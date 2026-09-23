// lex.mc -- the byte stream, which is the module's own.
// 
// mc's core lexer does not have php's punctuation and cannot lex php's
// regions (probes/t4 measured which), so this owns both: tok_add for the
// lexemes the core can be taught, and p_skip_to for the four it cannot --
// '...', # comments, #[Attr] and inline html -- plus "...", where php's own
// \xNN / \u{...} / octal escapes live.

// ---- the punctuation the core does not have (T4's table 1) -----------------
void ph_tokens() {
    tok_add("<?php", 5);
    tok_add("<?=",  3);
    tok_add("?>",   2);
    tok_add("?->",  3);
    tok_add("??=",  3);
    tok_add("??",   2);
    tok_add("::",   2);
    tok_add("**=",  3);
    tok_add("**",   2);
    tok_add("...",  3);
    tok_add("<=>",  3);
    tok_add("<<<",  3);
    tok_add("<<=",  3);
    tok_add(">>=",  3);
    tok_add("<<",   2);
    tok_add(">>",   2);
    tok_add(".=",   2);
    tok_add("->",   2);
    tok_add("<>",   2);
    tok_add("\\",   1);
    tok_add("+=",   2);
    tok_add("-=",   2);
    tok_add("*=",   2);
    tok_add("/=",   2);
    tok_add("%=",   2);
    tok_add("|=",   2);
    tok_add("&=",   2);
    tok_add("^=",   2);
    tok_add("&&",   2);
    tok_add("||",   2);
    tok_add("===",  3);
    tok_add("!==",  3);
    tok_add("++",   2);
    tok_add("--",   2);
    tok_add("?",    1);
    tok_add(":",    1);
    tok_add("@",    1);
    tok_add("`",    1);
}

i64 ph_tok(uptr s, i64 n) { return tok_add(s, n); }

// ---- the token layer: the module owns what the core lexer cannot ----------
// p_skip_to's guard is `cp == tok_start(cur) + tok_len(cur)`, which one skip
// already breaks -- so there is AT MOST ONE p_skip_to per advance, and the
// whole raw scan (whitespace, // and /* */ and # comments, #[Attr]) decides a
// single destination before calling it.
#define PHT_PSTR (-2)     // a php single-quoted string: raw bytes, no escapes but \\ and \'
#define PHT_HTML (-3)     // a run of inline html between ?> and <?php
#define PHT_DSTR (-4)     // a php double-quoted string, already lowered to a node

i64  ph_tid;
uptr ph_tname;
i64  ph_tlen;
i64  ph_tval;
i64  ph_tline;
uptr ph_tfile;
i64  ph_tnode;            // PHT_DSTR: the node the scanner already built
i64  ph_nopeek;           // set right after a p_push_source: cur is in the old frame

// `#[\Override]` just went past: the next class member is the one php checks
i64  ph_saw_override;

// is the very next thing in the source `::`? The module has no token
// lookahead, so this reads the cursor, which sits just past the current
// token -- the same road ph_number takes for a literal's tail.
i64 ph_dcolon_next() {
    uptr q = p_cp();
    uptr e = p_src_end();
    loop {
        if (q >= e) return 0;
        i64 c = ld8(q);
        if (c == 32 || c == 9 || c == 10 || c == 13) { q = q + 1; continue; }
        break;
    }
    if (q + 1 >= e) return 0;
    if (ld8(q) != 58) return 0;
    if (ld8(q + 1) != 58) return 0;
    return 1;
}

// does [b, e) contain `w` as a whole word? (the attribute scan's only need)
i64 ph_has_word(uptr b, uptr e, uptr w, i64 n) {
    uptr q = b;
    loop {
        if (q + n > e) break;
        i64 k = 0;
        loop { if (k >= n) break; if (ld8(q + k) != ld8(w + k)) break; k = k + 1; }
        if (k == n) {
            i64 okl = 1;
            i64 okr = 1;
            if (q > b) { i64 p0 = ld8(q - 1); if (ph_nmb(p0, 0)) okl = 0; }
            if (q + n < e) { i64 p1 = ld8(q + n); if (ph_nmb(p1, 0)) okr = 0; }
            if (okl && okr) return 1;
        }
        q = q + 1;
    }
    return 0;
}

void ph_sync() {
    ph_tid   = p_id();
    ph_tname = p_name();
    ph_tval  = p_val();
    ph_tline = p_line();
    ph_tfile = p_file();
    ph_tlen  = 0;
}

i64 ph_space(i64 c) {
    if (c == 32) return 1;
    if (c == 9)  return 1;
    if (c == 10) return 1;
    if (c == 13) return 1;
    if (c == 11) return 1;
    if (c == 12) return 1;
    return 0;
}

// the single-quoted string, php's rule: only \\ and \' are escapes
uptr ph_sq_read(uptr q, uptr e, uptr pend, uptr plen) {
    uptr out = xalloc(e - q + 1);
    i64 n = 0;
    uptr p = q + 1;
    loop {
        if (p >= e) err_at(ph_tfile, ph_tline, "unterminated php single-quoted string");
        i64 c = ld8(p);
        if (c == 39) { p = p + 1; break; }
        if (c == 92) {
            if (p + 1 < e) {
                i64 d = ld8(p + 1);
                if (d == 39 || d == 92) { st8(out + n, d); n = n + 1; p = p + 2; continue; }
            }
        }
        st8(out + n, c);
        n = n + 1;
        p = p + 1;
    }
    st8(out + n, 0);
    st64(plen, n);
    st64(pend, p);
    return out;
}


// php's double-quoted string. Owning it is what makes `\xNN`, `\u{...}`, the
// octal escapes and an ESCAPED `\$` possible at all: the core lexer decodes
// its own (smaller) escape set before any handler runs, and by then `\$` and
// `$` are the same byte. The interpolation is done here for the same reason,
// so the node is built during the scan and ph_primary just returns it.
uptr ph_dqbuf;
i64  ph_dqcap;
i64  ph_dqn;

void ph_dq_put(i64 c) {
    if (ph_dqn >= ph_dqcap) {
        i64 nc = ph_dqcap * 2 + 64;
        uptr nb = xalloc(nc);
        i64 i = 0;
        loop { if (i >= ph_dqn) break; st8(nb + i, ld8(ph_dqbuf + i)); i = i + 1; }
        ph_dqbuf = nb;
        ph_dqcap = nc;
    }
    st8(ph_dqbuf + ph_dqn, c);
    ph_dqn = ph_dqn + 1;
}

void ph_dq_utf8(i64 cp) {
    if (cp < 0x80) { ph_dq_put(cp); return; }
    if (cp < 0x800) { ph_dq_put(0xc0 | (cp >> 6)); ph_dq_put(0x80 | (cp & 63)); return; }
    if (cp < 0x10000) {
        ph_dq_put(0xe0 | (cp >> 12));
        ph_dq_put(0x80 | ((cp >> 6) & 63));
        ph_dq_put(0x80 | (cp & 63));
        return;
    }
    ph_dq_put(0xf0 | (cp >> 18));
    ph_dq_put(0x80 | ((cp >> 12) & 63));
    ph_dq_put(0x80 | ((cp >> 6) & 63));
    ph_dq_put(0x80 | (cp & 63));
}

i64 ph_dq_flush(i64 acc) {
    if (ph_dqn == 0) return acc;
    i64 lit = ph_strlit(xstrdup(ph_dqbuf, ph_dqn), ph_dqn);
    ph_dqn = 0;
    if (!acc) return lit;
    return ph_c2("php_str_concat", acc, lit, ty_pstr);
}

i64 ph_name_byte(i64 c, i64 first) {
    if (c >= 97 && c <= 122) return 1;
    if (c >= 65 && c <= 90)  return 1;
    if (c == 95) return 1;
    if (!first && c >= 48 && c <= 57) return 1;
    return 0;
}

// returns the node; writes the byte just past the closing quote through pend
i64 ph_dq_read2(uptr q, uptr e, uptr pend, i64 term, i64 raw) {
    uptr p = q;
    i64 acc = 0;
    ph_dqn = 0;
    loop {
        if (p >= e) { if (term) err_at(ph_tfile, ph_tline, "mc-php: unterminated php string"); break; }
        i64 c = ld8(p);
        if (term && c == term) { p = p + 1; break; }
        if (c == 92 && !raw) {
            p = p + 1;
            if (p >= e) break;
            i64 d = ld8(p);
            p = p + 1;
            if (d == 110) { ph_dq_put(10); continue; }
            if (d == 116) { ph_dq_put(9);  continue; }
            if (d == 114) { ph_dq_put(13); continue; }
            if (d == 118) { ph_dq_put(11); continue; }
            if (d == 101) { ph_dq_put(27); continue; }
            if (d == 102) { ph_dq_put(12); continue; }
            if (d == 92)  { ph_dq_put(92); continue; }
            if (d == 36)  { ph_dq_put(36); continue; }
            if (d == 34)  { ph_dq_put(34); continue; }
            if (d == 120 || d == 88) {                 // \xNN
                i64 v = 0;
                i64 k = 0;
                loop {
                    if (k >= 2 || p >= e) break;
                    i64 h = ph_digit(ld8(p), 16);
                    if (h < 0) break;
                    v = v * 16 + h;
                    p = p + 1;
                    k = k + 1;
                }
                if (k == 0) { ph_dq_put(92); ph_dq_put(d); continue; }
                ph_dq_put(v);
                continue;
            }
            if (d == 117) {                            // \u{HHHH}
                if (p < e && ld8(p) == 123) {
                    p = p + 1;
                    i64 v2 = 0;
                    loop {
                        if (p >= e) break;
                        i64 h2 = ph_digit(ld8(p), 16);
                        if (h2 < 0) break;
                        v2 = v2 * 16 + h2;
                        p = p + 1;
                    }
                    if (p < e && ld8(p) == 125) p = p + 1;
                    ph_dq_utf8(v2);
                    continue;
                }
                ph_dq_put(92); ph_dq_put(d);
                continue;
            }
            if (d >= 48 && d <= 55) {                  // \NNN octal
                i64 v3 = d - 48;
                i64 k3 = 1;
                loop {
                    if (k3 >= 3 || p >= e) break;
                    i64 o = ld8(p);
                    if (o < 48 || o > 55) break;
                    v3 = v3 * 8 + (o - 48);
                    p = p + 1;
                    k3 = k3 + 1;
                }
                ph_dq_put(v3 & 255);
                continue;
            }
            ph_dq_put(92);                             // php keeps an unknown escape
            ph_dq_put(d);
            continue;
        }
        i64 nstart = 0;
        i64 brace = 0;
        if (raw) { ph_dq_put(c); p = p + 1; continue; }   // a nowdoc interpolates nothing
        if (c == 36 && p + 1 < e && ph_name_byte(ld8(p + 1), 1)) nstart = p + 1;
        if (c == 123 && p + 2 < e && ld8(p + 1) == 36 && ph_name_byte(ld8(p + 2), 1)) { nstart = p + 2; brace = 1; }
        if (!nstart) { ph_dq_put(c); p = p + 1; continue; }
        uptr k4 = nstart;
        loop {
            if (k4 >= e) break;
            if (!ph_name_byte(ld8(k4), 0)) break;
            k4 = k4 + 1;
        }
        if (brace) {
            // {$a[...]} and {$o->p} carry one accessor before the }
            i64 nx = 0;
            if (k4 < e) nx = ld8(k4);
            if (nx != 125 && nx != 91 && nx != 45) { ph_dq_put(c); p = p + 1; continue; }
        }
        acc = ph_dq_flush(acc);
        uptr d2 = xalloc(k4 - nstart + 2);
        st8(d2, 36);
        i64 z = 0;
        loop { if (z >= k4 - nstart) break; st8(d2 + 1 + z, ld8(nstart + z)); z = z + 1; }
        st8(d2 + 1 + (k4 - nstart), 0);
        i64 vt = PT_MIXED;
        i64 v4 = 0;
        if (ph_var_find(d2) < 0) v4 = ph_c1("php_undef_var", ph_raw(d2 + 1, cstrlen(d2) - 1), ty_pzv);
        if (!v4) {
            vt = ph_var_type(d2);
            v4 = node_new(N_IDENT, ph_tline, ph_tfile);
            set_nd_name(v4, ph_mangle(d2, "v_"));
            set_nd_type(v4, ph_mcty(vt));
        }
        p = k4;
        // php's SIMPLE interpolation carries one accessor: $a[k] with a bare
        // key, and $o->p
        loop {
            if (p < e && ld8(p) == 91) {
                uptr ks = p + 1;
                uptr ke = ks;
                loop { if (ke >= e) break; if (ld8(ke) == 93) break; ke = ke + 1; }
                if (ke >= e) break;
                i64 key = 0;
                i64 kc = ld8(ks);
                if (kc == 36 && ks + 1 < e && ph_name_byte(ld8(ks + 1), 1)) {
                    uptr kd = xalloc(ke - ks + 2);
                    i64 y = 0;
                    loop { if (y >= ke - ks) break; st8(kd + y, ld8(ks + y)); y = y + 1; }
                    st8(kd + (ke - ks), 0);
                    if (ph_var_find(kd) < 0) break;
                    i64 kt = ph_var_type(kd);
                    i64 kn = node_new(N_IDENT, ph_tline, ph_tfile);
                    set_nd_name(kn, ph_mangle(kd, "v_"));
                    set_nd_type(kn, ph_mcty(kt));
                    key = ph_to_mixed(kn, kt);
                } else {
                    i64 alldig = 1;
                    i64 y2 = 0;
                    loop { if (y2 >= ke - ks) break; if (ph_digit(ld8(ks + y2), 10) < 0) { alldig = 0; break; } y2 = y2 + 1; }
                    if (ke == ks) break;
                    if (alldig) {
                        i64 iv = 0;
                        y2 = 0;
                        loop { if (y2 >= ke - ks) break; iv = iv * 10 + ph_digit(ld8(ks + y2), 10); y2 = y2 + 1; }
                        key = ph_to_mixed(ph_int(iv), PT_INT);
                    }
                    if (!alldig) {
                        uptr kb = ks;
                        i64 kl = ke - ks;
                        // php accepts a bare word here, and also a quoted one
                        if (kl >= 2 && (ld8(kb) == 39 || ld8(kb) == 34)) { kb = kb + 1; kl = kl - 2; }
                        key = ph_to_mixed(ph_strlit(xstrdup(kb, kl), kl), PT_STRING);
                    }
                }
                if (!key) break;
                if (vt == PT_MIXED) v4 = ph_c1("php_zv_arr_r", v4, ty_parr);
                if (vt != PT_MIXED && vt != PT_ARR) break;
                v4 = ph_c2("php_arr_zget_w", v4, key, ty_pzv);
                vt = PT_MIXED;
                p = ke + 1;
                break;
            }
            if (p + 2 < e && ld8(p) == 45 && ld8(p + 1) == 62 && ph_name_byte(ld8(p + 2), 1)) {
                uptr ps = p + 2;
                uptr pe2 = ps;
                loop { if (pe2 >= e) break; if (!ph_name_byte(ld8(pe2), 0)) break; pe2 = pe2 + 1; }
                v4 = ph_c3("php_zv_pget", ph_recv(v4, vt), ph_strlit(xstrdup(ps, pe2 - ps), pe2 - ps), ph_scope(), ty_pzv);
                vt = PT_MIXED;
                p = pe2;
                break;
            }
            break;
        }
        i64 sv = ph_to_str(v4, vt);
        if (acc) acc = ph_c2("php_str_concat", acc, sv, ty_pstr);
        if (!acc) acc = sv;
        if (brace) { if (p < e && ld8(p) == 125) p = p + 1; }
    }
    st64(pend, p);
    acc = ph_dq_flush(acc);
    if (!acc) acc = ph_strlit("", 0);
    return acc;
}

i64 ph_dq_read(uptr q, uptr e, uptr pend) { return ph_dq_read2(q + 1, e, pend, 34, 0); }

// <<<LABEL / <<<"LABEL" / <<<'LABEL' -- php 7.3's indented closing label is
// stripped from every body line, and a nowdoc has no escapes and no
// interpolation.
i64 ph_heredoc(uptr q, uptr e, uptr pend) {
    uptr p = q + 3;
    loop { if (p >= e) break; i64 c = ld8(p); if (c != 32 && c != 9) break; p = p + 1; }
    i64 raw = 0;
    i64 quoted = 0;
    if (p < e && ld8(p) == 39) { raw = 1; quoted = 1; p = p + 1; }
    if (p < e && ld8(p) == 34) { quoted = 1; p = p + 1; }
    uptr ls = p;
    loop { if (p >= e) break; if (!ph_name_byte(ld8(p), p == ls)) break; p = p + 1; }
    i64 ln = p - ls;
    if (!ln) err_at(ph_tfile, ph_tline, "mc-php: a heredoc needs a label");
    uptr lab = xstrdup(ls, ln);
    if (quoted) { if (p < e && (ld8(p) == 39 || ld8(p) == 34)) p = p + 1; }
    loop { if (p >= e) break; if (ld8(p) == 10) { p = p + 1; break; } p = p + 1; }
    uptr bs = p;
    // find the closing label: the first line whose first non-blank run is it
    uptr be = e;
    uptr after = e;
    i64 indent = 0;
    uptr ln0 = p;
    loop {
        if (ln0 >= e) break;
        uptr k = ln0;
        loop { if (k >= e) break; i64 c = ld8(k); if (c != 32 && c != 9) break; k = k + 1; }
        i64 m = 1;
        i64 z = 0;
        loop {
            if (z >= ln) break;
            if (k + z >= e || ld8(k + z) != ld8(lab + z)) { m = 0; break; }
            z = z + 1;
        }
        if (m) {
            if (k + ln >= e || !ph_name_byte(ld8(k + ln), 0)) {
                be = ln0;
                indent = k - ln0;
                after = k + ln;
                break;
            }
        }
        loop { if (ln0 >= e) break; if (ld8(ln0) == 10) { ln0 = ln0 + 1; break; } ln0 = ln0 + 1; }
    }
    if (be > bs) { be = be - 1; if (be > bs && ld8(be - 1) == 13) be = be - 1; }   // the \n before the label
    // strip the closing indentation from every line
    uptr body = bs;
    i64 blen = be - bs;
    if (blen < 0) blen = 0;
    if (indent) {
        uptr o = xalloc(blen + 1);
        i64 w = 0;
        uptr r = bs;
        loop {
            if (r >= be) break;
            i64 sk = 0;
            loop {
                if (sk >= indent || r >= be) break;
                i64 c = ld8(r);
                if (c != 32 && c != 9) break;
                r = r + 1;
                sk = sk + 1;
            }
            loop {
                if (r >= be) break;
                i64 c = ld8(r);
                st8(o + w, c);
                w = w + 1;
                r = r + 1;
                if (c == 10) break;
            }
        }
        body = o;
        blen = w;
    }
    st64(pend, after);
    u8 dummy[8];
    i64 saveline = ph_tline;
    i64 n = ph_dq_read2(body, body + blen, dummy, 0, raw);
    ph_tline = saveline;
    return n;
}

void ph_next() {
    if (ph_tid == PHT_PSTR || ph_tid == PHT_HTML || ph_tid == PHT_DSTR) { p_next(); ph_sync(); return; }
    if (ph_nopeek) { ph_nopeek = 0; p_next(); ph_sync(); return; }
    if (p_id() == T_STR || p_id() == T_CHAR || p_id() == T_EOF) { p_next(); ph_sync(); return; }

    uptr q = p_cp();
    uptr e = p_src_end();
    uptr q0 = q;
    i64 quote = 0;
    loop {
        if (q >= e) break;
        i64 c = ld8(q);
        if (ph_space(c)) { q = q + 1; continue; }
        if (c == 47) {                                  // /
            if (q + 1 < e) {
                i64 d = ld8(q + 1);
                if (d == 47) { loop { if (q >= e) break; if (ld8(q) == 10) break; q = q + 1; } continue; }
                if (d == 42) {
                    q = q + 2;
                    loop {
                        if (q + 1 >= e) { q = e; break; }
                        if (ld8(q) == 42 && ld8(q + 1) == 47) { q = q + 2; break; }
                        q = q + 1;
                    }
                    continue;
                }
            }
            break;
        }
        if (c == 35) {                                  // # comment, or #[Attr]
            if (q + 1 < e && ld8(q + 1) == 91) {        // D6: attributes are inert
                // -- except `#[\Override]`, which is not reflection: php
                // CHECKS it while compiling the class, so the name is read
                // here and the member that follows is marked.
                q = q + 2;
                i64 depth = 1;
                uptr abeg = q;
                loop {
                    if (q >= e) break;
                    i64 d2 = ld8(q);
                    if (d2 == 91) depth = depth + 1;
                    if (d2 == 93) { depth = depth - 1; if (depth == 0) { q = q + 1; break; } }
                    q = q + 1;
                }
                if (ph_has_word(abeg, q, "Override", 8)) ph_saw_override = 1;
                continue;
            }
            loop {
                if (q >= e) break;
                if (ld8(q) == 10) break;
                if (ld8(q) == 63 && q + 1 < e && ld8(q + 1) == 62) break;   // ?> ends a # comment
                q = q + 1;
            }
            continue;
        }
        if (c == 39) { quote = 1; break; }              // '
        if (c == 34) { quote = 2; break; }              // "
        if (c == 60 && q + 2 < e && ld8(q + 1) == 60 && ld8(q + 2) == 60) { quote = 3; break; }
        break;
    }
    if (quote == 1) {
        u8 eb[8];
        u8 lb[8];
        uptr s = ph_sq_read(q, e, eb, lb);
        p_skip_to(ld64(eb));
        ph_tid = PHT_PSTR;
        ph_tname = s;
        ph_tlen = ld64(lb);
        return;
    }
    if (quote == 2) {
        u8 eb2[8];
        ph_tline = p_line();
        ph_tfile = p_file();
        i64 n2 = ph_dq_read(q, e, eb2);
        p_skip_to(ld64(eb2));
        ph_tid = PHT_DSTR;
        ph_tnode = n2;
        return;
    }
    if (quote == 3) {
        u8 eb3[8];
        ph_tline = p_line();
        ph_tfile = p_file();
        i64 n3 = ph_heredoc(q, e, eb3);
        p_skip_to(ld64(eb3));
        ph_tid = PHT_DSTR;
        ph_tnode = n3;
        return;
    }
    if (q != q0) p_skip_to(q);
    p_next();
    ph_sync();
}

// the lexeme test: a php keyword that is also an mc core keyword arrives as its
// K_* id and never as T_IDENT, so the test is on the LEXEME, with the classes
// whose lexeme is not a name excluded (so the string "return" is not a keyword)
i64 ph_is(uptr w) {
    if (ph_tid == T_STR)  return 0;
    if (ph_tid == T_CHAR) return 0;
    if (ph_tid == T_HOLE) return 0;
    if (ph_tid == T_INT)  return 0;
    if (ph_tid == PHT_PSTR) return 0;
    if (ph_tid == PHT_HTML) return 0;
    if (ph_tid == PHT_DSTR) return 0;
    return str_eq(ph_tname, w);
}

i64 ph_at(uptr s, i64 n) { if (ph_tid == ph_tok(s, n)) return 1; return 0; }

// php's variable names include words mc lexes as core KEYWORDS ($break, $for,
// $return...): the test is on the lexeme's shape, not on the token id.
i64 ph_wordish() {
    if (ph_tid == T_STR || ph_tid == T_CHAR || ph_tid == T_INT) return 0;
    if (ph_tid == PHT_PSTR || ph_tid == PHT_HTML || ph_tid == PHT_DSTR) return 0;
    if (!ph_tname) return 0;
    return ph_name_byte(ld8(ph_tname), 1);
}

void ph_want(uptr s, i64 n, uptr msg) {
    if (!ph_at(s, n)) err_at2(ph_tfile, ph_tline, msg, ph_tname);
    ph_next();
}

i64 ph_accept(uptr s, i64 n) { if (ph_at(s, n)) { ph_next(); return 1; } return 0; }

// php lets the CLOSING TAG end a statement: `<?php echo 1 ?>` is legal, and
// the ?> is left for the inline-html handler to pick up.
void ph_semi(uptr msg) {
    if (ph_at("?>", 2)) return;
    if (ph_tid == T_EOF) return;
    ph_want(";", 1, msg);
}


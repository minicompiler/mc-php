// php.mc -- T5's compiler: PHP 8.5 source, one mc Tier 3 module.
//
// What T4 measured, this builds on:
//   * ONE word registration owns the grammar -- syntax("<?php", &ph_program).
//     Every PHP keyword stays an ordinary identifier matched by str_eq, because
//     a registration reserves its word for the whole program and PHP has ~70.
//   * The expression grammar is the module's own (PHP's precedence is not mc's).
//
// What mc 1.1.0 added and this uses, which is why T5 is possible:
//   * p_skip_to(q)  -- a handler owns a REGION the core has no grammar for:
//     '...' , # comments, #[Attr], inline HTML. T4's in-place on_source rewrite
//     is GONE with it, and with it the `don't` -> `don"t` corruption it caused.
//   * syntax_expr("$", &f) -- `$name` now lexes as the `$` token plus the
//     ordinary identifier `name`, so the module reads both instead of meeting a
//     T_HOLE no registration reaches.
//
// docs/plan.md D4 is the rule that shapes everything: a variable's type is its
// first assignment's and never changes, so every expression has a STATIC php
// type and the lowering (D10) is a native value, never a zval.

// ---- the php type codes (D10's left column) --------------------------------
// The runtime's var_dump takes these as literals: php_rt.txt repeats them.
#define PT_INT     0
#define PT_FLOAT   1
#define PT_STRING  2
#define PT_BOOL    3
#define PT_VOID    4
#define PT_IFALSE  5      // int|false -- strpos's return, the one union T5 has
#define PT_NULL    6
#define PT_ARR     16     // + the element type: 16..21

i64 ty_pstr;              // the mc type `string` lowers to (D10)
i64 ty_parr;

// forward declarations: mc is single pass
uptr php_dec(i64 v);
i64  ph_const_find(uptr n);
void ph_const_add(uptr cn, i64 v, i64 t, uptr fl, i64 line);
i64  ph_array_lit(uptr close);
void ph_local(uptr name, i64 mcty);
i64  ph_set(uptr name, i64 val);
void ph_pending_stmt(i64 s);
i64  ph_expr(i64 minp);
i64  ph_stmt();
i64  ph_block();
i64  ph_block_or_stmt();
i64  ph_if(uptr fl, i64 line);
i64  ph_foreach(uptr fl, i64 line);
i64  ph_builtin(uptr name, i64 line, uptr fl);
uptr ph_read_args(i64 maxn, uptr fl, i64 line, uptr pn);
i64  ph_a(uptr av, i64 i);
i64  ph_aty(uptr av, i64 i);
i64  ph_arith(i64 op, i64 lhs, i64 lt, i64 rhs, i64 rt, uptr fl, i64 line);
i64  ph_assign_stmt(uptr fl, i64 line, i64 semi);
i64  ph_strlit(uptr bytes, i64 len);
i64  ph_digit(i64 c, i64 base);
i64  ph_dq_read(uptr q, uptr e, uptr pend);
i64  ph_to_str(i64 n, i64 t);
i64  ph_to_int(i64 n, i64 t);
i64  ph_to_float(i64 n, i64 t);
i64  ph_to_bool(i64 n, i64 t);
i64  ph_space(i64 c);
i64  ph_is_arr(i64 t);
i64  ph_elem(i64 t);
i64  ph_mcty(i64 t);
uptr ph_tyname(i64 t);
i64  ph_tok(uptr s, i64 n);
i64  ph_var_find(uptr d);
i64  ph_var_type(uptr d);
i64  ph_var_bind(uptr d, i64 ty);
void ph_refuse(uptr fl, i64 line, uptr what, uptr dref);
void ph_todo(uptr fl, i64 line, uptr what);
void ph_todo2(uptr fl, i64 line, uptr what, uptr detail);
void ph_refuse2(uptr fl, i64 line, uptr what, uptr detail, uptr dref);
i64  ph_int(i64 v);
i64  ph_bool(i64 v);
i64  ph_cast(i64 mcty, i64 a);
i64  ph_bin(i64 op, i64 a, i64 b, i64 ty);
i64  ph_c1(uptr n, i64 a, i64 ty);
i64  ph_c2(uptr n, i64 a, i64 b, i64 ty);
i64  ph_c3(uptr n, i64 a, i64 b, i64 c, i64 ty);
i64  ph_c4(uptr n, i64 a, i64 b, i64 c, i64 d, i64 ty);
i64  ph_call(uptr name, i64 nargs, i64 a0, i64 a1, i64 a2, i64 a3, i64 ty);
i64  ph_prec(i64 t);
i64  ph_is(uptr w);
i64  ph_at(uptr s, i64 n);
void ph_next();
i64  ph_accept(uptr s, i64 n);
void ph_want(uptr s, i64 n, uptr msg);
uptr ph_mangle(uptr d, uptr pfx);
i64  ph_raw(uptr bytes, i64 len);
i64  ph_wrap(i64 s);
i64  ph_empty();
i64  ph_expr_stmt_of(i64 e);
i64  ph_loop_of(i64 cond, i64 body, i64 step, i64 line, uptr fl);
i64  ph_loop_pre;
i64  ph_pushing;
i64  ph_type_word(i64 must);
i64  ph_vd(i64 v, i64 t, uptr fl, i64 line);
i64  ph_echo_of(i64 v, i64 t, uptr fl, i64 line);
i64  ph_inline_html(uptr fl, i64 line);

i64 ph_is_arr(i64 t) { if (t >= PT_ARR) return 1; return 0; }
i64 ph_elem(i64 t) { return t - PT_ARR; }

i64 ph_mcty(i64 t) {
    if (t == PT_INT)    return TY_I64;
    if (t == PT_IFALSE) return TY_I64;
    if (t == PT_FLOAT)  return ty_f64;
    if (t == PT_STRING) return ty_pstr;
    if (t == PT_BOOL)   return TY_U8;
    if (t == PT_VOID)   return TY_VOID;
    if (t == PT_NULL)   return TY_I64;
    if (ph_is_arr(t))   return ty_parr;
    return TY_I64;
}

uptr ph_tyname(i64 t) {
    if (t == PT_INT)    return "int";
    if (t == PT_FLOAT)  return "float";
    if (t == PT_STRING) return "string";
    if (t == PT_BOOL)   return "bool";
    if (t == PT_VOID)   return "void";
    if (t == PT_IFALSE) return "int|false";
    if (t == PT_NULL)   return "null";
    if (t == PT_ARR + PT_INT)    return "array<int>";
    if (t == PT_ARR + PT_FLOAT)  return "array<float>";
    if (t == PT_ARR + PT_STRING) return "array<string>";
    if (t == PT_ARR + PT_BOOL)   return "array<bool>";
    if (ph_is_arr(t)) return "array";
    return "?";
}

// ---- refusals (D1, D4, D5, D6, and T5's own named limits) ------------------
// Every one of them is `mc-php: <what> is refused by design (docs/plan.md D<n>)`
// on stderr, which is what probes/t5/mcphp.sh turns into the grid's exit 3.
void ph_refuse(uptr fl, i64 line, uptr what, uptr dref) {
    uptr m = p_cat("mc-php: ", what, 0, cstrlen(what));
    m = p_cat(m, " is refused by design (docs/plan.md ", 0, 36);
    m = p_cat(m, dref, 0, cstrlen(dref));
    m = p_cat(m, ")", 0, 1);
    err_at(fl, line, m);
}

// NOT a refusal: something T5 has not built yet. It is an ordinary compile
// error (the grid counts it `wrong`), because inflating the refused column
// with "not implemented" would make that column a lie.
void ph_todo(uptr fl, i64 line, uptr what) {
    uptr m = p_cat("mc-php: ", what, 0, cstrlen(what));
    m = p_cat(m, " is not implemented in T5 (probes/t5/RESULTS.md)", 0, 48);
    err_at(fl, line, m);
}

void ph_todo2(uptr fl, i64 line, uptr what, uptr detail) {
    uptr m = p_cat(what, ": ", 0, 2);
    m = p_cat(m, detail, 0, cstrlen(detail));
    ph_todo(fl, line, m);
}

void ph_refuse2(uptr fl, i64 line, uptr what, uptr detail, uptr dref) {
    uptr m = p_cat(what, ": ", 0, 2);
    m = p_cat(m, detail, 0, cstrlen(detail));
    ph_refuse(fl, line, m, dref);
}

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
i64 ph_dq_read(uptr q, uptr e, uptr pend) {
    uptr p = q + 1;
    i64 acc = 0;
    ph_dqn = 0;
    loop {
        if (p >= e) err_at(ph_tfile, ph_tline, "mc-php: unterminated php string");
        i64 c = ld8(p);
        if (c == 34) { p = p + 1; break; }
        if (c == 92) {
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
            if (k4 >= e || ld8(k4) != 125) { ph_dq_put(c); p = p + 1; continue; }
        }
        acc = ph_dq_flush(acc);
        uptr d2 = xalloc(k4 - nstart + 2);
        st8(d2, 36);
        i64 z = 0;
        loop { if (z >= k4 - nstart) break; st8(d2 + 1 + z, ld8(nstart + z)); z = z + 1; }
        st8(d2 + 1 + (k4 - nstart), 0);
        if (ph_var_find(d2) < 0) ph_refuse2(ph_tfile, ph_tline, "an undefined php variable in a string", d2, "D4");
        i64 vt = ph_var_type(d2);
        i64 v4 = node_new(N_IDENT, ph_tline, ph_tfile);
        set_nd_name(v4, ph_mangle(d2, "v_"));
        set_nd_type(v4, ph_mcty(vt));
        i64 sv = ph_to_str(v4, vt);
        if (acc) acc = ph_c2("php_str_concat", acc, sv, ty_pstr);
        if (!acc) acc = sv;
        p = k4;
        if (brace) p = k4 + 1;
    }
    st64(pend, p);
    acc = ph_dq_flush(acc);
    if (!acc) acc = ph_strlit("", 0);
    return acc;
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
                q = q + 2;
                i64 depth = 1;
                loop {
                    if (q >= e) break;
                    i64 d2 = ld8(q);
                    if (d2 == 91) depth = depth + 1;
                    if (d2 == 93) { depth = depth - 1; if (depth == 0) { q = q + 1; break; } }
                    q = q + 1;
                }
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

void ph_want(uptr s, i64 n, uptr msg) {
    if (!ph_at(s, n)) err_at2(ph_tfile, ph_tline, msg, ph_tname);
    ph_next();
}

i64 ph_accept(uptr s, i64 n) { if (ph_at(s, n)) { ph_next(); return 1; } return 0; }

// ---- node helpers ----------------------------------------------------------
i64 ph_nonce;

i64 ph_int(i64 v) {
    i64 n = node_new(N_INT, ph_tline, ph_tfile);
    set_nd_val(n, v);
    set_nd_type(n, TY_I64);
    return n;
}

i64 ph_bool(i64 v) {
    i64 n = node_new(N_INT, ph_tline, ph_tfile);
    set_nd_val(n, v);
    set_nd_type(n, TY_U8);
    return n;
}

i64 ph_raw(uptr bytes, i64 len) {
    i64 k = node_new(N_STR, ph_tline, ph_tfile);
    set_nd_name(k, bytes);
    set_nd_val(k, len);
    set_nd_type(k, TY_UPTR);
    return k;
}

i64 ph_call(uptr name, i64 nargs, i64 a0, i64 a1, i64 a2, i64 a3, i64 ty) {
    i64 c = node_new(N_CALL, ph_tline, ph_tfile);
    set_nd_name(c, name);
    if (nargs >= 1) set_nd_a(c, a0);
    if (nargs >= 2) set_nd_next(a0, a1);
    if (nargs >= 3) set_nd_next(a1, a2);
    if (nargs >= 4) set_nd_next(a2, a3);
    set_nd_type(c, ty);
    return c;
}

i64 ph_c1(uptr n, i64 a, i64 ty) { return ph_call(n, 1, a, 0, 0, 0, ty); }
i64 ph_c2(uptr n, i64 a, i64 b, i64 ty) { return ph_call(n, 2, a, b, 0, 0, ty); }
i64 ph_c3(uptr n, i64 a, i64 b, i64 c, i64 ty) { return ph_call(n, 3, a, b, c, 0, ty); }
i64 ph_c4(uptr n, i64 a, i64 b, i64 c, i64 d, i64 ty) { return ph_call(n, 4, a, b, c, d, ty); }

i64 ph_bin(i64 op, i64 a, i64 b, i64 ty) {
    i64 n = node_new(N_BINARY, ph_tline, ph_tfile);
    set_nd_op(n, op);
    set_nd_a(n, a);
    set_nd_b(n, b);
    set_nd_type(n, ty);
    return n;
}

i64 ph_cast(i64 mcty, i64 a) {
    i64 n = node_new(N_CAST, ph_tline, ph_tfile);
    set_nd_type(n, mcty);
    set_nd_a(n, a);
    return n;
}

// a php string literal: one global cache slot beside it, so an arena with no
// free (D7) pays one copy per literal per RUN and not one per loop iteration.
i64 ph_strlit(uptr bytes, i64 len) {
    ph_nonce = ph_nonce + 1;
    uptr nm = p_cat("phl_", "", 0, 0);
    nm = p_cat(nm, php_dec(ph_nonce), 0, cstrlen(php_dec(ph_nonce)));
    i64 g = node_new(N_GLOBAL, ph_tline, ph_tfile);
    set_nd_name(g, nm);
    set_nd_type(g, TY_UPTR);
    set_nd_val(g, 1);
    set_nd_a(g, 0);
    top_add(g);
    i64 cache = node_new(N_IDENT, ph_tline, ph_tfile);
    set_nd_name(cache, nm);
    return ph_c3("php_str_lit", cache, ph_raw(bytes, len), ph_int(len), ty_pstr);
}

uptr php_dec(i64 v) {
    uptr o = xalloc(24);
    i64 k = 0;
    u8 t[24];
    i64 u = v;
    loop { st8(t + k, 48 + u % 10); u = u / 10; k = k + 1; if (u == 0) break; }
    i64 i = 0;
    loop { if (i >= k) break; st8(o + i, ld8(t + k - 1 - i)); i = i + 1; }
    st8(o + k, 0);
    return o;
}

// the mc-level name of a php variable/function: `$x` -> `v_x`, `f` -> `f_f`
uptr ph_mangle(uptr d, uptr pfx) {
    i64 n = cstrlen(d);
    i64 skip = 0;
    if (ld8(d) == 36) skip = 1;
    uptr o = xalloc(n + 8);
    i64 i = 0;
    loop { i64 c = ld8(pfx + i); if (!c) break; st8(o + i, c); i = i + 1; }
    i64 j = skip;
    loop { if (j >= n) break; st8(o + i, ld8(d + j)); i = i + 1; j = j + 1; }
    st8(o + i, 0);
    return o;
}

// ---- locals are hoisted to the top of the function ------------------------
// php scopes a variable to the FUNCTION; an mc block scopes its own locals. So
// every local -- a php variable and the temporaries an array literal or a
// foreach needs -- is declared (with no initialiser) in one list that
// ph_function and ph_program put in front of the body, and the place it is
// written emits an N_ASSIGN. Without this, `if (c) { $y = 1; } echo $y;` --
// valid php -- would not compile.
i64 ph_hoist_head;
i64 ph_hoist_tail;

void ph_local(uptr name, i64 mcty) {
    i64 v = node_new(N_VAR, ph_tline, ph_tfile);
    set_nd_name(v, name);
    set_nd_type(v, mcty);
    set_nd_a(v, 0);
    if (ph_hoist_tail) set_nd_next(ph_hoist_tail, v);
    if (!ph_hoist_tail) ph_hoist_head = v;
    ph_hoist_tail = v;
}

i64 ph_set(uptr name, i64 val) {
    i64 a = node_new(N_ASSIGN, ph_tline, ph_tfile);
    set_nd_name(a, name);
    set_nd_a(a, val);
    return a;
}

// ---- D4: one type per variable, its first assignment's ---------------------
#define PH_MAXVAR 512

uptr ph_vname[PH_MAXVAR];
i64  ph_vtype[PH_MAXVAR];
i64  ph_nvar;

i64 ph_var_find(uptr d) {
    i64 i = 0;
    loop {
        if (i >= ph_nvar) break;
        if (str_eq(ld64(ph_vname + i * 8), d)) return i;
        i = i + 1;
    }
    return -1;
}

i64 ph_var_type(uptr d) { return ld64(ph_vtype + ph_var_find(d) * 8); }

// 1 when this is the variable's FIRST assignment (the caller emits N_VAR, not
// N_ASSIGN). A second assignment of another type is D4's named compile error.
i64 ph_var_bind(uptr d, i64 ty) {
    i64 i = ph_var_find(d);
    if (i < 0) {
        if (ph_nvar >= PH_MAXVAR) err_at(ph_tfile, ph_tline, "mc-php: too many php variables");
        st64(ph_vname + ph_nvar * 8, d);
        st64(ph_vtype + ph_nvar * 8, ty);
        ph_nvar = ph_nvar + 1;
        ph_local(ph_mangle(d, "v_"), ph_mcty(ty));
        return 1;
    }
    i64 was = ld64(ph_vtype + i * 8);
    if (was != ty) {
        uptr m = p_cat(d, " was ", 0, 5);
        m = p_cat(m, ph_tyname(was), 0, cstrlen(ph_tyname(was)));
        m = p_cat(m, ", assigned ", 0, 11);
        m = p_cat(m, ph_tyname(ty), 0, cstrlen(ph_tyname(ty)));
        ph_refuse2(ph_tfile, ph_tline, "a php variable has one type", m, "D4");
    }
    return 0;
}

// ---- `const NAME = <literal>;` and define("NAME", <literal>) --------------
// A constant is compile time here, which is what D1 already requires of every
// name: there is no run-time symbol table to look one up in.
#define PH_MAXCONST 256

uptr ph_cname[PH_MAXCONST];
i64  ph_cty[PH_MAXCONST];
i64  ph_cval[PH_MAXCONST];
uptr ph_cstr[PH_MAXCONST];
i64  ph_nconst;

i64 ph_const_find(uptr n) {
    i64 i = 0;
    loop {
        if (i >= ph_nconst) break;
        if (str_eq(ld64(ph_cname + i * 8), n)) return i;
        i = i + 1;
    }
    return -1;
}

// A constant's value has to be known at compile time: an int/bool literal or a
// string literal, which is the php_str_lit call ph_strlit built.
void ph_const_add(uptr cn, i64 v, i64 t, uptr fl, i64 line) {
    if (ph_const_find(cn) >= 0) err_at2(fl, line, "mc-php: this php constant is declared twice", cn);
    if (ph_nconst >= PH_MAXCONST) err_at(fl, line, "mc-php: too many php constants");
    i64 val = 0;
    uptr bytes = 0;
    if (t == PT_INT || t == PT_BOOL) {
        if (nd_kind(v) != N_INT) ph_todo2(fl, line, "a php constant whose value is not a literal", cn);
        val = nd_val(v);
    } else {
        if (t != PT_STRING) ph_todo2(fl, line, "a php constant of type", ph_tyname(t));
        if (nd_kind(v) != N_CALL || !str_eq(nd_name(v), "php_str_lit"))
            ph_todo2(fl, line, "a php constant whose value is not a literal", cn);
        i64 raw = nd_next(nd_a(v));
        bytes = nd_name(raw);
        val = nd_val(raw);
    }
    st64(ph_cname + ph_nconst * 8, cn);
    st64(ph_cty + ph_nconst * 8, t);
    st64(ph_cval + ph_nconst * 8, val);
    st64(ph_cstr + ph_nconst * 8, bytes);
    ph_nconst = ph_nconst + 1;
}

// ---- the function table ----------------------------------------------------
#define PH_MAXFN  256
#define PH_MAXP   12

uptr ph_fname[PH_MAXFN];
i64  ph_fret[PH_MAXFN];
i64  ph_fnp[PH_MAXFN];
i64  ph_fpt[PH_MAXFN * PH_MAXP];
i64  ph_nfn;

i64 ph_fn_find(uptr n) {
    i64 i = 0;
    loop {
        if (i >= ph_nfn) break;
        if (str_eq(ld64(ph_fname + i * 8), n)) return i;
        i = i + 1;
    }
    return -1;
}

// ---- the type words on the surface are PHP's (D9) --------------------------
i64 ph_type_word(i64 must) {
    if (ph_at("?", 1)) ph_refuse(ph_tfile, ph_tline, "a nullable type ?T", "D9 (e)");
    if (ph_is("int"))      { ph_next(); if (ph_at("|", 1)) ph_refuse(ph_tfile, ph_tline, "a union type", "D9"); return PT_INT; }
    if (ph_is("float"))    { ph_next(); if (ph_at("|", 1)) ph_refuse(ph_tfile, ph_tline, "a union type", "D9"); return PT_FLOAT; }
    if (ph_is("string"))   { ph_next(); if (ph_at("|", 1)) ph_refuse(ph_tfile, ph_tline, "a union type", "D9"); return PT_STRING; }
    if (ph_is("bool"))     { ph_next(); if (ph_at("|", 1)) ph_refuse(ph_tfile, ph_tline, "a union type", "D9"); return PT_BOOL; }
    if (ph_is("void"))     { ph_next(); return PT_VOID; }
    if (ph_is("array"))    { ph_next(); ph_refuse(ph_tfile, ph_tline, "an untyped array parameter", "D4 (d)"); }
    if (ph_is("mixed"))    { ph_next(); ph_refuse(ph_tfile, ph_tline, "the type mixed", "D4 (c)"); }
    if (ph_is("iterable")) { ph_next(); ph_refuse(ph_tfile, ph_tline, "the type iterable", "D9"); }
    if (ph_is("callable")) { ph_next(); ph_refuse(ph_tfile, ph_tline, "the type callable", "D9"); }
    if (ph_is("object"))   { ph_next(); ph_refuse(ph_tfile, ph_tline, "the type object", "D9"); }
    if (ph_is("null"))     { ph_next(); ph_refuse(ph_tfile, ph_tline, "the type null", "D9 (e)"); }
    if (ph_is("static"))   { ph_next(); ph_refuse(ph_tfile, ph_tline, "the type static", "D6"); }
    if (ph_is("self"))     { ph_next(); ph_refuse(ph_tfile, ph_tline, "the type self", "D6"); }
    if (ph_is("never"))    { ph_next(); ph_refuse(ph_tfile, ph_tline, "the type never", "D9"); }
    if (must) ph_refuse2(ph_tfile, ph_tline, "a php type this compiler does not have", ph_tname, "D9");
    return -1;
}

// ---- conversions between the static types ----------------------------------
i64 ph_to_str(i64 n, i64 t) {
    if (t == PT_STRING) return n;
    if (t == PT_INT)    return ph_c1("php_itos", n, ty_pstr);
    if (t == PT_IFALSE) return ph_c1("php_itos", n, ty_pstr);
    if (t == PT_FLOAT)  return ph_c1("php_ftos", n, ty_pstr);
    if (t == PT_BOOL)   return ph_c1("php_btos", n, ty_pstr);
    ph_refuse2(ph_tfile, ph_tline, "converting to string", ph_tyname(t), "D4");
    return 0;
}

i64 ph_to_int(i64 n, i64 t) {
    if (t == PT_INT || t == PT_IFALSE) return n;
    if (t == PT_BOOL)   return ph_cast(TY_I64, n);
    if (t == PT_FLOAT)  return ph_cast(TY_I64, n);
    if (t == PT_STRING) return ph_c1("php_stoi", n, TY_I64);
    ph_refuse2(ph_tfile, ph_tline, "converting to int", ph_tyname(t), "D4");
    return 0;
}

i64 ph_to_float(i64 n, i64 t) {
    if (t == PT_FLOAT) return n;
    if (t == PT_INT || t == PT_IFALSE || t == PT_BOOL) return ph_cast(ty_f64, n);
    if (t == PT_STRING) return ph_c1("php_stof", n, ty_f64);
    ph_refuse2(ph_tfile, ph_tline, "converting to float", ph_tyname(t), "D4");
    return 0;
}

i64 ph_to_bool(i64 n, i64 t) {
    if (t == PT_BOOL) return n;
    if (t == PT_INT || t == PT_IFALSE)
        return ph_cast(TY_U8, ph_bin(ph_tok("!=", 2), n, ph_int(0), TY_U8));
    if (t == PT_FLOAT)  return ph_cast(TY_U8, ph_c1("php_truthy_f", n, TY_I64));
    if (t == PT_STRING) return ph_cast(TY_U8, ph_c1("php_truthy_s", n, TY_I64));
    if (ph_is_arr(t))   return ph_cast(TY_U8, ph_bin(ph_tok("!=", 2), ph_c1("php_count", n, TY_I64), ph_int(0), TY_U8));
    ph_refuse2(ph_tfile, ph_tline, "converting to bool", ph_tyname(t), "D4");
    return 0;
}

// ---- the expression grammar (the module's own -- T4's finding) -------------
i64 ph_ety;                     // the php type of the node ph_expr just returned


i64 ph_digit(i64 c, i64 base) {
    i64 d = -1;
    if (c >= 48 && c <= 57)  d = c - 48;
    if (c >= 97 && c <= 102) d = c - 87;
    if (c >= 65 && c <= 70)  d = c - 55;
    if (d < 0) return -1;
    if (d >= base) return -1;
    return d;
}

// the number formats the core lexer stops short of: 0b / 0o / 1_000 / 1.5 /
// 1e3 / 0x1F. p_cp() is the cursor, p_take_lit(q) says where the literal ends.
i64 ph_number() {
    i64 v = ph_tval;
    uptr q = p_cp();
    uptr e = p_src_end();
    i64 base = 0;
    if (v == 0 && q < e) {
        i64 c0 = ld8(q);
        if (c0 == 98 || c0 == 66)  base = 2;
        if (c0 == 111 || c0 == 79) base = 8;
    }
    // php's LEGACY octal: a leading 0 followed by a digit. The core lexer read
    // it as decimal, so the digits have to be re-read from the source.
    if (!base && ld8(p_start()) == 48) {
        uptr r = p_start() + 1;
        if (r < q && ph_digit(ld8(r), 8) >= 0) {
            i64 oct = 0;
            loop {
                if (r >= q) break;
                i64 c1 = ld8(r);
                if (c1 == 95) { r = r + 1; continue; }
                i64 d1 = ph_digit(c1, 8);
                if (d1 < 0) break;
                oct = oct * 8 + d1;
                r = r + 1;
            }
            p_take_lit(q);
            ph_next();
            ph_ety = PT_INT;
            return ph_int(oct);
        }
    }
    if (base) {
        q = q + 1;
        i64 acc = 0;
        i64 nd = 0;
        loop {
            if (q >= e) break;
            i64 c = ld8(q);
            if (c == 95) { q = q + 1; continue; }
            i64 d = ph_digit(c, base);
            if (d < 0) break;
            acc = acc * base + d;
            nd = nd + 1;
            q = q + 1;
        }
        if (!nd) err_at(ph_tfile, ph_tline, "mc-php: a php integer literal with no digits");
        p_take_lit(q);
        ph_next();
        ph_ety = PT_INT;
        return ph_int(acc);
    }
    // legacy octal 0777 and 0o777 aside, the core already gave us the decimal
    // or hex value in ph_tval; what is left is _ separators and the float tail.
    i64 ipart = v;
    loop {
        if (q >= e) break;
        if (ld8(q) != 95) break;
        q = q + 1;
        loop {
            if (q >= e) break;
            i64 d = ph_digit(ld8(q), 10);
            if (d < 0) break;
            ipart = ipart * 10 + d;
            q = q + 1;
        }
    }
    i64 isf = 0;
    if (q < e) {
        i64 c = ld8(q);
        if (c == 101 || c == 69) isf = 1;
        if (c == 46) { if (q + 1 >= e) isf = 1; if (q + 1 < e && ph_digit(ld8(q + 1), 10) >= 0) isf = 1; }
    }
    if (!isf) {
        p_take_lit(q);
        ph_next();
        ph_ety = PT_INT;
        return ph_int(ipart);
    }
    // a float literal: scan the whole lexeme and hand the text to the runtime's
    // own strtod, so the compiler needs no decimal-to-binary of its own.
    uptr s0 = p_start();
    loop {
        if (q >= e) break;
        i64 c = ld8(q);
        if (c == 46 || c == 95) { q = q + 1; continue; }
        if (ph_digit(c, 10) >= 0) { q = q + 1; continue; }
        if (c == 101 || c == 69) {
            q = q + 1;
            if (q < e && (ld8(q) == 43 || ld8(q) == 45)) q = q + 1;
            continue;
        }
        break;
    }
    i64 tl = q - s0;
    uptr txt = xstrdup(s0, tl);
    p_take_lit(q);
    ph_next();
    ph_ety = PT_FLOAT;
    return ph_c1("php_stof", ph_strlit(txt, tl), ty_f64);
}

// "a $x b {$y}": the core hands over ONE T_STR with the escapes already
// decoded, so the module re-scans it for the `$`.
i64 ph_interp(uptr raw, i64 n) {
    i64 acc = 0;
    i64 seg = 0;
    i64 i = 0;
    loop {
        if (i >= n) break;
        i64 c = ld8(raw + i);
        i64 j = 0;
        i64 brace = 0;
        if (c == 123 && i + 1 < n && ld8(raw + i + 1) == 36) { brace = 1; j = i + 2; }
        if (c == 36) j = i + 1;
        if (!j) { i = i + 1; continue; }
        i64 k = j;
        loop {
            if (k >= n) break;
            i64 d = ld8(raw + k);
            i64 ok = 0;
            if (d >= 97 && d <= 122) ok = 1;
            if (d >= 65 && d <= 90)  ok = 1;
            if (d >= 48 && d <= 57)  ok = 1;
            if (d == 95) ok = 1;
            if (!ok) break;
            k = k + 1;
        }
        if (k == j) { i = i + 1; continue; }
        i64 after = k;
        if (brace) {
            if (k >= n || ld8(raw + k) != 125) { i = i + 1; continue; }
            after = k + 1;
        }
        if (i > seg) {
            i64 lit = ph_strlit(xstrdup(raw + seg, i - seg), i - seg);
            if (acc) acc = ph_c2("php_str_concat", acc, lit, ty_pstr);
            if (!acc) acc = lit;
        }
        uptr d2 = xalloc(k - j + 2);
        st8(d2, 36);
        i64 z = 0;
        loop { if (z >= k - j) break; st8(d2 + 1 + z, ld8(raw + j + z)); z = z + 1; }
        st8(d2 + 1 + (k - j), 0);
        if (ph_var_find(d2) < 0) ph_refuse2(ph_tfile, ph_tline, "an undefined php variable in a string", d2, "D4");
        i64 vt = ph_var_type(d2);
        i64 v = node_new(N_IDENT, ph_tline, ph_tfile);
        set_nd_name(v, ph_mangle(d2, "v_"));
        set_nd_type(v, ph_mcty(vt));
        i64 sv = ph_to_str(v, vt);
        if (acc) acc = ph_c2("php_str_concat", acc, sv, ty_pstr);
        if (!acc) acc = sv;
        seg = after;
        i = after;
    }
    if (!acc) return ph_strlit(xstrdup(raw, n), n);
    if (n > seg) {
        i64 lit2 = ph_strlit(xstrdup(raw + seg, n - seg), n - seg);
        acc = ph_c2("php_str_concat", acc, lit2, ty_pstr);
    }
    return acc;
}

// an array literal, homogeneous: [1, 2, 3] / array("a", "b")
i64 ph_array_lit(uptr close) {
    ph_nonce = ph_nonce + 1;
    uptr an = p_cat("pha_", php_dec(ph_nonce), 0, cstrlen(php_dec(ph_nonce)));
    i64 et = -1;
    i64 head = 0;
    i64 tail = 0;
    loop {
        if (ph_at(close, 1)) break;
        i64 v = ph_expr(0);
        i64 vt = ph_ety;
        if (ph_at("=>", 2)) ph_todo(ph_tfile, ph_tline, "an array literal with keys");
        if (et < 0) et = vt;
        if (et != vt) {
            uptr m = p_cat(ph_tyname(et), " then ", 0, 6);
            m = p_cat(m, ph_tyname(vt), 0, cstrlen(ph_tyname(vt)));
            ph_todo2(ph_tfile, ph_tline, "a heterogeneous array literal", m);
        }
        i64 push = ph_c2("php_arr_push", 0, 0, TY_VOID);
        uptr fn = "php_arr_push";
        if (et == PT_FLOAT) fn = "php_arr_pushf";
        i64 aref = node_new(N_IDENT, ph_tline, ph_tfile);
        set_nd_name(aref, an);
        set_nd_type(aref, ty_parr);
        push = ph_c2(fn, aref, v, TY_VOID);
        i64 st = node_new(N_EXPRSTMT, ph_tline, ph_tfile);
        set_nd_a(st, push);
        if (tail) set_nd_next(tail, st);
        if (!tail) head = st;
        tail = st;
        if (!ph_accept(",", 1)) break;
    }
    ph_want(close, 1, "expected the end of a php array literal");
    if (et < 0) et = PT_INT;
    // A literal is a LOCAL plus a run of pushes emitted before the statement
    // that contains it (ph_pending_stmt), and the expression is the local --
    // mc has no comma operator and this needs none.
    ph_local(an, ty_parr);
    i64 mk = ph_set(an, ph_c1("php_arr_new", ph_int(8), ty_parr));
    set_nd_next(mk, head);
    ph_pending_stmt(mk);
    i64 out = node_new(N_IDENT, ph_tline, ph_tfile);
    set_nd_name(out, an);
    set_nd_type(out, ty_parr);
    ph_ety = PT_ARR + et;
    return out;
}

// statements an expression needs emitted BEFORE it (an array literal builds
// itself with a run of pushes). The statement parser drains this.
i64 ph_pend_head;
i64 ph_pend_tail;

void ph_pending_stmt(i64 s) {
    i64 t = s;
    loop { if (!nd_next(t)) break; t = nd_next(t); }
    if (ph_pend_tail) set_nd_next(ph_pend_tail, s);
    if (!ph_pend_tail) ph_pend_head = s;
    ph_pend_tail = t;
}

i64 ph_var_ref(uptr d) {
    if (ph_var_find(d) < 0) ph_refuse2(ph_tfile, ph_tline, "an undefined php variable", d, "D4");
    i64 t = ph_var_type(d);
    i64 n = node_new(N_IDENT, ph_tline, ph_tfile);
    set_nd_name(n, ph_mangle(d, "v_"));
    set_nd_type(n, ph_mcty(t));
    ph_ety = t;
    return n;
}

// $a[i] on the right-hand side
i64 ph_index(i64 base, i64 bt) {
    i64 et = ph_elem(bt);
    i64 idx = ph_to_int(ph_expr(0), ph_ety);
    ph_want("]", 1, "expected ] after a php array index");
    ph_ety = et;
    if (et == PT_FLOAT) return ph_c2("php_arr_getf", base, idx, ty_f64);
    i64 g = ph_c2("php_arr_get", base, idx, TY_I64);
    if (et == PT_STRING) return ph_cast(ty_pstr, g);
    if (et == PT_BOOL)   return ph_cast(TY_U8, g);
    return g;
}

i64 ph_primary() {
    i64 line = ph_tline;
    uptr fl = ph_tfile;

    if (ph_tid == PHT_DSTR) {
        i64 n = ph_tnode;
        ph_next();
        ph_ety = PT_STRING;
        return n;
    }
    if (ph_tid == PHT_PSTR) {
        uptr s = ph_tname;
        i64 n = ph_tlen;
        ph_next();
        ph_ety = PT_STRING;
        return ph_strlit(s, n);
    }
    if (ph_tid == T_INT) return ph_number();
    if (ph_tid == T_STR) {
        uptr s = ph_tname;
        i64 n = cstrlen(s);
        ph_next();
        ph_ety = PT_STRING;
        return ph_interp(s, n);
    }
    if (ph_at("$", 1)) {
        ph_next();
        if (ph_at("$", 1)) ph_refuse(fl, line, "a variable variable $$name", "D6");
        if (ph_at("{", 1)) ph_refuse(fl, line, "a variable variable ${expr}", "D6");
        if (ph_tid != T_IDENT) err_at2(fl, line, "mc-php: a php variable needs a name", ph_tname);
        uptr d = p_cat("$", ph_tname, 0, cstrlen(ph_tname));
        ph_next();
        i64 v = ph_var_ref(d);
        i64 vt = ph_ety;
        loop {
            if (ph_at("[", 1)) {
                if (!ph_is_arr(vt)) ph_refuse2(fl, line, "indexing a value that is not an array", ph_tyname(vt), "D4");
                ph_next();
                v = ph_index(v, vt);
                vt = ph_ety;
                continue;
            }
            if (ph_at("->", 2) || ph_at("?->", 3)) ph_todo(fl, line, "an object property or method");
            break;
        }
        ph_ety = vt;
        return v;
    }
    if (ph_at("(", 1)) {
        ph_next();
        // a cast: (int) (float) (string) (bool)
        if (ph_tid == T_IDENT || ph_tid == T_STR) {
            i64 ct = -1;
            if (ph_is("int") || ph_is("integer")) ct = PT_INT;
            if (ph_is("float") || ph_is("double")) ct = PT_FLOAT;
            if (ph_is("string")) ct = PT_STRING;
            if (ph_is("bool") || ph_is("boolean")) ct = PT_BOOL;
            if (ct >= 0) {
                // only a cast if the ) follows immediately
                uptr q = p_cp();
                uptr e = p_src_end();
                loop { if (q >= e) break; if (!ph_space(ld8(q))) break; q = q + 1; }
                if (q < e && ld8(q) == 41) {
                    ph_next();
                    ph_next();                     // the )
                    i64 v = ph_expr(55);
                    i64 vt = ph_ety;
                    ph_ety = ct;
                    if (ct == PT_INT)    return ph_to_int(v, vt);
                    if (ct == PT_FLOAT)  return ph_to_float(v, vt);
                    if (ct == PT_STRING) return ph_to_str(v, vt);
                    return ph_to_bool(v, vt);
                }
            }
        }
        i64 e2 = ph_expr(0);
        ph_want(")", 1, "expected ) in a php expression");
        return e2;
    }
    if (ph_at("[", 1)) { ph_next(); return ph_array_lit("]"); }
    if (ph_at("-", 1)) {
        ph_next();
        i64 v = ph_expr(70);
        i64 t = ph_ety;
        if (t == PT_FLOAT) return ph_bin(ph_tok("-", 1), ph_c1("php_fzero", ph_int(0), ty_f64), v, ty_f64);
        i64 iv = ph_to_int(v, t);
        ph_ety = PT_INT;
        return ph_bin(ph_tok("-", 1), ph_int(0), iv, TY_I64);
    }
    if (ph_at("+", 1)) { ph_next(); i64 v = ph_expr(70); return v; }
    if (ph_at("!", 1)) {
        ph_next();
        i64 v = ph_to_bool(ph_expr(70), ph_ety);
        ph_ety = PT_BOOL;
        i64 n = node_new(N_UNARY, line, fl);
        set_nd_op(n, ph_tok("!", 1));
        set_nd_a(n, v);
        set_nd_type(n, TY_U8);
        return n;
    }
    if (ph_at("@", 1)) ph_refuse(fl, line, "the @ error-suppression operator", "D1");
    if (ph_at("&", 1)) ph_todo(fl, line, "a reference &$x");
    if (ph_at("\\", 1)) { ph_next(); return ph_primary(); }   // a root-namespaced name
    if (ph_tid == T_IDENT) {
        uptr name = ph_tname;
        return ph_builtin(name, line, fl);
    }
    err_at2(fl, line, "mc-php: a php expression was expected", ph_tname);
    return 0;
}

// ---- PHP's precedence, the subset T5 reads ---------------------------------
i64 ph_prec(i64 t) {
    if (t == ph_tok("**", 2)) return 80;
    if (t == ph_tok("*", 1) || t == ph_tok("/", 1) || t == ph_tok("%", 1)) return 60;
    if (t == ph_tok("+", 1) || t == ph_tok("-", 1)) return 55;
    if (t == ph_tok(".", 1)) return 54;
    if (t == ph_tok("<<", 2) || t == ph_tok(">>", 2)) return 52;
    if (t == ph_tok("<", 1) || t == ph_tok(">", 1) || t == ph_tok("<=", 2) || t == ph_tok(">=", 2)) return 45;
    if (t == ph_tok("==", 2) || t == ph_tok("!=", 2) || t == ph_tok("===", 3)
        || t == ph_tok("!==", 3) || t == ph_tok("<>", 2) || t == ph_tok("<=>", 3)) return 40;
    if (t == ph_tok("&", 1)) return 38;
    if (t == ph_tok("^", 1)) return 37;
    if (t == ph_tok("|", 1)) return 36;
    if (t == ph_tok("&&", 2)) return 30;
    if (t == ph_tok("||", 2)) return 28;
    if (t == ph_tok("??", 2)) return 26;
    return -1;
}

i64 ph_arith(i64 op, i64 lhs, i64 lt, i64 rhs, i64 rt, uptr fl, i64 line) {
    // php's numeric promotion, with D4's static types
    if (lt == PT_STRING || rt == PT_STRING) {
        if (lt == PT_STRING) { lhs = ph_to_int(lhs, lt); lt = PT_INT; }
        if (rt == PT_STRING) { rhs = ph_to_int(rhs, rt); rt = PT_INT; }
    }
    if (lt == PT_BOOL) { lhs = ph_to_int(lhs, lt); lt = PT_INT; }
    if (rt == PT_BOOL) { rhs = ph_to_int(rhs, rt); rt = PT_INT; }
    if (lt == PT_IFALSE) lt = PT_INT;
    if (rt == PT_IFALSE) rt = PT_INT;
    i64 flt = 0;
    if (lt == PT_FLOAT || rt == PT_FLOAT) flt = 1;
    if (op == ph_tok("/", 1)) {
        if (!flt) ph_refuse(fl, line,
            "int / int (its type is int|float, which needs a zval; use intdiv() or a float operand)", "D4");
        ph_ety = PT_FLOAT;
        return ph_bin(op, ph_to_float(lhs, lt), ph_to_float(rhs, rt), ty_f64);
    }
    if (op == ph_tok("%", 1)) {
        ph_ety = PT_INT;
        return ph_c2("php_mod", ph_to_int(lhs, lt), ph_to_int(rhs, rt), TY_I64);
    }
    if (op == ph_tok("**", 2)) {
        if (flt) { ph_ety = PT_FLOAT; return ph_c2("php_pow_f", ph_to_float(lhs, lt), ph_to_int(rhs, rt), ty_f64); }
        ph_ety = PT_INT;
        return ph_c2("php_pow_i", ph_to_int(lhs, lt), ph_to_int(rhs, rt), TY_I64);
    }
    if (op == ph_tok("<<", 2) || op == ph_tok(">>", 2) || op == ph_tok("&", 1)
        || op == ph_tok("|", 1) || op == ph_tok("^", 1)) {
        ph_ety = PT_INT;
        return ph_bin(op, ph_to_int(lhs, lt), ph_to_int(rhs, rt), TY_I64);
    }
    if (flt) {
        ph_ety = PT_FLOAT;
        return ph_bin(op, ph_to_float(lhs, lt), ph_to_float(rhs, rt), ty_f64);
    }
    ph_ety = PT_INT;
    return ph_bin(op, lhs, rhs, TY_I64);
}

i64 ph_compare(i64 t, i64 lhs, i64 lt, i64 rhs, i64 rt, uptr fl, i64 line) {
    i64 strict = 0;
    if (t == ph_tok("===", 3) || t == ph_tok("!==", 3)) strict = 1;
    i64 neg = 0;
    if (t == ph_tok("!=", 2) || t == ph_tok("<>", 2) || t == ph_tok("!==", 3)) neg = 1;
    i64 eq = 0;
    if (t == ph_tok("==", 2) || t == ph_tok("!=", 2) || t == ph_tok("<>", 2) || strict) eq = 1;

    // the one union T5 has: `strpos(...) === false`
    if (lt == PT_IFALSE && rt == PT_BOOL && eq) {
        ph_ety = PT_BOOL;
        i64 op = ph_tok("==", 2);
        if (neg) op = ph_tok("!=", 2);
        return ph_cast(TY_U8, ph_bin(op, lhs, ph_int(-1), TY_U8));
    }
    if (strict && lt != rt) {
        if (lt == PT_IFALSE && rt == PT_INT) { lt = PT_INT; }
        else {
            ph_ety = PT_BOOL;
            if (neg) return ph_bool(1);
            return ph_bool(0);
        }
    }
    if (lt == PT_IFALSE) lt = PT_INT;
    if (rt == PT_IFALSE) rt = PT_INT;
    if (lt == PT_STRING && rt == PT_STRING) {
        i64 c = ph_c2("php_str_cmp", lhs, rhs, TY_I64);
        if (t == ph_tok("<=>", 3)) { ph_ety = PT_INT; return c; }
        i64 op = t;
        if (strict) { op = ph_tok("==", 2); if (neg) op = ph_tok("!=", 2); }
        if (op == ph_tok("<>", 2)) op = ph_tok("!=", 2);
        ph_ety = PT_BOOL;
        return ph_cast(TY_U8, ph_bin(op, c, ph_int(0), TY_U8));
    }
    if (lt == PT_STRING || rt == PT_STRING) {
        if (lt == PT_BOOL || rt == PT_BOOL) {
            lhs = ph_to_bool(lhs, lt); rhs = ph_to_bool(rhs, rt); lt = PT_BOOL; rt = PT_BOOL;
        } else {
            // php 8 compares a non-numeric string with a number AS STRINGS
            ph_refuse2(fl, line, "comparing a string with a number", ph_tyname(lt), "D4");
        }
    }
    if (ph_is_arr(lt) || ph_is_arr(rt)) ph_todo(fl, line, "comparing arrays");
    i64 flt = 0;
    if (lt == PT_FLOAT || rt == PT_FLOAT) flt = 1;
    i64 a = lhs;
    i64 b = rhs;
    if (flt) { a = ph_to_float(lhs, lt); b = ph_to_float(rhs, rt); }
    if (!flt) { a = ph_to_int(lhs, lt); b = ph_to_int(rhs, rt); }
    if (t == ph_tok("<=>", 3)) {
        ph_ety = PT_INT;
        if (flt) return ph_c2("php_cmp_f", a, b, TY_I64);
        return ph_c2("php_cmp_i", a, b, TY_I64);
    }
    i64 op2 = t;
    if (strict) { op2 = ph_tok("==", 2); if (neg) op2 = ph_tok("!=", 2); }
    if (op2 == ph_tok("<>", 2)) op2 = ph_tok("!=", 2);
    ph_ety = PT_BOOL;
    return ph_cast(TY_U8, ph_bin(op2, a, b, TY_U8));
}

i64 ph_expr(i64 minp) {
    i64 lhs = ph_primary();
    i64 lt = ph_ety;
    loop {
        i64 t = ph_tid;
        i64 pr = ph_prec(t);
        if (pr < 0) break;
        if (pr < minp) break;
        i64 line = ph_tline;
        uptr fl = ph_tfile;
        ph_next();
        i64 rhs = ph_expr(pr + 1);
        i64 rt = ph_ety;
        if (t == ph_tok(".", 1)) {
            lhs = ph_c2("php_str_concat", ph_to_str(lhs, lt), ph_to_str(rhs, rt), ty_pstr);
            lt = PT_STRING;
            continue;
        }
        if (t == ph_tok("&&", 2) || t == ph_tok("||", 2)) {
            i64 op = ph_tok("&&", 2);
            if (t == ph_tok("||", 2)) op = ph_tok("||", 2);
            lhs = ph_bin(op, ph_to_bool(lhs, lt), ph_to_bool(rhs, rt), TY_U8);
            set_nd_type(lhs, TY_U8);
            lt = PT_BOOL;
            continue;
        }
        if (t == ph_tok("??", 2)) ph_refuse(fl, line, "the ?? operator (its type is a union)", "D4");
        if (ph_prec(t) == 45 || ph_prec(t) == 40) {
            lhs = ph_compare(t, lhs, lt, rhs, rt, fl, line);
            lt = ph_ety;
            continue;
        }
        lhs = ph_arith(t, lhs, lt, rhs, rt, fl, line);
        lt = ph_ety;
    }
    ph_ety = lt;
    return lhs;
}

// ---- the builtin functions T5 implements ----------------------------------
// Each is an mc function in php_rt.txt that the compiler calls with the static
// types it already knows, so there is no dispatch at run time. A name that is
// not here is a named compile error, never a silent miss.
// A nested call must not clobber the caller's arguments, so each frame gets
// its own buffer: node at [i*16], php type at [i*16+8].
i64 ph_nargs;

uptr ph_read_args(i64 maxn, uptr fl, i64 line, uptr pn) {
    uptr buf = xalloc(maxn * 16 + 16);
    i64 n = 0;
    ph_want("(", 1, "expected ( in a php call");
    loop {
        if (ph_at(")", 1)) break;
        if (ph_at("...", 3)) ph_todo(fl, line, "argument unpacking ...$args");
        i64 a = ph_expr(0);
        i64 t = ph_ety;
        if (n >= maxn) ph_todo(fl, line, "too many arguments for this builtin");
        st64(buf + n * 16, a);
        st64(buf + n * 16 + 8, t);
        n = n + 1;
        if (!ph_accept(",", 1)) break;
    }
    ph_want(")", 1, "expected ) in a php call");
    st64(pn, n);
    return buf;
}

i64 ph_a(uptr av, i64 i) { return ld64(av + i * 16); }
i64 ph_aty(uptr av, i64 i) { return ld64(av + i * 16 + 8); }

void ph_need(i64 have, i64 n, uptr name, uptr fl, i64 line) {
    if (have != n) ph_todo2(fl, line, "the wrong number of arguments for", name);
}

// var_dump of one value, by its static type
i64 ph_vd(i64 v, i64 t, uptr fl, i64 line) {
    if (t == PT_INT)    return ph_c1("php_vd_int", v, TY_VOID);
    if (t == PT_IFALSE) return ph_c1("php_vd_ifalse", v, TY_VOID);
    if (t == PT_BOOL)   return ph_c1("php_vd_bool", v, TY_VOID);
    if (t == PT_FLOAT)  return ph_c1("php_vd_float", v, TY_VOID);
    if (t == PT_STRING) return ph_c1("php_vd_str", v, TY_VOID);
    if (t == PT_NULL)   return ph_call("php_vd_null", 0, 0, 0, 0, 0, TY_VOID);
    if (ph_is_arr(t))   return ph_c3("php_vd_arr", v, ph_int(ph_elem(t)), ph_int(0), TY_VOID);
    ph_todo2(fl, line, "var_dump of", ph_tyname(t));
    return 0;
}

i64 ph_echo_of(i64 v, i64 t, uptr fl, i64 line) {
    if (t == PT_INT || t == PT_IFALSE) return ph_c1("php_echo_int", v, TY_I64);
    if (t == PT_BOOL)   return ph_c1("php_echo_bool", v, TY_I64);
    if (t == PT_FLOAT)  return ph_c1("php_echo_float", v, TY_I64);
    if (t == PT_STRING) return ph_c1("php_echo_str", v, TY_I64);
    ph_todo2(fl, line, "echo of", ph_tyname(t));
    return 0;
}

// sprintf/printf: the FORMAT must be a literal, so the conversion is compiled
// into a chain of concatenations and there is no run-time format walker.
i64 ph_sprintf(uptr av, i64 na, uptr fl, i64 line) {
    i64 f = ph_a(av, 0);
    if (ph_aty(av, 0) != PT_STRING) ph_todo(fl, line, "a printf format that is not a string");
    if (nd_kind(f) != N_CALL || !str_eq(nd_name(f), "php_str_lit"))
        ph_refuse(fl, line, "a printf format that is not a literal", "D1");
    i64 raw = nd_next(nd_a(f));                     // the N_STR argument
    uptr b = nd_name(raw);
    i64 n = nd_val(raw);
    i64 acc = 0;
    i64 seg = 0;
    i64 i = 0;
    i64 ai = 1;
    loop {
        if (i >= n) break;
        if (ld8(b + i) != 37) { i = i + 1; continue; }
        if (i > seg) {
            i64 lit = ph_strlit(xstrdup(b + seg, i - seg), i - seg);
            if (acc) acc = ph_c2("php_str_concat", acc, lit, ty_pstr);
            if (!acc) acc = lit;
        }
        i64 c = 0;
        if (i + 1 < n) c = ld8(b + i + 1);
        i64 piece = 0;
        if (c == 37) piece = ph_strlit("%", 1);
        if (c == 100 || c == 115 || c == 102) {
            if (ai >= na) ph_todo(fl, line, "a printf format with more conversions than arguments");
            i64 v = ph_a(av, ai);
            i64 vt = ph_aty(av, ai);
            ai = ai + 1;
            if (c == 100) piece = ph_to_str(ph_to_int(v, vt), PT_INT);
            if (c == 115) piece = ph_to_str(v, vt);
            if (c == 102) piece = ph_c1("php_ftos6", ph_to_float(v, vt), ty_pstr);
        }
        if (!piece) {
            uptr w = xalloc(4);
            st8(w, 37); st8(w + 1, c); st8(w + 2, 0);
            ph_todo2(fl, line, "a printf conversion T5 does not have", w);
        }
        if (acc) acc = ph_c2("php_str_concat", acc, piece, ty_pstr);
        if (!acc) acc = piece;
        i = i + 2;
        seg = i;
    }
    if (n > seg) {
        i64 lit2 = ph_strlit(xstrdup(b + seg, n - seg), n - seg);
        if (acc) acc = ph_c2("php_str_concat", acc, lit2, ty_pstr);
        if (!acc) acc = lit2;
    }
    if (!acc) acc = ph_strlit("", 0);
    ph_ety = PT_STRING;
    return acc;
}

i64 ph_builtin(uptr name, i64 line, uptr fl) {
    // D1 and D6: the named refusals, before anything else
    if (str_eq(name, "eval")) ph_refuse(fl, line, "eval", "D1");
    if (str_eq(name, "create_function")) ph_refuse(fl, line, "create_function", "D1");
    if (str_eq(name, "assert")) ph_refuse(fl, line, "assert with a string argument", "D1");
    if (str_eq(name, "extract") || str_eq(name, "compact")) ph_refuse2(fl, line, "the symbol-table function", name, "D6");
    if (str_eq(name, "get_class_methods") || str_eq(name, "get_object_vars")
        || str_eq(name, "get_class_vars") || str_eq(name, "func_get_args")
        || str_eq(name, "debug_backtrace") || str_eq(name, "call_user_func")
        || str_eq(name, "call_user_func_array") || str_eq(name, "get_defined_vars"))
        ph_refuse2(fl, line, "the reflection function", name, "D6");
    if (cstrlen(name) > 10) {
        if (str_eq(xstrdup(name, 10), "Reflection")) ph_refuse2(fl, line, "the reflection class", name, "D6");
    }

    // the constants, before the ( is required
    if (str_eq(name, "true"))  { ph_next(); ph_ety = PT_BOOL; return ph_bool(1); }
    if (str_eq(name, "false")) { ph_next(); ph_ety = PT_BOOL; return ph_bool(0); }
    if (str_eq(name, "null") || str_eq(name, "NULL")) {
        ph_next();
        ph_ety = PT_NULL;
        return ph_int(0);
    }
    if (str_eq(name, "PHP_EOL"))      { ph_next(); ph_ety = PT_STRING; return ph_strlit("\n", 1); }
    if (str_eq(name, "PHP_INT_MAX"))  { ph_next(); ph_ety = PT_INT; return ph_int(9223372036854775807); }
    if (str_eq(name, "PHP_INT_MIN"))  { ph_next(); ph_ety = PT_INT; return ph_bin(ph_tok("-", 1), ph_int(-9223372036854775807), ph_int(1), TY_I64); }
    if (str_eq(name, "PHP_INT_SIZE")) { ph_next(); ph_ety = PT_INT; return ph_int(8); }
    if (str_eq(name, "PHP_FLOAT_DIG")) { ph_next(); ph_ety = PT_INT; return ph_int(15); }
    if (str_eq(name, "STR_PAD_RIGHT")) { ph_next(); ph_ety = PT_INT; return ph_int(0); }
    if (str_eq(name, "STR_PAD_LEFT"))  { ph_next(); ph_ety = PT_INT; return ph_int(1); }
    if (str_eq(name, "STR_PAD_BOTH"))  { ph_next(); ph_ety = PT_INT; return ph_int(2); }
    if (str_eq(name, "__LINE__")) { i64 l = ph_tline; ph_next(); ph_ety = PT_INT; return ph_int(l); }
    if (str_eq(name, "__FILE__")) {
        uptr f = ph_tfile;
        ph_next();
        ph_ety = PT_STRING;
        return ph_strlit(f, cstrlen(f));
    }
    if (str_eq(name, "__DIR__")) {
        uptr f = path_norm(path_join(ph_tfile, "."));
        ph_next();
        ph_ety = PT_STRING;
        return ph_strlit(f, cstrlen(f));
    }
    if (str_eq(name, "__FUNCTION__") || str_eq(name, "__METHOD__")) {
        uptr f2 = p_decl_name();
        ph_next();
        ph_ety = PT_STRING;
        if (!f2) return ph_strlit("", 0);
        return ph_strlit(f2 + 2, cstrlen(f2 + 2));
    }
    // a constant this program declared with `const` or define()
    i64 ci = ph_const_find(name);
    if (ci >= 0) {
        ph_next();
        i64 ct = ld64(ph_cty + ci * 8);
        ph_ety = ct;
        if (ct == PT_STRING) return ph_strlit(ld64(ph_cstr + ci * 8), ld64(ph_cval + ci * 8));
        if (ct == PT_BOOL)   return ph_bool(ld64(ph_cval + ci * 8));
        return ph_int(ld64(ph_cval + ci * 8));
    }

    if (str_eq(name, "array")) {
        ph_next();
        if (!ph_at("(", 1)) ph_todo2(fl, line, "a php constant T5 does not have", name);
        ph_next();
        return ph_array_lit(")");
    }
    // D4 makes these compile-time answers too: a variable HAS a type or it does
    // not exist, and there is no null to be unset.
    if (str_eq(name, "isset") || str_eq(name, "empty")) {
        i64 isempty = str_eq(name, "empty");
        ph_next();
        ph_want("(", 1, "expected ( in a php call");
        if (!ph_at("$", 1)) ph_todo2(fl, line, "isset/empty of", "something that is not a $variable");
        ph_next();
        if (ph_tid != T_IDENT) err_at(fl, line, "mc-php: a php variable needs a name");
        uptr d = p_cat("$", ph_tname, 0, cstrlen(ph_tname));
        ph_next();
        i64 known = 0;
        if (ph_var_find(d) >= 0) known = 1;
        if (ph_at("[", 1)) ph_todo(fl, line, "isset/empty of an array element");
        ph_want(")", 1, "expected ) in a php call");
        ph_ety = PT_BOOL;
        if (!isempty) return ph_bool(known);
        if (!known) return ph_bool(1);
        i64 t = ph_var_type(d);
        i64 v = node_new(N_IDENT, line, fl);
        set_nd_name(v, ph_mangle(d, "v_"));
        set_nd_type(v, ph_mcty(t));
        i64 b = ph_to_bool(v, t);
        i64 nn = node_new(N_UNARY, line, fl);
        set_nd_op(nn, ph_tok("!", 1));
        set_nd_a(nn, b);
        set_nd_type(nn, TY_U8);
        ph_ety = PT_BOOL;
        return nn;
    }
    ph_next();
    if (!ph_at("(", 1)) {
        if (ph_at("::", 2)) ph_todo(fl, line, "a class constant or static member");
        ph_todo2(fl, line, "a php constant T5 does not have", name);
    }

    if (str_eq(name, "sprintf") || str_eq(name, "printf")) {
        u8 pn0[8];
        uptr av0 = ph_read_args(16, fl, line, pn0);
        i64 s = ph_sprintf(av0, ld64(pn0), fl, line);
        if (str_eq(name, "sprintf")) { ph_ety = PT_STRING; return s; }
        i64 e = ph_c1("php_echo_str", s, TY_I64);
        ph_ety = PT_INT;
        return ph_c2("php_seq_i", e, ph_int(0), TY_I64);
    }

    u8 pnb[8];
    uptr av = ph_read_args(16, fl, line, pnb);
    i64 na = ld64(pnb);
    i64 a0 = 0;
    i64 t0 = -1;
    if (na >= 1) { a0 = ph_a(av, 0); t0 = ph_aty(av, 0); }

    if (str_eq(name, "var_dump")) {
        i64 head = 0;
        i64 tail = 0;
        i64 i = 0;
        loop {
            if (i >= na) break;
            i64 c = ph_vd(ph_a(av, i), ph_aty(av, i), fl, line);
            i64 s = node_new(N_EXPRSTMT, line, fl);
            set_nd_a(s, c);
            if (tail) set_nd_next(tail, s);
            if (!tail) head = s;
            tail = s;
            i = i + 1;
        }
        ph_pending_stmt(head);
        ph_ety = PT_NULL;
        return ph_int(0);
    }
    if (str_eq(name, "strlen"))   { ph_need(na, 1, name, fl, line); ph_ety = PT_INT; return ph_c1("php_strlen", ph_to_str(a0, t0), TY_I64); }
    if (str_eq(name, "count") || str_eq(name, "sizeof")) {
        ph_need(na, 1, name, fl, line);
        if (!ph_is_arr(t0)) ph_todo2(fl, line, "count() of", ph_tyname(t0));
        ph_ety = PT_INT;
        return ph_c1("php_count", a0, TY_I64);
    }
    if (str_eq(name, "str_repeat")) {
        ph_need(na, 2, name, fl, line);
        ph_ety = PT_STRING;
        return ph_c2("php_str_repeat", ph_to_str(a0, t0), ph_to_int(ph_a(av, 1), ph_aty(av, 1)), ty_pstr);
    }
    if (str_eq(name, "substr")) {
        if (na < 2 || na > 3) ph_need(na, 2, name, fl, line);
        i64 len = ph_int(0);
        i64 has = 0;
        if (na == 3) { len = ph_to_int(ph_a(av, 2), ph_aty(av, 2)); has = 1; }
        ph_ety = PT_STRING;
        return ph_c4("php_substr", ph_to_str(a0, t0), ph_to_int(ph_a(av, 1), ph_aty(av, 1)), len, ph_int(has), ty_pstr);
    }
    if (str_eq(name, "strpos")) {
        if (na < 2 || na > 3) ph_need(na, 2, name, fl, line);
        i64 off = ph_int(0);
        if (na == 3) off = ph_to_int(ph_a(av, 2), ph_aty(av, 2));
        ph_ety = PT_IFALSE;
        return ph_c3("php_strpos", ph_to_str(a0, t0), ph_to_str(ph_a(av, 1), ph_aty(av, 1)), off, TY_I64);
    }
    if (str_eq(name, "str_replace")) {
        ph_need(na, 3, name, fl, line);
        ph_ety = PT_STRING;
        return ph_c3("php_str_replace", ph_to_str(a0, t0), ph_to_str(ph_a(av, 1), ph_aty(av, 1)),
                     ph_to_str(ph_a(av, 2), ph_aty(av, 2)), ty_pstr);
    }
    if (str_eq(name, "implode") || str_eq(name, "join")) {
        ph_need(na, 2, name, fl, line);
        i64 sep = a0;
        i64 arr = ph_a(av, 1);
        i64 at = ph_aty(av, 1);
        if (!ph_is_arr(at)) {                            // implode($arr, $sep), the legacy order
            sep = ph_a(av, 1); arr = a0; at = t0;
        }
        if (!ph_is_arr(at)) ph_todo(fl, line, "implode() without an array");
        if (ph_elem(at) != PT_STRING) ph_todo2(fl, line, "implode() of", ph_tyname(at));
        ph_ety = PT_STRING;
        return ph_c2("php_implode", ph_to_str(sep, PT_STRING), arr, ty_pstr);
    }
    if (str_eq(name, "explode")) {
        if (na != 2) ph_need(na, 2, name, fl, line);
        ph_ety = PT_ARR + PT_STRING;
        return ph_c2("php_explode", ph_to_str(a0, t0), ph_to_str(ph_a(av, 1), ph_aty(av, 1)), ty_parr);
    }
    if (str_eq(name, "intdiv")) {
        ph_need(na, 2, name, fl, line);
        ph_ety = PT_INT;
        return ph_c2("php_intdiv", ph_to_int(a0, t0), ph_to_int(ph_a(av, 1), ph_aty(av, 1)), TY_I64);
    }
    if (str_eq(name, "abs")) {
        ph_need(na, 1, name, fl, line);
        if (t0 == PT_FLOAT) { ph_ety = PT_FLOAT; return ph_c1("php_abs_f", a0, ty_f64); }
        ph_ety = PT_INT;
        return ph_c1("php_abs_i", ph_to_int(a0, t0), TY_I64);
    }
    if (str_eq(name, "max") || str_eq(name, "min")) {
        ph_need(na, 2, name, fl, line);
        i64 t1 = ph_aty(av, 1);
        if (t0 == PT_FLOAT || t1 == PT_FLOAT) {
            ph_ety = PT_FLOAT;
            uptr f = "php_max_f";
            if (str_eq(name, "min")) f = "php_min_f";
            return ph_c2(f, ph_to_float(a0, t0), ph_to_float(ph_a(av, 1), t1), ty_f64);
        }
        ph_ety = PT_INT;
        uptr f2 = "php_max_i";
        if (str_eq(name, "min")) f2 = "php_min_i";
        return ph_c2(f2, ph_to_int(a0, t0), ph_to_int(ph_a(av, 1), t1), TY_I64);
    }
    if (str_eq(name, "define")) {
        ph_need(na, 2, name, fl, line);
        if (t0 != PT_STRING || nd_kind(a0) != N_CALL || !str_eq(nd_name(a0), "php_str_lit"))
            ph_refuse(fl, line, "define() with a computed name", "D1");
        i64 rawn = nd_next(nd_a(a0));
        ph_const_add(xstrdup(nd_name(rawn), nd_val(rawn)), ph_a(av, 1), ph_aty(av, 1), fl, line);
        ph_ety = PT_BOOL;
        return ph_bool(1);
    }
    if (str_eq(name, "defined")) {
        ph_need(na, 1, name, fl, line);
        if (t0 != PT_STRING || nd_kind(a0) != N_CALL || !str_eq(nd_name(a0), "php_str_lit"))
            ph_refuse(fl, line, "defined() with a computed name", "D1");
        i64 rawd = nd_next(nd_a(a0));
        ph_ety = PT_BOOL;
        if (ph_const_find(xstrdup(nd_name(rawd), nd_val(rawd))) >= 0) return ph_bool(1);
        return ph_bool(0);
    }
    if (str_eq(name, "chr")) { ph_need(na, 1, name, fl, line); ph_ety = PT_STRING; return ph_c1("php_chr", ph_to_int(a0, t0), ty_pstr); }
    if (str_eq(name, "ord")) { ph_need(na, 1, name, fl, line); ph_ety = PT_INT; return ph_c1("php_ord", ph_to_str(a0, t0), TY_I64); }
    if (str_eq(name, "strtoupper")) { ph_need(na, 1, name, fl, line); ph_ety = PT_STRING; return ph_c1("php_strtoupper", ph_to_str(a0, t0), ty_pstr); }
    if (str_eq(name, "strtolower")) { ph_need(na, 1, name, fl, line); ph_ety = PT_STRING; return ph_c1("php_strtolower", ph_to_str(a0, t0), ty_pstr); }
    if (str_eq(name, "ucfirst")) { ph_need(na, 1, name, fl, line); ph_ety = PT_STRING; return ph_c1("php_ucfirst", ph_to_str(a0, t0), ty_pstr); }
    if (str_eq(name, "lcfirst")) { ph_need(na, 1, name, fl, line); ph_ety = PT_STRING; return ph_c1("php_lcfirst", ph_to_str(a0, t0), ty_pstr); }
    if (str_eq(name, "strrev")) { ph_need(na, 1, name, fl, line); ph_ety = PT_STRING; return ph_c1("php_strrev", ph_to_str(a0, t0), ty_pstr); }
    if (str_eq(name, "trim") || str_eq(name, "ltrim") || str_eq(name, "rtrim")) {
        if (na != 1) ph_todo2(fl, line, "a trim with a charlist", name);
        i64 mode = 0;
        if (str_eq(name, "ltrim")) mode = 1;
        if (str_eq(name, "rtrim")) mode = 2;
        ph_ety = PT_STRING;
        return ph_c2("php_trim", ph_to_str(a0, t0), ph_int(mode), ty_pstr);
    }
    if (str_eq(name, "str_pad")) {
        if (na < 2 || na > 4) ph_need(na, 2, name, fl, line);
        i64 pad = ph_strlit(" ", 1);
        i64 type = ph_int(0);
        if (na >= 3) pad = ph_to_str(ph_a(av, 2), ph_aty(av, 2));
        if (na >= 4) type = ph_to_int(ph_a(av, 3), ph_aty(av, 3));
        ph_ety = PT_STRING;
        return ph_c4("php_str_pad", ph_to_str(a0, t0), ph_to_int(ph_a(av, 1), ph_aty(av, 1)), pad, type, ty_pstr);
    }
    if (str_eq(name, "str_contains")) { ph_need(na, 2, name, fl, line); ph_ety = PT_BOOL; return ph_c2("php_str_contains", ph_to_str(a0, t0), ph_to_str(ph_a(av, 1), ph_aty(av, 1)), TY_U8); }
    if (str_eq(name, "str_starts_with")) { ph_need(na, 2, name, fl, line); ph_ety = PT_BOOL; return ph_c2("php_str_starts", ph_to_str(a0, t0), ph_to_str(ph_a(av, 1), ph_aty(av, 1)), TY_U8); }
    if (str_eq(name, "str_ends_with")) { ph_need(na, 2, name, fl, line); ph_ety = PT_BOOL; return ph_c2("php_str_ends", ph_to_str(a0, t0), ph_to_str(ph_a(av, 1), ph_aty(av, 1)), TY_U8); }
    if (str_eq(name, "strcmp")) { ph_need(na, 2, name, fl, line); ph_ety = PT_INT; return ph_c2("php_str_cmp", ph_to_str(a0, t0), ph_to_str(ph_a(av, 1), ph_aty(av, 1)), TY_I64); }
    if (str_eq(name, "strcasecmp")) { ph_need(na, 2, name, fl, line); ph_ety = PT_INT; return ph_c2("php_strcasecmp", ph_to_str(a0, t0), ph_to_str(ph_a(av, 1), ph_aty(av, 1)), TY_I64); }
    if (str_eq(name, "intval")) { ph_need(na, 1, name, fl, line); ph_ety = PT_INT;    return ph_to_int(a0, t0); }
    if (str_eq(name, "strval")) { ph_need(na, 1, name, fl, line); ph_ety = PT_STRING; return ph_to_str(a0, t0); }
    if (str_eq(name, "floatval") || str_eq(name, "doubleval")) { ph_need(na, 1, name, fl, line); ph_ety = PT_FLOAT; return ph_to_float(a0, t0); }
    if (str_eq(name, "boolval")) { ph_need(na, 1, name, fl, line); ph_ety = PT_BOOL; return ph_to_bool(a0, t0); }
    // D4 makes these compile-time constants: the type IS static
    if (str_eq(name, "is_int") || str_eq(name, "is_integer") || str_eq(name, "is_long")) {
        ph_need(na, 1, name, fl, line); ph_ety = PT_BOOL;
        if (t0 == PT_INT) return ph_bool(1);
        return ph_bool(0);
    }
    if (str_eq(name, "is_string")) { ph_need(na, 1, name, fl, line); ph_ety = PT_BOOL; if (t0 == PT_STRING) return ph_bool(1); return ph_bool(0); }
    if (str_eq(name, "is_float") || str_eq(name, "is_double")) { ph_need(na, 1, name, fl, line); ph_ety = PT_BOOL; if (t0 == PT_FLOAT) return ph_bool(1); return ph_bool(0); }
    if (str_eq(name, "is_bool")) { ph_need(na, 1, name, fl, line); ph_ety = PT_BOOL; if (t0 == PT_BOOL) return ph_bool(1); return ph_bool(0); }
    if (str_eq(name, "is_array")) { ph_need(na, 1, name, fl, line); ph_ety = PT_BOOL; if (ph_is_arr(t0)) return ph_bool(1); return ph_bool(0); }
    if (str_eq(name, "is_null")) { ph_need(na, 1, name, fl, line); ph_ety = PT_BOOL; if (t0 == PT_NULL) return ph_bool(1); return ph_bool(0); }
    if (str_eq(name, "is_numeric")) { ph_need(na, 1, name, fl, line); ph_ety = PT_BOOL; if (t0 == PT_INT || t0 == PT_FLOAT) return ph_bool(1); return ph_bool(0); }
    if (str_eq(name, "function_exists")) { ph_ety = PT_BOOL; return ph_bool(0); }

    // a php function this program declared
    i64 fi = ph_fn_find(name);
    if (fi < 0) ph_todo2(fl, line, "a php function T5 does not have", name);
    i64 np = ld64(ph_fnp + fi * 8);
    if (na != np) ph_todo2(fl, line, "the wrong number of arguments for", name);
    i64 head = 0;
    i64 tail = 0;
    i64 i = 0;
    loop {
        if (i >= np) break;
        i64 want = ld64(ph_fpt + (fi * PH_MAXP + i) * 8);
        i64 v = ph_a(av, i);
        i64 have = ph_aty(av, i);
        if (want == PT_INT)    v = ph_to_int(v, have);
        if (want == PT_FLOAT)  v = ph_to_float(v, have);
        if (want == PT_STRING) v = ph_to_str(v, have);
        if (want == PT_BOOL)   v = ph_to_bool(v, have);
        if (tail) set_nd_next(tail, v);
        if (!tail) head = v;
        tail = v;
        i = i + 1;
    }
    i64 c = node_new(N_CALL, line, fl);
    set_nd_name(c, ph_mangle(name, "f_"));
    set_nd_a(c, head);
    i64 rt = ld64(ph_fret + fi * 8);
    set_nd_type(c, ph_mcty(rt));
    ph_ety = rt;
    return c;
}

// ---- statements ------------------------------------------------------------
// the pending statements an expression asked for (an array literal, var_dump)
// the pending statements are SPLICED into the enclosing list, never wrapped in
// a block: a block would scope what they declare (see ph_local).
i64 ph_wrap(i64 s) {
    if (!ph_pend_head) return s;
    i64 h = ph_pend_head;
    i64 t = ph_pend_tail;
    ph_pend_head = 0;
    ph_pend_tail = 0;
    set_nd_next(t, s);
    return h;
}

i64 ph_expr_stmt_of(i64 e) {
    i64 s = node_new(N_EXPRSTMT, ph_tline, ph_tfile);
    set_nd_a(s, e);
    return ph_wrap(s);
}

i64 ph_empty() { return node_new(N_BLOCK, ph_tline, ph_tfile); }

// a run of inline html between ?> and <?php, and the statement that prints it
i64 ph_inline_html(uptr fl, i64 line) {
    uptr q = p_cp();
    uptr e = p_src_end();
    uptr start = q;
    if (q < e && ld8(q) == 10) start = q + 1;                 // php eats one \n after ?>
    if (q + 1 < e && ld8(q) == 13 && ld8(q + 1) == 10) start = q + 2;
    uptr stop = e;
    uptr nxt = e;
    loop {
        if (q + 4 >= e) break;
        if (ld8(q) == 60 && ld8(q + 1) == 63) {               // <?
            if (ld8(q + 2) == 112 && ld8(q + 3) == 104 && ld8(q + 4) == 112) { stop = q; nxt = q + 5; break; }
            if (ld8(q + 2) == 61) { stop = q; nxt = q + 3; break; }
        }
        q = q + 1;
    }
    if (stop == e) { if (q + 4 >= e) stop = e; }
    i64 n = stop - start;
    if (n < 0) n = 0;
    p_skip_to(nxt);
    ph_tid = PHT_HTML;
    ph_tname = xstrdup(start, n);
    ph_tlen = n;
    if (n == 0) { ph_next(); return ph_empty(); }
    i64 c = ph_c1("php_echo_str", ph_strlit(ph_tname, n), TY_I64);
    ph_next();
    i64 s = node_new(N_EXPRSTMT, line, fl);
    set_nd_a(s, c);
    return s;
}

i64 ph_block() {
    i64 line = ph_tline;
    uptr fl = ph_tfile;
    ph_want("{", 1, "expected { in php");
    i64 head = 0;
    i64 tail = 0;
    loop {
        if (ph_at("}", 1)) break;
        if (ph_tid == T_EOF) err_at(fl, line, "mc-php: unterminated php block");
        i64 s = ph_stmt();
        if (tail) set_nd_next(tail, s);
        if (!tail) head = s;
        tail = s;
        loop { if (!nd_next(tail)) break; tail = nd_next(tail); }
    }
    ph_next();
    i64 b = node_new(N_BLOCK, line, fl);
    set_nd_a(b, head);
    return b;
}

i64 ph_block_or_stmt() {
    if (ph_at("{", 1)) return ph_block();
    return ph_stmt();
}

// `continue` jumps to the top of an mc `loop`, so a step appended after the
// body would be SKIPPED by it -- an infinite loop, measured on
// `for (...; $i++) { if (c) continue; }`. The step therefore runs at the TOP,
// guarded by a first-iteration flag, which is the one lowering where every
// edge into the next iteration passes through it.
i64 ph_loop_of(i64 cond, i64 body, i64 step, i64 line, uptr fl) {
    i64 pre = 0;
    if (step) {
        ph_nonce = ph_nonce + 1;
        uptr fn = p_cat("phl_f", php_dec(ph_nonce), 0, cstrlen(php_dec(ph_nonce)));
        ph_local(fn, TY_I64);
        pre = ph_set(fn, ph_int(1));                 // emitted by the caller? no: here
        i64 fref = node_new(N_IDENT, line, fl);
        set_nd_name(fref, fn);
        set_nd_type(fref, TY_I64);
        i64 clr = ph_set(fn, ph_int(0));
        i64 gate = node_new(N_IF, line, fl);
        set_nd_a(gate, fref);
        set_nd_b(gate, clr);
        set_nd_c(gate, step);
        step = 0;
        set_nd_next(gate, 0);
        i64 nb = node_new(N_BLOCK, line, fl);        // gate, then the old body
        set_nd_a(nb, gate);
        i64 hold = body;
        body = gate;
        set_nd_next(gate, hold);
        // `pre` (the flag = 1) has to run before the loop: the caller splices
        // it in through ph_loop_pre.
        ph_loop_pre = pre;
    }
    i64 neg = node_new(N_UNARY, line, fl);
    set_nd_op(neg, ph_tok("!", 1));
    set_nd_a(neg, cond);
    set_nd_type(neg, TY_U8);
    i64 brk = node_new(N_BREAK, line, fl);
    set_nd_val(brk, 1);
    i64 iff = node_new(N_IF, line, fl);
    set_nd_a(iff, neg);
    set_nd_b(iff, brk);
    // body already begins with the step gate when there is a step
    i64 first = body;
    if (nd_kind(body) == N_IF && ph_loop_pre) {
        // the gate is first; the condition test goes between it and the body
        i64 rest = nd_next(body);
        set_nd_next(body, iff);
        set_nd_next(iff, rest);
        first = body;
    }
    if (!ph_loop_pre) {
        set_nd_next(iff, body);
        first = iff;
    }
    i64 b = node_new(N_BLOCK, line, fl);
    set_nd_a(b, first);
    i64 lp = node_new(N_LOOP, line, fl);
    set_nd_a(lp, b);
    if (ph_loop_pre) {
        i64 pr = ph_loop_pre;
        ph_loop_pre = 0;
        set_nd_next(pr, lp);
        i64 ob = node_new(N_BLOCK, line, fl);
        set_nd_a(ob, pr);
        return ob;
    }
    return lp;
}

// $v = expr / $v[i] = expr / $v[] = expr, and the compound forms
i64 ph_assign_stmt(uptr fl, i64 line, i64 semi) {
    ph_next();                                       // $
    if (ph_at("$", 1)) ph_refuse(fl, line, "a variable variable $$name", "D6");
    if (ph_tid != T_IDENT) err_at2(fl, line, "mc-php: a php variable needs a name", ph_tname);
    uptr d = p_cat("$", ph_tname, 0, cstrlen(ph_tname));
    ph_next();

    if (ph_at("[", 1)) {
        if (ph_var_find(d) < 0) ph_refuse2(fl, line, "an undefined php array", d, "D4");
        i64 at = ph_var_type(d);
        if (!ph_is_arr(at)) ph_refuse2(fl, line, "indexing a value that is not an array", ph_tyname(at), "D4");
        ph_next();
        i64 idx = 0;
        i64 append = 1;
        if (!ph_at("]", 1)) { idx = ph_to_int(ph_expr(0), ph_ety); append = 0; }
        ph_want("]", 1, "expected ] in a php array assignment");
        ph_want("=", 1, "expected = after a php array index");
        i64 v = ph_expr(0);
        i64 vt = ph_ety;
        i64 et = ph_elem(at);
        if (vt != et) {
            uptr m = p_cat(ph_tyname(et), " assigned ", 0, 10);
            m = p_cat(m, ph_tyname(vt), 0, cstrlen(ph_tyname(vt)));
            ph_todo2(fl, line, "a heterogeneous array", m);
        }
        ph_want(";", 1, "expected ; after a php assignment");
        i64 aref = node_new(N_IDENT, line, fl);
        set_nd_name(aref, ph_mangle(d, "v_"));
        set_nd_type(aref, ty_parr);
        uptr fn = "php_arr_push";
        if (!append) fn = "php_arr_set";
        if (et == PT_FLOAT) { if (append) fn = "php_arr_pushf"; if (!append) fn = "php_arr_setf"; }
        i64 c = 0;
        if (append) c = ph_c2(fn, aref, v, TY_VOID);
        if (!append) c = ph_c3(fn, aref, idx, v, TY_VOID);
        return ph_expr_stmt_of(c);
    }

    i64 op = 0;
    if (ph_at(".=", 2))  op = ph_tok(".", 1);
    if (ph_at("+=", 2))  op = ph_tok("+", 1);
    if (ph_at("-=", 2))  op = ph_tok("-", 1);
    if (ph_at("*=", 2))  op = ph_tok("*", 1);
    if (ph_at("/=", 2))  op = ph_tok("/", 1);
    if (ph_at("%=", 2))  op = ph_tok("%", 1);
    if (ph_at("**=", 3)) op = ph_tok("**", 2);
    i64 incdec = 0;
    if (ph_at("++", 2)) incdec = 1;
    if (ph_at("--", 2)) incdec = -1;

    if (incdec) {
        ph_next();
        if (semi) ph_want(";", 1, "expected ; after ++/--");
        if (ph_var_find(d) < 0) ph_refuse2(fl, line, "an undefined php variable", d, "D4");
        i64 t = ph_var_type(d);
        i64 lv = node_new(N_IDENT, line, fl);
        set_nd_name(lv, ph_mangle(d, "v_"));
        set_nd_type(lv, ph_mcty(t));
        i64 one = ph_int(1);
        if (t == PT_FLOAT) one = ph_cast(ty_f64, ph_int(1));
        i64 b = ph_bin(ph_tok("+", 1), lv, one, ph_mcty(t));
        if (incdec < 0) set_nd_op(b, ph_tok("-", 1));
        i64 a = node_new(N_ASSIGN, line, fl);
        set_nd_name(a, ph_mangle(d, "v_"));
        set_nd_a(a, b);
        return ph_wrap(a);
    }

    if (op) {
        ph_next();
        if (ph_var_find(d) < 0) ph_refuse2(fl, line, "an undefined php variable", d, "D4");
        i64 lt = ph_var_type(d);
        i64 lv = node_new(N_IDENT, line, fl);
        set_nd_name(lv, ph_mangle(d, "v_"));
        set_nd_type(lv, ph_mcty(lt));
        i64 r = ph_expr(0);
        i64 rt = ph_ety;
        if (semi) ph_want(";", 1, "expected ; after a php assignment");
        i64 v = 0;
        if (op == ph_tok(".", 1)) { v = ph_c2("php_str_concat", ph_to_str(lv, lt), ph_to_str(r, rt), ty_pstr); ph_ety = PT_STRING; }
        if (op != ph_tok(".", 1)) v = ph_arith(op, lv, lt, r, rt, fl, line);
        if (ph_ety != lt) {
            uptr m = p_cat(d, " was ", 0, 5);
            m = p_cat(m, ph_tyname(lt), 0, cstrlen(ph_tyname(lt)));
            m = p_cat(m, ", assigned ", 0, 11);
            m = p_cat(m, ph_tyname(ph_ety), 0, cstrlen(ph_tyname(ph_ety)));
            ph_refuse2(fl, line, "a php variable has one type", m, "D4");
        }
        i64 a = node_new(N_ASSIGN, line, fl);
        set_nd_name(a, ph_mangle(d, "v_"));
        set_nd_a(a, v);
        return ph_wrap(a);
    }

    if (!ph_at("=", 1)) {
        if (ph_at("=>", 2)) err_at(fl, line, "mc-php: unexpected => outside foreach");
        ph_todo2(fl, line, "a php variable used as a statement", d);
    }
    ph_next();
    if (ph_at("&", 1)) ph_todo(fl, line, "an assignment by reference");
    i64 v = ph_expr(0);
    i64 vt = ph_ety;
    if (semi) ph_want(";", 1, "expected ; after a php assignment");
    if (vt == PT_NULL) ph_refuse(fl, line, "assigning null to a variable (its type would be ?T)", "D9 (e)");
    if (vt == PT_VOID) ph_refuse(fl, line, "assigning the result of a void function", "D4");
    ph_var_bind(d, vt);
    return ph_wrap(ph_set(ph_mangle(d, "v_"), v));
}

// D5: require / require_once / include / include_once of a LITERAL path
#define PH_MAXINC 128
uptr ph_seen[PH_MAXINC];
i64  ph_nseen;

void ph_require(i64 once, uptr fl, i64 line) {
    ph_next();
    if (ph_at("(", 1)) ph_next();
    if (ph_tid != T_STR && ph_tid != PHT_PSTR)
        ph_refuse(fl, line, "an include of a computed path", "D1");
    uptr rel = ph_tname;
    ph_next();
    if (ph_at(")", 1)) ph_next();
    if (!ph_at(";", 1)) err_at(fl, line, "mc-php: expected ; after require");
    uptr full = path_norm(path_join(fl, rel));
    i64 i = 0;
    i64 seen = 0;
    loop {
        if (i >= ph_nseen) break;
        if (str_eq(ld64(ph_seen + i * 8), full)) seen = 1;
        i = i + 1;
    }
    if (once && seen) { ph_next(); return; }
    if (!seen) {
        if (ph_nseen >= PH_MAXINC) err_at(fl, line, "mc-php: too many php requires");
        st64(ph_seen + ph_nseen * 8, full);
        ph_nseen = ph_nseen + 1;
    }
    i64 len = 0;
    uptr txt = read_file(full, &len);
    if (!txt) err_at2(fl, line, "mc-php: cannot open the required file", full);
    if (len < 5 || !str_eq(xstrdup(txt, 5), "<?php"))
        ph_todo2(fl, line, "an included file that does not open with <?php", full);
    ph_pushing = 1;
    p_push_source(full, txt + 5, len - 5);
    ph_pushing = 0;
    ph_nopeek = 1;
    ph_next();
}

i64 ph_stmt() {
    i64 line = ph_tline;
    uptr fl = ph_tfile;

    if (ph_at(";", 1)) { ph_next(); return ph_empty(); }
    if (ph_at("{", 1)) return ph_block();
    if (ph_at("<?php", 5) || ph_at("<?=", 3)) { ph_next(); return ph_empty(); }
    if (ph_at("?>", 2)) return ph_inline_html(fl, line);   // the cursor is just after ?>
    if (ph_tid == PHT_HTML) { ph_next(); return ph_empty(); }

    if (ph_is("echo") || ph_is("print")) {
        i64 isprint = ph_is("print");
        ph_next();
        i64 head = 0;
        i64 tail = 0;
        loop {
            i64 e = ph_expr(0);
            i64 t = ph_ety;
            i64 c = ph_echo_of(e, t, fl, line);
            i64 s = node_new(N_EXPRSTMT, line, fl);
            set_nd_a(s, c);
            if (tail) set_nd_next(tail, s);
            if (!tail) head = s;
            tail = s;
            if (isprint) break;
            if (!ph_accept(",", 1)) break;
        }
        ph_want(";", 1, "expected ; after echo");
        i64 b = node_new(N_BLOCK, line, fl);
        set_nd_a(b, head);
        return ph_wrap(b);
    }
    if (ph_is("return")) {
        ph_next();
        i64 e = 0;
        if (!ph_at(";", 1)) { e = ph_expr(0); }
        ph_want(";", 1, "expected ; after return");
        i64 r = node_new(N_RETURN, line, fl);
        set_nd_a(r, e);
        return ph_wrap(r);
    }
    if (ph_is("if")) return ph_if(fl, line);
    if (ph_is("while")) {
        ph_next();
        ph_want("(", 1, "expected ( after while");
        i64 c = ph_to_bool(ph_expr(0), ph_ety);
        if (ph_pend_head) ph_todo(fl, line, "a while condition that needs a temporary");
        ph_want(")", 1, "expected ) after while");
        if (ph_at(":", 1)) ph_todo(fl, line, "the alternative while: endwhile; syntax");
        i64 body = ph_block_or_stmt();
        return ph_loop_of(c, body, 0, line, fl);
    }
    if (ph_is("do")) {
        ph_next();
        i64 body = ph_block_or_stmt();
        if (!ph_is("while")) err_at(fl, line, "mc-php: expected while after do");
        ph_next();
        ph_want("(", 1, "expected ( after do-while");
        i64 c = ph_to_bool(ph_expr(0), ph_ety);
        ph_want(")", 1, "expected ) after do-while");
        ph_want(";", 1, "expected ; after do-while");
        i64 neg = node_new(N_UNARY, line, fl);
        set_nd_op(neg, ph_tok("!", 1));
        set_nd_a(neg, c);
        set_nd_type(neg, TY_U8);
        i64 brk = node_new(N_BREAK, line, fl);
        set_nd_val(brk, 1);
        i64 iff = node_new(N_IF, line, fl);
        set_nd_a(iff, neg);
        set_nd_b(iff, brk);
        i64 t = body;
        loop { if (!nd_next(t)) break; t = nd_next(t); }
        set_nd_next(t, iff);
        i64 b = node_new(N_BLOCK, line, fl);
        set_nd_a(b, body);
        i64 lp = node_new(N_LOOP, line, fl);
        set_nd_a(lp, b);
        return lp;
    }
    if (ph_is("for")) {
        ph_next();
        ph_want("(", 1, "expected ( after for");
        i64 init = ph_empty();
        if (!ph_at(";", 1)) init = ph_stmt();
        if (ph_at(";", 1)) ph_next();
        i64 c = ph_bool(1);
        if (!ph_at(";", 1)) c = ph_to_bool(ph_expr(0), ph_ety);
        ph_want(";", 1, "expected ; in for");
        i64 step = 0;
        if (!ph_at(")", 1)) {
            step = ph_assign_stmt(fl, line, 0);         // $i++ / $i += e, no ;
        }
        ph_want(")", 1, "expected ) after for");
        if (ph_at(":", 1)) ph_todo(fl, line, "the alternative for: endfor; syntax");
        i64 body = ph_block_or_stmt();
        i64 lp = ph_loop_of(c, body, step, line, fl);
        i64 t2 = init;
        loop { if (!nd_next(t2)) break; t2 = nd_next(t2); }
        set_nd_next(t2, lp);
        i64 outer = node_new(N_BLOCK, line, fl);
        set_nd_a(outer, init);
        return outer;
    }
    if (ph_is("foreach")) return ph_foreach(fl, line);
    if (ph_is("break") || ph_is("continue")) {
        i64 isbrk = ph_is("break");
        ph_next();
        i64 lv = 1;
        if (ph_tid == T_INT) { lv = ph_tval; ph_next(); }
        ph_want(";", 1, "expected ; after break/continue");
        i64 n = node_new(N_BREAK, line, fl);
        if (!isbrk) n = node_new(N_CONTINUE, line, fl);
        set_nd_val(n, lv);
        return n;
    }
    if (ph_is("require_once")) { ph_require(1, fl, line); return ph_empty(); }
    if (ph_is("include_once")) { ph_require(1, fl, line); return ph_empty(); }
    if (ph_is("require"))      { ph_require(0, fl, line); return ph_empty(); }
    if (ph_is("include"))      { ph_require(0, fl, line); return ph_empty(); }
    if (ph_is("declare")) {
        ph_next();
        ph_want("(", 1, "expected ( after declare");
        loop { if (ph_at(")", 1)) break; if (ph_tid == T_EOF) break; ph_next(); }
        ph_want(")", 1, "expected ) after declare");
        ph_accept(";", 1);
        return ph_empty();
    }
    if (ph_is("namespace") || ph_is("use")) {
        ph_next();
        loop { if (ph_at(";", 1)) break; if (ph_at("{", 1)) break; if (ph_tid == T_EOF) break; ph_next(); }
        ph_accept(";", 1);
        return ph_empty();
    }
    if (ph_is("const")) {
        ph_next();
        loop {
            if (ph_tid != T_IDENT) err_at2(fl, line, "mc-php: a php constant needs a name", ph_tname);
            uptr cn = ph_tname;
            ph_next();
            ph_want("=", 1, "expected = in a php const");
            i64 v = ph_expr(0);
            ph_const_add(cn, v, ph_ety, fl, line);
            if (!ph_accept(",", 1)) break;
        }
        ph_want(";", 1, "expected ; after a php const");
        return ph_empty();
    }
    if (ph_is("unset")) ph_refuse(fl, line, "unset()", "D4 (a variable's type is its declaration)");
    if (ph_is("global") || ph_is("static")) ph_todo2(fl, line, "the storage keyword", ph_tname);
    if (ph_is("switch")) ph_todo(fl, line, "switch");
    if (ph_is("match"))  ph_todo(fl, line, "match");
    if (ph_is("try") || ph_is("throw") || ph_is("catch")) ph_todo(fl, line, "exceptions");
    if (ph_is("class") || ph_is("interface") || ph_is("trait") || ph_is("enum"))
        ph_todo2(fl, line, "the declaration", ph_tname);
    if (ph_is("goto")) ph_todo(fl, line, "goto");
    if (ph_is("exit") || ph_is("die")) {
        ph_next();
        i64 code = ph_int(0);
        if (ph_at("(", 1)) {
            ph_next();
            if (!ph_at(")", 1)) {
                i64 v = ph_expr(0);
                if (ph_ety == PT_STRING) {
                    i64 e = ph_c1("php_echo_str", v, TY_I64);
                    i64 s0 = node_new(N_EXPRSTMT, line, fl);
                    set_nd_a(s0, e);
                    ph_pending_stmt(s0);
                }
                if (ph_ety != PT_STRING) code = ph_to_int(v, ph_ety);
            }
            ph_want(")", 1, "expected ) after exit");
        }
        ph_accept(";", 1);
        return ph_wrap(ph_expr_stmt_of(ph_c1("php_exit", code, TY_VOID)));
    }
    if (ph_at("$", 1)) return ph_assign_stmt(fl, line, 1);

    i64 e = ph_expr(0);
    if (!ph_at(")", 1)) ph_want(";", 1, "expected ; after a php expression");
    // var_dump() and the null literal have already emitted everything they do
    // (ph_pending_stmt) and their value is a constant: dropping it keeps the
    // statement list free of dead expressions. A VOID CALL is not that.
    if (nd_kind(e) == N_INT) return ph_wrap(ph_empty());
    return ph_expr_stmt_of(e);
}

// if / elseif / else, as one chain
i64 ph_if(uptr fl, i64 line) {
    ph_next();                                    // if / elseif
    ph_want("(", 1, "expected ( after if");
    i64 c = ph_to_bool(ph_expr(0), ph_ety);
    ph_want(")", 1, "expected ) after if");
    if (ph_at(":", 1)) ph_todo(fl, line, "the alternative if: endif; syntax");
    i64 pre = ph_pend_head;
    i64 pret = ph_pend_tail;
    ph_pend_head = 0;
    ph_pend_tail = 0;
    i64 t = ph_block_or_stmt();
    i64 e = 0;
    if (ph_is("elseif")) e = ph_if(ph_tfile, ph_tline);
    if (!e) {
        if (ph_is("else")) {
            ph_next();
            if (ph_is("if")) e = ph_if(ph_tfile, ph_tline);
            if (!e) e = ph_block_or_stmt();
        }
    }
    i64 n = node_new(N_IF, line, fl);
    set_nd_a(n, c);
    set_nd_b(n, t);
    set_nd_c(n, e);
    ph_pend_head = pre;
    ph_pend_tail = pret;
    return ph_wrap(n);
}

// foreach ($a as $v) / foreach ($a as $k => $v), over a T5 array (a packed
// homogeneous vector with the keys 0..n-1)
i64 ph_foreach(uptr fl, i64 line) {
    ph_next();
    ph_want("(", 1, "expected ( after foreach");
    i64 src = ph_expr(0);
    i64 st = ph_ety;
    if (!ph_is_arr(st)) ph_todo2(fl, line, "foreach over", ph_tyname(st));
    i64 et = ph_elem(st);
    if (!ph_is("as")) err_at(fl, line, "mc-php: expected as in foreach");
    ph_next();
    if (!ph_at("$", 1)) ph_todo(fl, line, "foreach without a $variable");
    ph_next();
    uptr k1 = p_cat("$", ph_tname, 0, cstrlen(ph_tname));
    ph_next();
    uptr kv = 0;
    if (ph_at("=>", 2)) {
        ph_next();
        if (ph_at("&", 1)) ph_todo(fl, line, "foreach by reference");
        if (!ph_at("$", 1)) ph_todo(fl, line, "foreach without a $variable");
        ph_next();
        kv = p_cat("$", ph_tname, 0, cstrlen(ph_tname));
        ph_next();
    }
    ph_want(")", 1, "expected ) after foreach");
    if (ph_at(":", 1)) ph_todo(fl, line, "the alternative foreach: endforeach; syntax");

    uptr key = 0;
    uptr val = k1;
    if (kv) { key = k1; val = kv; }

    ph_nonce = ph_nonce + 1;
    uptr an = p_cat("phf_a", php_dec(ph_nonce), 0, cstrlen(php_dec(ph_nonce)));
    uptr iname = p_cat("phf_i", php_dec(ph_nonce), 0, cstrlen(php_dec(ph_nonce)));

    ph_local(an, ty_parr);
    ph_local(iname, TY_I64);
    i64 av = ph_set(an, src);
    i64 iv = ph_set(iname, ph_int(0));
    set_nd_next(av, iv);

    i64 aref = node_new(N_IDENT, line, fl);
    set_nd_name(aref, an);
    set_nd_type(aref, ty_parr);
    i64 iref = node_new(N_IDENT, line, fl);
    set_nd_name(iref, iname);
    set_nd_type(iref, TY_I64);
    i64 cond = ph_bin(ph_tok("<", 1), iref, ph_c1("php_count", aref, TY_I64), TY_U8);

    if (key) ph_var_bind(key, PT_INT);
    ph_var_bind(val, et);

    i64 aref2 = node_new(N_IDENT, line, fl);
    set_nd_name(aref2, an);
    set_nd_type(aref2, ty_parr);
    i64 iref2 = node_new(N_IDENT, line, fl);
    set_nd_name(iref2, iname);
    set_nd_type(iref2, TY_I64);
    i64 get = 0;
    if (et == PT_FLOAT) get = ph_c2("php_arr_getf", aref2, iref2, ty_f64);
    if (et != PT_FLOAT) {
        get = ph_c2("php_arr_get", aref2, iref2, TY_I64);
        if (et == PT_STRING) get = ph_cast(ty_pstr, get);
        if (et == PT_BOOL)   get = ph_cast(TY_U8, get);
    }
    i64 setv = ph_set(ph_mangle(val, "v_"), get);
    i64 head = setv;
    if (key) {
        i64 iref3 = node_new(N_IDENT, line, fl);
        set_nd_name(iref3, iname);
        set_nd_type(iref3, TY_I64);
        i64 setk = ph_set(ph_mangle(key, "v_"), iref3);
        set_nd_next(setk, setv);
        head = setk;
    }
    i64 body = ph_block_or_stmt();
    i64 t = head;
    loop { if (!nd_next(t)) break; t = nd_next(t); }
    set_nd_next(t, body);

    i64 iref4 = node_new(N_IDENT, line, fl);
    set_nd_name(iref4, iname);
    set_nd_type(iref4, TY_I64);
    i64 bump = ph_set(iname, ph_bin(ph_tok("+", 1), iref4, ph_int(1), TY_I64));

    i64 lp = ph_loop_of(cond, head, bump, line, fl);
    set_nd_next(iv, lp);
    i64 outer = node_new(N_BLOCK, line, fl);
    set_nd_a(outer, av);
    return outer;
}

// ---- declarations ----------------------------------------------------------
// A function is registered BEFORE its body is parsed, so it may call itself.
i64 ph_main_head;
i64 ph_main_tail;

i64 ph_function() {
    i64 line = ph_tline;
    uptr fl = ph_tfile;
    ph_next();                                    // function
    if (ph_at("&", 1)) ph_todo(fl, line, "a function returning by reference");
    if (ph_tid != T_IDENT) ph_todo(fl, line, "an anonymous function or closure");
    uptr name = ph_tname;
    ph_next();
    if (ph_fn_find(name) >= 0) err_at2(fl, line, "mc-php: this php function is declared twice", name);
    if (ph_nfn >= PH_MAXFN) err_at(fl, line, "mc-php: too many php functions");
    i64 fi = ph_nfn;
    ph_nfn = ph_nfn + 1;
    st64(ph_fname + fi * 8, name);
    st64(ph_fret + fi * 8, PT_INT);
    st64(ph_fnp + fi * 8, 0);

    ph_want("(", 1, "expected ( in a php function");
    i64 save = ph_nvar;
    i64 head = 0;
    i64 tail = 0;
    i64 np = 0;
    loop {
        if (ph_at(")", 1)) break;
        if (ph_at("...", 3)) ph_todo(fl, line, "a variadic parameter ...$args");
        if (ph_at("&", 1)) ph_todo(fl, line, "a by-reference parameter");
        i64 pt = -1;
        if (!ph_at("$", 1)) pt = ph_type_word(1);
        if (pt < 0) ph_refuse(fl, line, "an untyped php parameter (D4 needs the type)", "D4");
        if (!ph_at("$", 1)) ph_todo(fl, line, "a php parameter without $name");
        ph_next();
        uptr d = p_cat("$", ph_tname, 0, cstrlen(ph_tname));
        ph_next();
        if (ph_at("=", 1)) ph_todo(fl, line, "a default parameter value");
        if (np >= PH_MAXP) ph_todo(fl, line, "more than 12 parameters");
        ph_var_bind(d, pt);
        st64(ph_fpt + (fi * PH_MAXP + np) * 8, pt);
        np = np + 1;
        i64 pn = param_new(ph_mcty(pt), ph_mangle(d, "v_"));
        if (tail) set_nd_next(tail, pn);
        if (!tail) head = pn;
        tail = pn;
        if (!ph_accept(",", 1)) break;
    }
    ph_want(")", 1, "expected ) in a php function");
    st64(ph_fnp + fi * 8, np);
    i64 rt = PT_INT;
    if (ph_at(":", 1)) { ph_next(); rt = ph_type_word(1); }
    if (!ph_at(":", 1)) { if (rt == PT_INT) rt = PT_INT; }
    st64(ph_fret + fi * 8, rt);
    uptr mn = ph_mangle(name, "f_");
    p_set_decl_name(mn);
    i64 hh = ph_hoist_head;
    i64 ht = ph_hoist_tail;
    ph_hoist_head = 0;
    ph_hoist_tail = 0;
    i64 body = ph_block();
    if (ph_hoist_head) {
        set_nd_next(ph_hoist_tail, nd_a(body));
        set_nd_a(body, ph_hoist_head);
    }
    ph_hoist_head = hh;
    ph_hoist_tail = ht;
    ph_nvar = save;
    i64 f = node_new(N_FUNC, line, fl);
    set_nd_name(f, mn);
    set_nd_type(f, ph_mcty(rt));
    set_nd_a(f, head);
    set_nd_b(f, body);
    return f;
}

// ---- the one registration --------------------------------------------------
void ph_program() {
    i64 line = ph_tline;
    uptr fl = p_file();
    ph_sync();
    ph_next();                                    // <?php
    loop {
        if (ph_tid == T_EOF) break;
        if (ph_is("function")) {
            // `function` as an EXPRESSION (a closure) is refused inside ph_function
            top_add(ph_function());
            continue;
        }
        i64 s = ph_stmt();
        if (ph_main_tail) set_nd_next(ph_main_tail, s);
        if (!ph_main_tail) ph_main_head = s;
        ph_main_tail = s;
        loop { if (!nd_next(ph_main_tail)) break; ph_main_tail = nd_next(ph_main_tail); }
    }
    i64 fin = node_new(N_EXPRSTMT, line, fl);
    set_nd_a(fin, ph_call("php_flush", 0, 0, 0, 0, 0, TY_VOID));
    if (ph_main_tail) set_nd_next(ph_main_tail, fin);
    if (!ph_main_tail) ph_main_head = fin;
    i64 r = node_new(N_RETURN, line, fl);
    set_nd_a(r, ph_int(0));
    set_nd_next(fin, r);
    if (ph_hoist_head) {
        set_nd_next(ph_hoist_tail, ph_main_head);
        ph_main_head = ph_hoist_head;
    }
    i64 b = node_new(N_BLOCK, line, fl);
    set_nd_a(b, ph_main_head);
    i64 f = node_new(N_FUNC, line, fl);
    set_nd_name(f, "main");
    set_nd_type(f, TY_I64);
    set_nd_b(f, b);
    top_add(f);
}

// A .php the core lexer would meet before `<?php` is a named refusal, not a
// pile of stray identifiers: leading inline html has nowhere to go, because
// the module only gets control once a token has already been lexed.
i64 ph_ends(uptr s, uptr sfx) {
    i64 n = cstrlen(s);
    i64 m = cstrlen(sfx);
    if (m > n) return 0;
    return str_eq(s + n - m, sfx);
}

void ph_on_source(uptr name, uptr src, i64 len) {
    if (ph_pushing) return;                  // the body of a require: <?php already eaten
    if (!ph_ends(name, ".php")) return;
    if (len >= 5 && str_eq(xstrdup(src, 5), "<?php")) return;
    if (len >= 3 && str_eq(xstrdup(src, 3), "<?=")) return;
    ph_todo(name, 1, "a php file that does not open with <?php (leading inline html)");
}

i64 ph_dollar_expr() {
    err_at(p_file(), p_line(), "mc-php: a $variable outside a php expression");
    return 0;
}

#embed ph_rt "php_rt.txt"

void user_init() {
    float_init();
    machine_arm64_float_init();
    machine_x86_64_float_init();
    ty_pstr = type_new("php_str", 8, 8, TK_INT);
    ty_parr = type_new("php_arr", 8, 8, TK_INT);
    ph_tokens();
    syntax_expr("$", &ph_dollar_expr);            // makes `$name` lex as `$` + name
    on_source(&ph_on_source);
    syntax("<?php", &ph_program);
    p_push_source("php runtime", ph_rt, ph_rt_size);
}

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
#define PT_IFALSE  5      // int|false -- strpos's return, the one union kept typed
#define PT_NULL    6      // the `null` literal; a variable assigned one is mixed
#define PT_MIXED   7      // a zval: php's own 16-byte value (T6)
#define PT_ARR     8      // php's ordered hash; every element is a zval
#define PT_OBJ     9      // a raw object handle: $this, and nothing else

// the visibility codes, shared with php_rt.txt
#define V_PUBLIC    0
#define V_PROTECTED 1
#define V_PRIVATE   2

i64 ty_pstr;              // the mc type `string` lowers to (D10)
i64 ty_parr;
i64 ty_pzv;               // `mixed`: a pointer to a 16-byte zval

// forward declarations: mc is single pass
extern void exit(i64 code);          // the compiler's own exit, for a php compile-time fatal
uptr php_dec(i64 v);
i64  ph_const_find(uptr n);
void ph_const_add(uptr cn, i64 v, i64 t, uptr fl, i64 line);
i64  ph_array_lit(uptr close);
void ph_local(uptr name, i64 mcty);
i64  ph_set(uptr name, i64 val);
void ph_pending_stmt(i64 s);
i64  ph_expr(i64 minp);
i64  ph_stmt();
i64  ph_stmt_1();
i64  ph_block();
i64  ph_block_or_stmt();
i64  ph_if(uptr fl, i64 line);
i64  ph_foreach(uptr fl, i64 line);
i64  ph_builtin(uptr name, i64 line, uptr fl);
uptr ph_read_args(i64 maxn, uptr fl, i64 line, uptr pn);
i64  ph_isof(i64 na, i64 t0, i64 a0, i64 want, i64 ztype, uptr fl, i64 line, uptr name);
i64  ph_a(uptr av, i64 i);
i64  ph_aty(uptr av, i64 i);
i64  ph_arith(i64 op, i64 lhs, i64 lt, i64 rhs, i64 rt, uptr fl, i64 line);
i64  ph_assign_stmt(uptr fl, i64 line, i64 semi);
i64  ph_strlit(uptr bytes, i64 len);
i64  ph_digit(i64 c, i64 base);
i64  ph_dq_read(uptr q, uptr e, uptr pend);
i64  ph_dq_read2(uptr q, uptr e, uptr pend, i64 term, i64 raw);
i64  ph_heredoc(uptr q, uptr e, uptr pend);
i64  ph_to_str(i64 n, i64 t);
i64  ph_to_int(i64 n, i64 t);
i64  ph_to_float(i64 n, i64 t);
i64  ph_to_bool(i64 n, i64 t);
i64  ph_space(i64 c);
i64  ph_is_arr(i64 t);
i64  ph_to_mixed(i64 n, i64 t);
i64  ph_postfix(i64 v, i64 vt);
i64  ph_temp(i64 v, i64 mcty, uptr pfx);
i64  ph_tref(i64 n);
i64  ph_ret_null(i64 line, uptr fl);
void ph_var_bind_raw(uptr d, i64 ty);
void ph_class(uptr fl, i64 line, i64 flags);
i64  ph_scope();
uptr ph_cur_cls;               // the class being parsed, 0 outside one
uptr ph_cur_fn;                // the php function or method being parsed, 0 outside one
i64  ph_pre_find(uptr n);
i64  ph_stmt_of(i64 c);
i64  ph_mcall_node(i64 recv, uptr name, uptr fl, i64 line);
i64  ph_scall_node(i64 ce, uptr name, uptr fl, i64 line);
i64  ph_ce_of(uptr name, uptr fl, i64 line);
i64  ph_this(uptr fl, i64 line);
i64  ph_recv(i64 v, i64 t);
void ph_skip_type();
i64  ph_obj_stmt(uptr d, uptr fl, i64 line, i64 semi);
i64  ph_calln(uptr fn, uptr args, i64 n, i64 ty);
i64  ph_take_pend();
i64  ph_is_ref(uptr d);
i64  ph_refset_has(uptr n);
i64  ph_gset_has(uptr n);
void ph_gset_add(uptr n);
void ph_refset_add(uptr n);
void ph_incset_add(uptr n);
i64  ph_incset_has(uptr n);
void ph_set_ref(uptr d);
uptr ph_scope_save();
void ph_scope_restore(uptr b);
i64  ph_closure(uptr fl, i64 line, i64 arrow);
i64  ph_prefix_stmts(i64 pre, i64 s);
void ph_ls_push(i64 kind);
void ph_ls_pop();
i64  ph_ls_level(i64 n, uptr fl, i64 line);
i64  ph_check(i64 line, uptr fl);
i64  ph_lv_walk(uptr d, uptr fl, i64 line, uptr pkey, i64 hoist);
i64  ph_index(i64 base, i64 bt);
i64  ph_zkey(i64 n, i64 t);
i64  ph_mcty(i64 t);
uptr ph_tyname(i64 t);
i64  ph_tok(uptr s, i64 n);
i64  ph_var_find(uptr d);
i64  ph_var_type(uptr d);
i64  ph_var_bind(uptr d, i64 ty);
void ph_refuse(uptr fl, i64 line, uptr what, uptr dref);
void ph_phpfatal(uptr fl, i64 line, uptr msg);
uptr ph_absfile(uptr fl);
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
i64  ph_wordish();
i64  ph_name_byte(i64 c, i64 first);
void ph_next();
i64  ph_accept(uptr s, i64 n);
void ph_want(uptr s, i64 n, uptr msg);
void ph_semi(uptr msg);
uptr ph_mangle(uptr d, uptr pfx);
i64  ph_raw(uptr bytes, i64 len);
i64  ph_wrap(i64 s);
i64  ph_empty();
i64  ph_expr_stmt_of(i64 e);
i64  ph_loop_of(i64 cond, i64 body, i64 step, i64 line, uptr fl);
i64  ph_loop_pre;

// `break N` counts php LOOPS; a try block is lowered as a one-iteration mc
// loop so a throw can break out of it, so the mc level is the php level plus
// the try wrappers in between.
#define PH_MAXLS 64
i64 ph_lstack[PH_MAXLS];
i64 ph_nls;
i64 ph_can_throw;              // this statement contains a call
i64 ph_in_try;
i64 ph_toplevel;               // parsing main: an uncaught throwable is fatal
i64  ph_pushing;
i64  ph_type_word(i64 must);
i64  ph_vd(i64 v, i64 t, uptr fl, i64 line);
i64  ph_echo_of(i64 v, i64 t, uptr fl, i64 line);
i64  ph_inline_html(uptr fl, i64 line);

i64 ph_is_arr(i64 t) { if (t == PT_ARR) return 1; return 0; }

i64 ph_mcty(i64 t) {
    if (t == PT_INT)    return TY_I64;
    if (t == PT_IFALSE) return TY_I64;
    if (t == PT_FLOAT)  return ty_f64;
    if (t == PT_STRING) return ty_pstr;
    if (t == PT_BOOL)   return TY_U8;
    if (t == PT_VOID)   return TY_VOID;
    if (t == PT_NULL)   return ty_pzv;
    if (t == PT_MIXED)  return ty_pzv;
    if (t == PT_ARR)    return ty_parr;
    if (t == PT_OBJ)    return TY_UPTR;
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
    if (t == PT_MIXED)  return "mixed";
    if (t == PT_ARR)    return "array";
    if (t == PT_OBJ)    return "object";
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

// A php COMPILE-TIME fatal: php reports these while parsing, prints the text
// on stdout and exits 255, and that text IS the program's whole output. So
// mc-php does the same from the compiler -- stdout, exit 255 -- and
// probes/t7/mcphp.sh passes 255 through instead of calling it a compile
// error. It is neither a refusal (the grid's third column) nor an mc
// diagnostic: it is php's answer, produced where php produces it.
void ph_phpfatal(uptr fl, i64 line, uptr msg) {
    uptr a = ph_absfile(fl);
    uptr d0 = php_dec(line);
    // a plain `php file.php` has log_errors=On and writes the stderr form
    // first; the phpt runner sets log_errors=0 and grades stdout alone.
    write(2, "PHP Fatal error:  ", 18);
    write(2, msg, cstrlen(msg));
    write(2, " in ", 4);
    write(2, a, cstrlen(a));
    write(2, " on line ", 9);
    write(2, d0, cstrlen(d0));
    write(2, "\n", 1);
    write(1, "\nFatal error: ", 14);
    write(1, msg, cstrlen(msg));
    write(1, " in ", 4);
    write(1, a, cstrlen(a));
    write(1, " on line ", 9);
    uptr d = php_dec(line);
    write(1, d, cstrlen(d));
    write(1, "\n", 1);
    exit(255);
}

// NOT a refusal: something T5 has not built yet. It is an ordinary compile
// error (the grid counts it `wrong`), because inflating the refused column
// with "not implemented" would make that column a lie.
void ph_todo(uptr fl, i64 line, uptr what) {
    uptr m = p_cat("mc-php: ", what, 0, cstrlen(what));
    m = p_cat(m, " is not implemented yet (probes/t6/RESULTS.md)", 0, 46);
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
    ph_can_throw = 1;
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
// 1 when the variable holds a zval POINTER that must be written through:
// a by-reference parameter, `global $x`, a function `static`, and the value
// of `foreach as &$v`. Reading one is reading the zval; writing one is a
// store into it, which is what makes the alias visible to the other name.
i64  ph_vref[PH_MAXVAR];
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

i64 ph_is_ref(uptr d) {
    i64 i = ph_var_find(d);
    if (i < 0) return 0;
    return ld64(ph_vref + i * 8);
}

// A variable that is ever aliased (`&$x`, a `global`, a by-reference use or
// parameter) has to be a zval from its FIRST assignment: the typed local it
// would otherwise be has no address a second name can share. The names come
// from a byte scan of every source, in ph_on_source, before anything is
// parsed -- a false positive costs a zval and nothing else.
#define PH_MAXREF 256
uptr ph_refn[PH_MAXREF];
i64  ph_nref;
uptr ph_gsetn[PH_MAXREF];
i64  ph_ngset;

void ph_gset_add(uptr n) {
    i64 i = 0;
    loop {
        if (i >= ph_ngset) break;
        if (str_eq(ld64(ph_gsetn + i * 8), n)) return;
        i = i + 1;
    }
    if (ph_ngset >= PH_MAXREF) return;
    st64(ph_gsetn + ph_ngset * 8, n);
    ph_ngset = ph_ngset + 1;
}

i64 ph_gset_has(uptr n) {
    i64 i = 0;
    loop {
        if (i >= ph_ngset) break;
        if (str_eq(ld64(ph_gsetn + i * 8), n)) return 1;
        i = i + 1;
    }
    return 0;
}

void ph_refset_add(uptr n) {
    i64 i = 0;
    loop {
        if (i >= ph_nref) break;
        if (str_eq(ld64(ph_refn + i * 8), n)) return;
        i = i + 1;
    }
    if (ph_nref >= PH_MAXREF) return;
    st64(ph_refn + ph_nref * 8, n);
    ph_nref = ph_nref + 1;
}

i64 ph_refset_has(uptr n) {
    i64 i = 0;
    loop {
        if (i >= ph_nref) break;
        if (str_eq(ld64(ph_refn + i * 8), n)) return 1;
        i = i + 1;
    }
    return 0;
}

// A php `$s++` on a STRING changes the variable's type -- "5"++ is int(6) --
// which D4 forbids of a typed local. The same byte scan that finds `&$x`
// finds `$x++`, and a variable whose first assignment is a string and which
// is incremented somewhere is bound `mixed` instead: a zval can hold both
// answers and php_zv_inc already has php's rules. An int or float counter is
// untouched, which is what keeps every `for ($i = 0; ...; $i++)` a native i64.
uptr ph_incn[PH_MAXREF];
i64  ph_ninc;

void ph_incset_add(uptr n) {
    i64 i = 0;
    loop {
        if (i >= ph_ninc) break;
        if (str_eq(ld64(ph_incn + i * 8), n)) return;
        i = i + 1;
    }
    if (ph_ninc >= PH_MAXREF) return;
    st64(ph_incn + ph_ninc * 8, n);
    ph_ninc = ph_ninc + 1;
}

i64 ph_incset_has(uptr n) {
    i64 i = 0;
    loop {
        if (i >= ph_ninc) break;
        if (str_eq(ld64(ph_incn + i * 8), n)) return 1;
        i = i + 1;
    }
    return 0;
}

void ph_set_ref(uptr d) {
    i64 i = ph_var_find(d);
    if (i >= 0) st64(ph_vref + i * 8, 1);
}

// a php function body has its OWN scope: it sees no enclosing variable (a
// closure's captures are copied in explicitly). The table is flat, so the
// outer entries are saved and put back rather than just counted.
uptr ph_scope_save() {
    uptr b = xalloc(ph_nvar * 24 + 24);
    st64(b, ph_nvar);
    i64 i = 0;
    loop {
        if (i >= ph_nvar) break;
        st64(b + 8 + i * 24, ld64(ph_vname + i * 8));
        st64(b + 16 + i * 24, ld64(ph_vtype + i * 8));
        st64(b + 24 + i * 24, ld64(ph_vref + i * 8));
        i = i + 1;
    }
    ph_nvar = 0;
    return b;
}

void ph_scope_restore(uptr b) {
    i64 n = ld64(b);
    i64 i = 0;
    loop {
        if (i >= n) break;
        st64(ph_vname + i * 8, ld64(b + 8 + i * 24));
        st64(ph_vtype + i * 8, ld64(b + 16 + i * 24));
        st64(ph_vref + i * 8, ld64(b + 24 + i * 24));
        i = i + 1;
    }
    ph_nvar = n;
}

// 1 when this is the variable's FIRST assignment (the caller emits N_VAR, not
// N_ASSIGN). A second assignment of another type is D4's named compile error.
void ph_var_bind_raw(uptr d, i64 ty) {
    i64 i = ph_var_find(d);
    if (i >= 0) { st64(ph_vtype + i * 8, ty); return; }
    if (ph_nvar >= PH_MAXVAR) err_at(ph_tfile, ph_tline, "mc-php: too many php variables");
    st64(ph_vname + ph_nvar * 8, d);
    st64(ph_vtype + ph_nvar * 8, ty);
    st64(ph_vref + ph_nvar * 8, 0);
    ph_nvar = ph_nvar + 1;
}

i64 ph_var_bind(uptr d, i64 ty) {
    if (ty == PT_STRING && ph_incset_has(d)) ty = PT_MIXED;
    i64 i = ph_var_find(d);
    if (i < 0) {
        if (ph_nvar >= PH_MAXVAR) err_at(ph_tfile, ph_tline, "mc-php: too many php variables");
        st64(ph_vname + ph_nvar * 8, d);
        st64(ph_vtype + ph_nvar * 8, ty);
        st64(ph_vref + ph_nvar * 8, 0);
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
    i64 lit = 0;
    if ((t == PT_INT || t == PT_BOOL) && nd_kind(v) == N_INT) { val = nd_val(v); lit = 1; }
    if (t == PT_STRING && nd_kind(v) == N_CALL && str_eq(nd_name(v), "php_str_lit")) {
        i64 raw = nd_next(nd_a(v));
        bytes = nd_name(raw);
        val = nd_val(raw);
        lit = 1;
    }
    if (!lit) {
        // not a literal: the value is computed at run time and looked up by
        // name, which is what php's own constant table is
        ph_pending_stmt(ph_stmt_of(ph_c2("php_const_set", ph_strlit(cn, cstrlen(cn)), ph_to_mixed(v, t), TY_VOID)));
        st64(ph_cname + ph_nconst * 8, cn);
        st64(ph_cty + ph_nconst * 8, -1);
        st64(ph_cval + ph_nconst * 8, 0);
        st64(ph_cstr + ph_nconst * 8, 0);
        ph_nconst = ph_nconst + 1;
        return;
    }
    st64(ph_cname + ph_nconst * 8, cn);
    st64(ph_cty + ph_nconst * 8, t);
    st64(ph_cval + ph_nconst * 8, val);
    st64(ph_cstr + ph_nconst * 8, bytes);
    ph_nconst = ph_nconst + 1;
}

// ---- the predefined constants ----------------------------------------------
// value kinds: 0 int, 1 string, 2 float (built by the runtime from its text)
#define PH_MAXPRE 160
uptr ph_pren[PH_MAXPRE];
i64  ph_prek[PH_MAXPRE];
i64  ph_prev[PH_MAXPRE];
uptr ph_pres[PH_MAXPRE];
i64  ph_npre;

void ph_pre(uptr n, i64 k, i64 v, uptr s) {
    if (ph_npre >= PH_MAXPRE) err_at("php.mc", 1, "mc-php: too many predefined constants");
    st64(ph_pren + ph_npre * 8, n);
    st64(ph_prek + ph_npre * 8, k);
    st64(ph_prev + ph_npre * 8, v);
    st64(ph_pres + ph_npre * 8, s);
    ph_npre = ph_npre + 1;
}

i64 ph_pre_find(uptr n) {
    i64 i = 0;
    loop {
        if (i >= ph_npre) break;
        if (str_eq(ld64(ph_pren + i * 8), n)) return i;
        i = i + 1;
    }
    return -1;
}

void ph_pre_init() {
    ph_pre("E_ERROR", 0, 1, 0);
    ph_pre("E_WARNING", 0, 2, 0);
    ph_pre("E_PARSE", 0, 4, 0);
    ph_pre("E_NOTICE", 0, 8, 0);
    ph_pre("E_CORE_ERROR", 0, 16, 0);
    ph_pre("E_CORE_WARNING", 0, 32, 0);
    ph_pre("E_COMPILE_ERROR", 0, 64, 0);
    ph_pre("E_COMPILE_WARNING", 0, 128, 0);
    ph_pre("E_USER_ERROR", 0, 256, 0);
    ph_pre("E_USER_WARNING", 0, 512, 0);
    ph_pre("E_USER_NOTICE", 0, 1024, 0);
    ph_pre("E_STRICT", 0, 2048, 0);
    ph_pre("E_RECOVERABLE_ERROR", 0, 4096, 0);
    ph_pre("E_DEPRECATED", 0, 8192, 0);
    ph_pre("E_USER_DEPRECATED", 0, 16384, 0);
    ph_pre("E_ALL", 0, 30719, 0);
    ph_pre("SORT_REGULAR", 0, 0, 0);
    ph_pre("SORT_NUMERIC", 0, 1, 0);
    ph_pre("SORT_STRING", 0, 2, 0);
    ph_pre("SORT_DESC", 0, 3, 0);
    ph_pre("SORT_ASC", 0, 4, 0);
    ph_pre("SORT_LOCALE_STRING", 0, 5, 0);
    ph_pre("SORT_NATURAL", 0, 6, 0);
    ph_pre("SORT_FLAG_CASE", 0, 8, 0);
    ph_pre("COUNT_NORMAL", 0, 0, 0);
    ph_pre("COUNT_RECURSIVE", 0, 1, 0);
    ph_pre("ENT_QUOTES", 0, 3, 0);
    ph_pre("ENT_COMPAT", 0, 2, 0);
    ph_pre("ENT_NOQUOTES", 0, 0, 0);
    ph_pre("ENT_HTML5", 0, 48, 0);
    ph_pre("ENT_HTML401", 0, 0, 0);
    ph_pre("ENT_SUBSTITUTE", 0, 8, 0);
    ph_pre("ENT_IGNORE", 0, 4, 0);
    ph_pre("LC_ALL", 0, 0, 0);
    ph_pre("LC_COLLATE", 0, 1, 0);
    ph_pre("LC_CTYPE", 0, 2, 0);
    ph_pre("LC_MONETARY", 0, 3, 0);
    ph_pre("LC_NUMERIC", 0, 4, 0);
    ph_pre("LC_TIME", 0, 5, 0);
    ph_pre("LC_MESSAGES", 0, 6, 0);
    ph_pre("PHP_MAJOR_VERSION", 0, 8, 0);
    ph_pre("PHP_MINOR_VERSION", 0, 5, 0);
    ph_pre("PHP_RELEASE_VERSION", 0, 10, 0);
    ph_pre("PHP_INT_SIZE", 0, 8, 0);
    ph_pre("PHP_FLOAT_DIG", 0, 15, 0);
    ph_pre("JSON_PRETTY_PRINT", 0, 128, 0);
    ph_pre("JSON_UNESCAPED_SLASHES", 0, 64, 0);
    ph_pre("JSON_UNESCAPED_UNICODE", 0, 256, 0);
    ph_pre("JSON_THROW_ON_ERROR", 0, 4194304, 0);
    ph_pre("JSON_HEX_TAG", 0, 1, 0);
    ph_pre("JSON_HEX_QUOT", 0, 8, 0);
    ph_pre("JSON_HEX_AMP", 0, 2, 0);
    ph_pre("JSON_HEX_APOS", 0, 4, 0);
    ph_pre("JSON_NUMERIC_CHECK", 0, 32, 0);
    ph_pre("JSON_PRESERVE_ZERO_FRACTION", 0, 1024, 0);
    ph_pre("JSON_ERROR_NONE", 0, 0, 0);
    ph_pre("ARRAY_FILTER_USE_KEY", 0, 2, 0);
    ph_pre("ARRAY_FILTER_USE_BOTH", 0, 1, 0);
    ph_pre("PHP_ROUND_HALF_UP", 0, 1, 0);
    ph_pre("PHP_ROUND_HALF_DOWN", 0, 2, 0);
    ph_pre("PHP_ROUND_HALF_EVEN", 0, 3, 0);
    ph_pre("PHP_ROUND_HALF_ODD", 0, 4, 0);
    ph_pre("SEEK_SET", 0, 0, 0);
    ph_pre("SEEK_CUR", 0, 1, 0);
    ph_pre("SEEK_END", 0, 2, 0);
    ph_pre("PREG_PATTERN_ORDER", 0, 1, 0);
    ph_pre("PREG_SET_ORDER", 0, 2, 0);
    ph_pre("PREG_SPLIT_NO_EMPTY", 0, 1, 0);
    ph_pre("CASE_LOWER", 0, 0, 0);
    ph_pre("CASE_UPPER", 0, 1, 0);
    ph_pre("STR_PAD_RIGHT", 0, 1, 0);
    ph_pre("STR_PAD_LEFT", 0, 0, 0);
    ph_pre("STR_PAD_BOTH", 0, 2, 0);
    ph_pre("PHP_VERSION_ID", 0, 80510, 0);
    ph_pre("MB_CASE_UPPER", 0, 0, 0);
    ph_pre("MB_CASE_LOWER", 0, 1, 0);
    ph_pre("MB_CASE_TITLE", 0, 2, 0);
    ph_pre("DEBUG_BACKTRACE_IGNORE_ARGS", 0, 2, 0);
    ph_pre("PHP_MAXPATHLEN", 0, 1024, 0);
    ph_pre("PHP_EOL", 1, 1, "\n");
    ph_pre("PHP_OS", 1, 6, "Darwin");
    ph_pre("PHP_OS_FAMILY", 1, 6, "Darwin");
    ph_pre("DIRECTORY_SEPARATOR", 1, 1, "/");
    ph_pre("PATH_SEPARATOR", 1, 1, ":");
    ph_pre("PHP_VERSION", 1, 6, "8.5.10");
    ph_pre("PHP_EXTRA_VERSION", 1, 0, "");
    ph_pre("PHP_SAPI", 1, 3, "cli");
    ph_pre("PHP_BINARY", 1, 3, "php");
    ph_pre("M_PI", 2, 0, "3.141592653589793");
    ph_pre("M_E", 2, 0, "2.718281828459045");
    ph_pre("M_SQRT2", 2, 0, "1.4142135623730951");
    ph_pre("M_LN2", 2, 0, "0.6931471805599453");
    ph_pre("M_LN10", 2, 0, "2.302585092994046");
    ph_pre("M_LOG2E", 2, 0, "1.4426950408889634");
    ph_pre("M_LOG10E", 2, 0, "0.4342944819032518");
    ph_pre("M_PI_2", 2, 0, "1.5707963267948966");
    ph_pre("M_PI_4", 2, 0, "0.7853981633974483");
    ph_pre("M_1_PI", 2, 0, "0.3183098861837907");
    ph_pre("M_2_PI", 2, 0, "0.6366197723675814");
    ph_pre("M_SQRT1_2", 2, 0, "0.7071067811865476");
    ph_pre("M_2_SQRTPI", 2, 0, "1.1283791670955126");
    ph_pre("M_EULER", 2, 0, "0.5772156649015329");
    ph_pre("M_SQRT3", 2, 0, "1.7320508075688772");
    ph_pre("PHP_FLOAT_EPSILON", 2, 0, "2.220446049250313e-16");
    ph_pre("PHP_FLOAT_MAX", 2, 0, "1.7976931348623157e+308");
    ph_pre("PHP_FLOAT_MIN", 2, 0, "2.2250738585072014e-308");
}
// ---- the library table -----------------------------------------------------
// Every row is one php function whose arguments are zvals and whose result is
// a native value of `ret`. Missing optional arguments are php_znull(), so the
// runtime sees a fixed arity and does its own ZPP.
#define PH_MAXLIB 384

uptr ph_ln[PH_MAXLIB];
uptr ph_lf[PH_MAXLIB];
i64  ph_lmin[PH_MAXLIB];
i64  ph_lmax[PH_MAXLIB];
i64  ph_lret[PH_MAXLIB];
i64  ph_nlib;

void ph_lib(uptr name, uptr fn, i64 mn, i64 mx, i64 ret) {
    if (ph_nlib >= PH_MAXLIB) err_at("php.mc", 1, "mc-php: too many library rows");
    st64(ph_ln + ph_nlib * 8, name);
    st64(ph_lf + ph_nlib * 8, fn);
    st64(ph_lmin + ph_nlib * 8, mn);
    st64(ph_lmax + ph_nlib * 8, mx);
    st64(ph_lret + ph_nlib * 8, ret);
    ph_nlib = ph_nlib + 1;
}

i64 ph_lib_find(uptr n) {
    i64 i = 0;
    loop {
        if (i >= ph_nlib) break;
        if (str_eq(ld64(ph_ln + i * 8), n)) return i;
        i = i + 1;
    }
    return -1;
}

// ---- the function table ----------------------------------------------------
#define PH_MAXFN  256
#define PH_MAXP   12

uptr ph_fname[PH_MAXFN];
i64  ph_fret[PH_MAXFN];
i64  ph_fnp[PH_MAXFN];
i64  ph_fpt[PH_MAXFN * PH_MAXP];
i64  ph_fpd[PH_MAXFN * PH_MAXP];        // the default value node, 0 = none
i64  ph_fvar[PH_MAXFN];                 // 1 when the last parameter is ...$rest
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
// mixed is a zval: the one type every other one converts into, which is what
// makes an array element, an untyped parameter and `int / int` expressible.
i64 ph_to_mixed(i64 n, i64 t) {
    if (t == PT_MIXED || t == PT_NULL) return n;
    if (t == PT_INT)    return ph_c1("php_zlong", n, ty_pzv);
    if (t == PT_IFALSE) return ph_c1("php_zifalse", n, ty_pzv);
    if (t == PT_FLOAT)  return ph_c1("php_zdouble", n, ty_pzv);
    if (t == PT_STRING) return ph_c1("php_zstr", n, ty_pzv);
    if (t == PT_BOOL)   return ph_c1("php_zbool", n, ty_pzv);
    if (t == PT_ARR)    return ph_c1("php_zarr", n, ty_pzv);
    if (t == PT_OBJ)    return ph_c1("php_zobj", n, ty_pzv);
    ph_refuse2(ph_tfile, ph_tline, "converting to mixed", ph_tyname(t), "D4");
    return 0;
}

// an array subscript: php's own key rules live in the runtime, so a key is
// just a zval and the runtime decides int vs string vs numeric-string.
i64 ph_zkey(i64 n, i64 t) { return ph_to_mixed(n, t); }

i64 ph_to_str(i64 n, i64 t) {
    if (t == PT_STRING) return n;
    if (t == PT_INT)    return ph_c1("php_itos", n, ty_pstr);
    if (t == PT_IFALSE) return ph_c1("php_itos", n, ty_pstr);
    if (t == PT_FLOAT)  return ph_c1("php_ftos", n, ty_pstr);
    if (t == PT_BOOL)   return ph_c1("php_btos", n, ty_pstr);
    if (t == PT_MIXED || t == PT_NULL) return ph_c1("php_zv_str", n, ty_pstr);
    if (t == PT_ARR || t == PT_OBJ) return ph_c1("php_zv_str", ph_to_mixed(n, t), ty_pstr);
    ph_refuse2(ph_tfile, ph_tline, "converting to string", ph_tyname(t), "D4");
    return 0;
}

i64 ph_to_int(i64 n, i64 t) {
    if (t == PT_INT || t == PT_IFALSE) return n;
    if (t == PT_BOOL)   return ph_cast(TY_I64, n);
    if (t == PT_FLOAT)  return ph_cast(TY_I64, n);
    if (t == PT_STRING) return ph_c1("php_stoi", n, TY_I64);
    if (t == PT_MIXED || t == PT_NULL) return ph_c1("php_zv_long", n, TY_I64);
    if (t == PT_ARR || t == PT_OBJ) return ph_c1("php_zv_long", ph_to_mixed(n, t), TY_I64);
    ph_refuse2(ph_tfile, ph_tline, "converting to int", ph_tyname(t), "D4");
    return 0;
}

i64 ph_to_float(i64 n, i64 t) {
    if (t == PT_FLOAT) return n;
    if (t == PT_INT || t == PT_IFALSE || t == PT_BOOL) return ph_cast(ty_f64, n);
    if (t == PT_STRING) return ph_c1("php_stof", n, ty_f64);
    if (t == PT_MIXED || t == PT_NULL) return ph_c1("php_zv_double", n, ty_f64);
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
    if (t == PT_MIXED)  return ph_cast(TY_U8, ph_c1("php_zv_bool", n, TY_I64));
    if (t == PT_NULL)   return ph_bool(0);
    if (t == PT_OBJ)    return ph_bool(1);
    ph_refuse2(ph_tfile, ph_tline, "converting to bool", ph_tyname(t), "D4");
    return 0;
}

// ---- the expression grammar (the module's own -- T4's finding) -------------
i64 ph_ety;                     // the php type of the node ph_expr just returned
i64 ph_fn_ret;                  // the php return type of the function being parsed
i64 ph_efresh;                  // the value is a brand-new array: no copy needed


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
        i64 vt = PT_MIXED;
        i64 v = 0;
        if (ph_var_find(d2) < 0) v = ph_c1("php_undef_var", ph_raw(d2 + 1, cstrlen(d2) - 1), ty_pzv);
        if (!v) {
            vt = ph_var_type(d2);
            v = node_new(N_IDENT, ph_tline, ph_tfile);
            set_nd_name(v, ph_mangle(d2, "v_"));
            set_nd_type(v, ph_mcty(vt));
        }
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

// an array literal: [1, 2, 3], ["k" => $v], array(...), mixed elements, any
// key php accepts. Every value is a zval, so nothing here is homogeneous.
i64 ph_array_lit(uptr close) {
    ph_nonce = ph_nonce + 1;
    uptr an = p_cat("pha_", php_dec(ph_nonce), 0, cstrlen(php_dec(ph_nonce)));
    i64 head = 0;
    i64 tail = 0;
    i64 n = 0;
    loop {
        if (ph_at(close, 1)) break;
        i64 spread = 0;
        if (ph_at("...", 3)) { ph_next(); spread = 1; }
        i64 v = ph_expr(0);
        i64 vt = ph_ety;
        i64 k = 0;
        if (ph_at("=>", 2)) {
            ph_next();
            k = ph_zkey(v, vt);
            if (ph_at("&", 1)) ph_todo(ph_tfile, ph_tline, "an array element by reference");
            v = ph_expr(0);
            vt = ph_ety;
        }
        i64 aref = node_new(N_IDENT, ph_tline, ph_tfile);
        set_nd_name(aref, an);
        set_nd_type(aref, ty_parr);
        i64 push = 0;
        if (spread) push = ph_c2("php_arr_spread", aref, ph_to_mixed(v, vt), TY_VOID);
        if (!spread && k)  push = ph_c3("php_arr_set", aref, k, ph_to_mixed(v, vt), TY_VOID);
        if (!spread && !k) push = ph_c2("php_arr_push", aref, ph_to_mixed(v, vt), TY_VOID);
        i64 st = node_new(N_EXPRSTMT, ph_tline, ph_tfile);
        set_nd_a(st, push);
        if (tail) set_nd_next(tail, st);
        if (!tail) head = st;
        tail = st;
        n = n + 1;
        if (!ph_accept(",", 1)) break;
    }
    ph_want(close, 1, "expected the end of a php array literal");
    // A literal is a LOCAL plus a run of inserts emitted before the statement
    // that contains it (ph_pending_stmt), and the expression is the local --
    // mc has no comma operator and this needs none.
    ph_local(an, ty_parr);
    i64 cap = 8;
    loop { if (cap >= n) break; cap = cap * 2; }
    i64 mk = ph_set(an, ph_c1("php_arr_new", ph_int(cap), ty_parr));
    set_nd_next(mk, head);
    ph_pending_stmt(mk);
    i64 out = node_new(N_IDENT, ph_tline, ph_tfile);
    set_nd_name(out, an);
    set_nd_type(out, ty_parr);
    ph_ety = PT_ARR;
    ph_efresh = 1;
    return out;
}

// statements an expression needs emitted BEFORE it (an array literal builds
// itself with a run of pushes). The statement parser drains this.
i64 ph_pend_head;
i64 ph_pend_tail;

// take the pending statements out of the way before parsing a BODY, which
// would otherwise steal them into itself (a foreach over an array literal
// would then rebuild the array inside its own loop)
i64 ph_take_pend() {
    i64 h = ph_pend_head;
    ph_pend_head = 0;
    ph_pend_tail = 0;
    return h;
}

i64 ph_prefix_stmts(i64 pre, i64 s) {
    if (!pre) return s;
    i64 t = pre;
    loop { if (!nd_next(t)) break; t = nd_next(t); }
    set_nd_next(t, s);
    return pre;
}

void ph_pending_stmt(i64 s) {
    i64 t = s;
    loop { if (!nd_next(t)) break; t = nd_next(t); }
    if (ph_pend_tail) set_nd_next(ph_pend_tail, s);
    if (!ph_pend_tail) ph_pend_head = s;
    ph_pend_tail = t;
}

// Reading a variable with neither a declaration nor a first assignment is the
// one place T6 said D4 had no answer. php's answer is a WARNING and null, and
// null is a value of `mixed`, which D4 (c) already lowers to a zval -- so the
// read is expressible without the variable gaining a type: a later `$x = 5`
// still declares $x an int. The refusal is retired.
i64 ph_var_ref(uptr d) {
    if (ph_var_find(d) < 0) {
        ph_ety = PT_MIXED;
        // `$x ?? d` reads without warning, and the token after the name is
        // what says so -- the same test ph_index makes after its `]`.
        if (ph_at("??", 2)) return ph_call("php_znull", 0, 0, 0, 0, 0, ty_pzv);
        return ph_c1("php_undef_var", ph_raw(d + 1, cstrlen(d) - 1), ty_pzv);
    }
    i64 t = ph_var_type(d);
    i64 n = node_new(N_IDENT, ph_tline, ph_tfile);
    set_nd_name(n, ph_mangle(d, "v_"));
    set_nd_type(n, ph_mcty(t));
    ph_ety = t;
    return n;
}

// $a[i] / $s[i] on the right-hand side. An array element is a zval, which is
// what makes an array heterogeneous (D4 (d)); a string offset is a string.
i64 ph_index(i64 base, i64 bt) {
    if (bt == PT_STRING) {
        i64 i = ph_to_int(ph_expr(0), ph_ety);
        ph_want("]", 1, "expected ] after a php string offset");
        ph_ety = PT_STRING;
        return ph_c2("php_str_off", base, i, ty_pstr);
    }
    i64 k = ph_zkey(ph_expr(0), ph_ety);
    ph_want("]", 1, "expected ] after a php array index");
    ph_ety = PT_MIXED;
    // php's `??` is a FETCH_DIM_IS and warns for nothing it reads; the one
    // thing that tells this read apart from any other is the token after the
    // closing bracket, and it is right here.
    if (bt == PT_MIXED) {
        if (ph_at("??", 2)) return ph_c2("php_arr_zget", ph_c1("php_zv_arr_r", base, ty_parr), k, ty_pzv);
        return ph_c2("php_zv_dim_rd", base, k, ty_pzv);
    }
    if (ph_at("??", 2)) return ph_c2("php_arr_zget", base, k, ty_pzv);
    return ph_c2("php_arr_zget_w", base, k, ty_pzv);
}

// the postfix chain every expression can carry: [ ], and (from T6's object
// block) -> and ::. It is one function so a call, a literal and a variable all
// get the same one.
i64 ph_postfix(i64 v, i64 vt) {
    loop {
        if (ph_at("[", 1)) {
            // php reads an offset of a scalar as null with a warning; D4
            // knows the static type, so the conversion to a zval is the
            // compiler's and the warning is the runtime's.
            if (vt != PT_ARR && vt != PT_MIXED && vt != PT_STRING) {
                v = ph_to_mixed(v, vt);
                vt = PT_MIXED;
            }
            ph_next();
            if (ph_at("]", 1)) err_at(ph_tfile, ph_tline, "mc-php: cannot use [] for reading");
            v = ph_index(v, vt);
            vt = ph_ety;
            continue;
        }
        if (ph_at("->", 2) || ph_at("?->", 3)) {
            ph_next();
            if (ph_at("$", 1) || ph_at("{", 1))
                ph_refuse(ph_tfile, ph_tline, "a property name that is not a literal", "D6");
            if (ph_tid != T_IDENT) err_at2(ph_tfile, ph_tline, "mc-php: a php property needs a name", ph_tname);
            uptr pn = ph_tname;
            uptr fl2 = ph_tfile;
            i64 line2 = ph_tline;
            ph_next();
            i64 recv = ph_recv(v, vt);
            i64 iscall = 0;
            if (ph_at("(", 1)) iscall = 1;
            if (iscall)  v = ph_mcall_node(recv, pn, fl2, line2);
            uptr pg = "php_zv_pget";
            if (ph_at("??", 2)) pg = "php_zv_pget_q";       // `$o->p ?? d` is silent
            if (!iscall) v = ph_c3(pg, recv, ph_strlit(pn, cstrlen(pn)), ph_scope(), ty_pzv);
            vt = PT_MIXED;
            continue;
        }
        if (ph_at("(", 1) && vt == PT_MIXED) {
            // a callable value: $f(...) and (expr)(...)
            u8 nb[8];
            uptr av = ph_read_args(5, ph_tfile, ph_tline, nb);
            u8 all[64];
            st64(all, v);
            st64(all + 8, ph_int(ld64(nb)));
            i64 i = 0;
            loop {
                if (i >= 5) break;
                i64 a = ph_int(0);
                if (i < ld64(nb)) a = ph_to_mixed(ph_a(av, i), ph_aty(av, i));
                st64(all + 16 + i * 8, a);
                i = i + 1;
            }
            v = ph_calln("php_call_zv", all, 7, ty_pzv);
            vt = PT_MIXED;
            continue;
        }
        break;
    }
    ph_ety = vt;
    return v;
}

i64 ph_primary() {
    ph_efresh = 0;
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
    if (ph_at(".", 1)) {
        uptr q0 = p_cp();
        uptr e0 = p_src_end();
        if (q0 < e0 && ph_digit(ld8(q0), 10) >= 0) {
            uptr q = q0;
            loop { if (q >= e0) break; i64 c = ld8(q); if (ph_digit(c, 10) >= 0 || c == 95) { q = q + 1; continue; } if (c == 101 || c == 69) { q = q + 1; if (q < e0 && (ld8(q) == 43 || ld8(q) == 45)) q = q + 1; continue; } break; }
            uptr txt = xalloc(q - q0 + 4);
            st8(txt, 48);
            st8(txt + 1, 46);
            i64 z = 0;
            loop { if (z >= q - q0) break; st8(txt + 2 + z, ld8(q0 + z)); z = z + 1; }
            st8(txt + 2 + (q - q0), 0);
            p_skip_to(q);
            ph_next();
            ph_ety = PT_FLOAT;
            return ph_c1("php_stof", ph_strlit(txt, cstrlen(txt)), ty_f64);
        }
    }
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
        if (!ph_wordish()) err_at2(fl, line, "mc-php: a php variable needs a name", ph_tname);
        uptr d = p_cat("$", ph_tname, 0, cstrlen(ph_tname));
        ph_next();
        if (ph_at("::", 2)) ph_refuse(fl, line, "a class name from a variable", "D6");
        i64 v = ph_var_ref(d);
        return ph_postfix(v, ph_ety);
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
        if (t == PT_FLOAT) return ph_c1("php_fneg", v, ty_f64);
        // -"1.2" is float(-1.2) and -"abc" is a TypeError: a zval keeps its
        // own rules, and converting to int first threw the fraction away.
        if (t == PT_MIXED || t == PT_STRING || t == PT_NULL) {
            ph_can_throw = 1;
            ph_ety = PT_MIXED;
            return ph_c1("php_zv_neg", ph_to_mixed(v, t), ty_pzv);
        }
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
    if (ph_at("~", 1)) {
        ph_next();
        i64 v = ph_expr(70);
        i64 t = ph_ety;
        if (t == PT_MIXED || t == PT_STRING) { ph_ety = PT_MIXED; return ph_c1("php_zv_bnot", ph_to_mixed(v, t), ty_pzv); }
        ph_ety = PT_INT;
        return ph_bin(ph_tok("-", 1), ph_bin(ph_tok("-", 1), ph_int(0), ph_to_int(v, t), TY_I64), ph_int(1), TY_I64);
    }
    if (ph_at("++", 2) || ph_at("--", 2)) {
        // ++$x in expression position: the increment is a pending statement
        i64 up = 1;
        if (ph_at("--", 2)) up = 0;
        ph_next();
        if (!ph_at("$", 1)) ph_todo(fl, line, "++ on something that is not a $variable");
        ph_next();
        uptr d = p_cat("$", ph_tname, 0, cstrlen(ph_tname));
        ph_next();
        if (ph_var_find(d) < 0) ph_refuse2(fl, line, "an undefined php variable", d, "D4");
        i64 t = ph_var_type(d);
        i64 lv = node_new(N_IDENT, line, fl);
        set_nd_name(lv, ph_mangle(d, "v_"));
        set_nd_type(lv, ph_mcty(t));
        i64 val = 0;
        if (t == PT_MIXED) {
            uptr f = "php_zv_inc";
            if (!up) f = "php_zv_dec";
            val = ph_c1(f, lv, ty_pzv);
        }
        if (t != PT_MIXED) {
            i64 one = ph_int(1);
            if (t == PT_FLOAT) one = ph_cast(ty_f64, ph_int(1));
            val = ph_bin(ph_tok("+", 1), lv, one, ph_mcty(t));
            if (!up) set_nd_op(val, ph_tok("-", 1));
        }
        if (ph_is_ref(d)) {
            i64 lvi = node_new(N_IDENT, line, fl);
            set_nd_name(lvi, ph_mangle(d, "v_"));
            set_nd_type(lvi, ty_pzv);
            ph_pending_stmt(ph_expr_stmt_of(ph_c2("php_zv_store", lvi, val, ty_pzv)));
        }
        if (!ph_is_ref(d)) ph_pending_stmt(ph_set(ph_mangle(d, "v_"), val));
        i64 r = node_new(N_IDENT, line, fl);
        set_nd_name(r, ph_mangle(d, "v_"));
        set_nd_type(r, ph_mcty(t));
        ph_ety = t;
        return r;
    }
    // @EXPR: php suppresses the diagnostics the expression raises and keeps
    // its value. The runtime has a suppression depth since T7's diagnostic
    // channel, so this is a pending statement on each side of a temporary --
    // the pendings are a queue, so the expression's own land between them.
    if (ph_at("@", 1)) {
        ph_next();
        ph_pending_stmt(ph_stmt_of(ph_call("php_quiet_on", 0, 0, 0, 0, 0, TY_VOID)));
        i64 av = ph_expr(70);
        i64 at = ph_ety;
        i64 atmp = ph_temp(av, ph_mcty(at), "pha_");
        ph_pending_stmt(ph_stmt_of(ph_call("php_quiet_off", 0, 0, 0, 0, 0, TY_VOID)));
        ph_ety = at;
        return ph_tref(atmp);
    }
    if (ph_is("new")) {
        ph_next();
        ph_accept("\\", 1);
        if (ph_at("$", 1)) ph_refuse(fl, line, "new with a class name from a variable", "D6");
        if (ph_is("class")) ph_todo(fl, line, "an anonymous class");
        if (ph_tid != T_IDENT) err_at2(fl, line, "mc-php: a php class name was expected after new", ph_tname);
        uptr cn = ph_tname;
        ph_next();
        loop { if (!ph_accept("\\", 1)) break; cn = ph_tname; ph_next(); }
        i64 ob = ph_c3("php_new_at", ph_strlit(cn, cstrlen(cn)), ph_strlit(fl, cstrlen(fl)), ph_int(line), TY_UPTR);
        i64 tmp = ph_temp(ob, TY_UPTR, "phw_");
        i64 hasargs = 0;
        if (ph_at("(", 1)) hasargs = 1;
        if (hasargs) {
            u8 nb[8];
            uptr ma = ph_margs(nb, fl, line);
            u8 all[80];
            st64(all, ph_tref(tmp));
            st64(all + 8, ph_strlit("__construct", 11));
            st64(all + 16, ph_scope());
            st64(all + 24, ph_int(ld64(nb)));
            i64 i = 0;
            loop { if (i >= 6) break; st64(all + 32 + i * 8, ld64(ma + i * 8)); i = i + 1; }
            ph_pending_stmt(ph_stmt_of(ph_calln("php_ctor", all, 10, ty_pzv)));
        }
        if (!hasargs) ph_pending_stmt(ph_stmt_of(ph_c1("php_ctor0", ph_tref(tmp), ty_pzv)));
        ph_ety = PT_OBJ;
        return ph_tref(tmp);
    }
    if (ph_is("fn")) { ph_next(); return ph_closure(fl, line, 1); }
    if (ph_is("function")) { ph_next(); ph_accept("&", 1); return ph_closure(fl, line, 0); }
    if (ph_is("static")) {
        // `static function () {}` / `static fn() =>`: a closure with no $this
        ph_next();
        if (ph_is("fn")) { ph_next(); return ph_closure(fl, line, 1); }
        if (ph_is("function")) { ph_next(); ph_accept("&", 1); return ph_closure(fl, line, 0); }
        ph_todo2(fl, line, "the storage keyword", "static");
    }
    if (ph_is("match")) {
        ph_next();
        ph_want("(", 1, "expected ( after match");
        i64 sv = ph_expr(0);
        i64 svt = ph_ety;
        ph_want(")", 1, "expected ) after match");
        ph_want("{", 1, "expected { after match");
        i64 subj = ph_temp(ph_to_mixed(sv, svt), ty_pzv, "phm_");
        i64 res = ph_temp(ph_call("php_znull", 0, 0, 0, 0, 0, ty_pzv), ty_pzv, "phr_");
        i64 chain = 0;
        i64 last = 0;
        i64 hasdef = 0;
        loop {
            if (ph_at("}", 1)) break;
            if (ph_tid == T_EOF) err_at(fl, line, "mc-php: unterminated match");
            i64 cond = 0;
            i64 isdef = 0;
            if (ph_is("default")) { ph_next(); isdef = 1; }
            if (!isdef) {
                loop {
                    i64 cv = ph_expr(0);
                    i64 one = ph_cast(TY_U8, ph_c2("php_zv_identical", ph_tref(subj), ph_to_mixed(cv, ph_ety), TY_I64));
                    if (!cond) cond = one;
                    if (cond != one) cond = ph_bin(ph_tok("||", 2), cond, one, TY_U8);
                    if (!ph_accept(",", 1)) break;
                    if (ph_at("=>", 2)) break;
                }
            }
            ph_want("=>", 2, "expected => in a match arm");
            i64 rv = ph_expr(0);
            i64 asg = ph_set(nd_name(res), ph_to_mixed(rv, ph_ety));
            if (isdef) {
                hasdef = 1;
                if (last) set_nd_c(last, asg);
                if (!chain) chain = asg;
                last = 0;
            }
            if (!isdef) {
                i64 iff = node_new(N_IF, line, fl);
                set_nd_a(iff, cond);
                set_nd_b(iff, asg);
                if (last) set_nd_c(last, iff);
                if (!chain) chain = iff;
                last = iff;
            }
            if (!ph_accept(",", 1)) break;
        }
        ph_want("}", 1, "expected } after match");
        if (!hasdef && last)
            set_nd_c(last, ph_stmt_of(ph_c1("php_unhandled_match", ph_tref(subj), ty_pzv)));
        if (chain) ph_pending_stmt(chain);
        ph_ety = PT_MIXED;
        return ph_tref(res);
    }
    if (ph_is("clone")) {
        ph_next();
        i64 v = ph_expr(70);
        i64 vt2 = ph_ety;
        ph_ety = PT_MIXED;
        return ph_c1("php_clone", ph_recv(v, vt2), ty_pzv);
    }
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
    return -1;
}

// the zval road: php's own numeric-string, overflow-to-float and array-union
// rules all live in the runtime, so anything the static types cannot answer
// exactly is lowered to one call instead of guessed at here.
i64 ph_arith_zv(i64 op, i64 lhs, i64 lt, i64 rhs, i64 rt) {
    uptr f = 0;
    if (op == ph_tok("+", 1))  f = "php_zv_add";
    if (op == ph_tok("-", 1))  f = "php_zv_sub";
    if (op == ph_tok("*", 1))  f = "php_zv_mul";
    if (op == ph_tok("/", 1))  f = "php_zv_div";
    if (op == ph_tok("%", 1))  f = "php_zv_mod";
    if (op == ph_tok("**", 2)) f = "php_zv_pow";
    if (op == ph_tok("&", 1))  f = "php_zv_band";
    if (op == ph_tok("|", 1))  f = "php_zv_bor";
    if (op == ph_tok("^", 1))  f = "php_zv_bxor";
    if (op == ph_tok("<<", 2)) f = "php_zv_shl";
    if (op == ph_tok(">>", 2)) f = "php_zv_shr";
    if (!f) err_at(ph_tfile, ph_tline, "mc-php: this operator has no zval form");
    ph_ety = PT_MIXED;
    return ph_c2(f, ph_to_mixed(lhs, lt), ph_to_mixed(rhs, rt), ty_pzv);
}

i64 ph_numeric(i64 t) {
    if (t == PT_INT || t == PT_IFALSE || t == PT_BOOL || t == PT_FLOAT) return 1;
    return 0;
}

i64 ph_arith(i64 op, i64 lhs, i64 lt, i64 rhs, i64 rt, uptr fl, i64 line) {
    // anything a static type cannot answer exactly goes to the zval
    if (!ph_numeric(lt) || !ph_numeric(rt)) return ph_arith_zv(op, lhs, lt, rhs, rt);
    if (lt == PT_BOOL) { lhs = ph_to_int(lhs, lt); lt = PT_INT; }
    if (rt == PT_BOOL) { rhs = ph_to_int(rhs, rt); rt = PT_INT; }
    if (lt == PT_IFALSE) lt = PT_INT;
    if (rt == PT_IFALSE) rt = PT_INT;
    i64 flt = 0;
    if (lt == PT_FLOAT || rt == PT_FLOAT) flt = 1;
    if (op == ph_tok("/", 1)) {
        // int / int is int|float in php -- a union, so a zval (D4 (c))
        if (!flt) return ph_arith_zv(op, lhs, lt, rhs, rt);
        ph_ety = PT_FLOAT;
        return ph_c2("php_div_f", ph_to_float(lhs, lt), ph_to_float(rhs, rt), ty_f64);
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
    if (op == ph_tok("<<", 2) || op == ph_tok(">>", 2)) {
        ph_ety = PT_INT;
        uptr sf = "php_shl_i";
        if (op == ph_tok(">>", 2)) sf = "php_shr_i";
        ph_can_throw = 1;
        return ph_c2(sf, ph_to_int(lhs, lt), ph_to_int(rhs, rt), TY_I64);
    }
    if (op == ph_tok("&", 1) || op == ph_tok("|", 1) || op == ph_tok("^", 1)) {
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

i64 ph_cmp_zv(i64 t, i64 lhs, i64 lt, i64 rhs, i64 rt) {
    i64 a = ph_to_mixed(lhs, lt);
    i64 b = ph_to_mixed(rhs, rt);
    i64 neg = 0;
    if (t == ph_tok("!=", 2) || t == ph_tok("<>", 2) || t == ph_tok("!==", 3)) neg = 1;
    if (t == ph_tok("===", 3) || t == ph_tok("!==", 3)) {
        ph_ety = PT_BOOL;
        i64 id = ph_c2("php_zv_identical", a, b, TY_I64);
        i64 op = ph_tok("!=", 2);
        if (neg) op = ph_tok("==", 2);
        return ph_cast(TY_U8, ph_bin(op, id, ph_int(0), TY_U8));
    }
    i64 c = ph_c2("php_zv_cmp", a, b, TY_I64);
    if (t == ph_tok("<=>", 3)) { ph_ety = PT_INT; return c; }
    i64 op2 = t;
    if (op2 == ph_tok("<>", 2)) op2 = ph_tok("!=", 2);
    ph_ety = PT_BOOL;
    return ph_cast(TY_U8, ph_bin(op2, c, ph_int(0), TY_U8));
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
    if (lt == PT_MIXED || rt == PT_MIXED || lt == PT_NULL || rt == PT_NULL
        || ph_is_arr(lt) || ph_is_arr(rt))
        return ph_cmp_zv(t, lhs, lt, rhs, rt);
    if (lt == PT_STRING && rt != PT_STRING) return ph_cmp_zv(t, lhs, lt, rhs, rt);
    if (rt == PT_STRING && lt != PT_STRING) return ph_cmp_zv(t, lhs, lt, rhs, rt);
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
    ph_efresh = 0;
    i64 lhs = ph_postfix(ph_primary(), ph_ety);
    i64 lt = ph_ety;
    loop {
        if (ph_is("instanceof")) {
            if (minp > 65) break;
            ph_next();
            ph_accept("\\", 1);
            uptr cn = ph_tname;
            if (ph_at("$", 1)) ph_refuse(ph_tfile, ph_tline, "instanceof with a class name from a variable", "D6");
            ph_next();
            lhs = ph_cast(TY_U8, ph_c2("php_instanceof", ph_recv(lhs, lt), ph_strlit(cn, cstrlen(cn)), TY_I64));
            lt = PT_BOOL;
            continue;
        }
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
        if (ph_prec(t) == 45 || ph_prec(t) == 40) {
            lhs = ph_compare(t, lhs, lt, rhs, rt, fl, line);
            lt = ph_ety;
            continue;
        }
        lhs = ph_arith(t, lhs, lt, rhs, rt, fl, line);
        lt = ph_ety;
    }
    ph_ety = lt;
    // ?? and the conditional, both right-associative and both short-circuiting.
    // A short circuit needs a branch, and an mc expression has none: the value
    // is a temporary assigned by statements ph_pending_stmt emits in front of
    // the statement that contains the expression.
    if (minp <= 26 && ph_at("??", 2)) {
        i64 line2 = ph_tline;
        uptr fl2 = ph_tfile;
        i64 tmp = ph_temp(ph_to_mixed(lhs, lt), ty_pzv, "phn_");
        ph_next();
        i64 r = ph_expr(26);
        i64 rt = ph_ety;
        i64 nn = node_new(N_UNARY, line2, fl2);
        set_nd_op(nn, ph_tok("!", 1));
        set_nd_a(nn, ph_cast(TY_U8, ph_c1("php_zv_isset", ph_tref(tmp), TY_I64)));
        set_nd_type(nn, TY_U8);
        i64 iff = node_new(N_IF, line2, fl2);
        set_nd_a(iff, nn);
        set_nd_b(iff, ph_set(nd_name(tmp), ph_to_mixed(r, rt)));
        ph_pending_stmt(iff);
        ph_ety = PT_MIXED;
        return ph_tref(tmp);
    }
    if (minp <= 20 && ph_at("?", 1)) {
        i64 line3 = ph_tline;
        uptr fl3 = ph_tfile;
        i64 tmp2 = ph_temp(ph_to_mixed(lhs, lt), ty_pzv, "phq_");
        i64 cnd = ph_cast(TY_U8, ph_c1("php_zv_bool", ph_tref(tmp2), TY_I64));
        ph_next();
        i64 thenv = 0;
        if (!ph_at(":", 1)) {                      // the full a ? b : c
            i64 b = ph_expr(0);
            thenv = ph_set(nd_name(tmp2), ph_to_mixed(b, ph_ety));
        }
        ph_want(":", 1, "expected : in a php conditional");
        i64 c = ph_expr(20);
        i64 elsev = ph_set(nd_name(tmp2), ph_to_mixed(c, ph_ety));
        i64 iff2 = node_new(N_IF, line3, fl3);
        set_nd_a(iff2, cnd);
        if (thenv) { set_nd_b(iff2, thenv); set_nd_c(iff2, elsev); }
        if (!thenv) {                              // a ?: c
            i64 nn2 = node_new(N_UNARY, line3, fl3);
            set_nd_op(nn2, ph_tok("!", 1));
            set_nd_a(nn2, cnd);
            set_nd_type(nn2, TY_U8);
            set_nd_a(iff2, nn2);
            set_nd_b(iff2, elsev);
        }
        ph_pending_stmt(iff2);
        ph_ety = PT_MIXED;
        return ph_tref(tmp2);
    }
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
        i64 sct = ph_can_throw;
        ph_can_throw = 0;
        i64 a = ph_expr(0);
        i64 t = ph_ety;
        // An argument that can throw is computed into a temporary with the
        // unwinding check BETWEEN computing it and the call, exactly as the
        // echo path already does: php stops at the throwing argument, and
        // `var_dump("65" / "0")` must print nothing before the catch runs
        // (T6 printed NULL first).
        if (ph_can_throw) {
            i64 tmp = ph_temp(a, ph_mcty(t), "phg_");
            ph_pending_stmt(ph_check(ph_tline, ph_tfile));
            a = ph_tref(tmp);
        }
        ph_can_throw = ph_can_throw | sct;
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

// is_int/is_string/...: a compile-time answer when the type is static (D4),
// a runtime one when the value is a zval
i64 ph_isof(i64 na, i64 t0, i64 a0, i64 want, i64 ztype, uptr fl, i64 line, uptr name) {
    if (na != 1) ph_todo2(fl, line, "the wrong number of arguments for", name);
    ph_ety = PT_BOOL;
    if (t0 == PT_MIXED || t0 == PT_NULL) return ph_cast(TY_U8, ph_c2("php_zv_is", a0, ph_int(ztype), TY_I64));
    if (t0 == want) return ph_bool(1);
    if (want == PT_INT && t0 == PT_IFALSE) return ph_bool(1);
    return ph_bool(0);
}

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
    if (t == PT_NULL)   return ph_c2("php_vd_zv", v, ph_int(0), TY_VOID);
    if (t == PT_MIXED)  return ph_c2("php_vd_zv", v, ph_int(0), TY_VOID);
    if (t == PT_ARR)    return ph_c2("php_vd_arr", v, ph_int(0), TY_VOID);
    if (t == PT_OBJ)    return ph_c2("php_vd_obj", v, ph_int(0), TY_VOID);
    ph_todo2(fl, line, "var_dump of", ph_tyname(t));
    return 0;
}

i64 ph_echo_of(i64 v, i64 t, uptr fl, i64 line) {
    if (t == PT_INT || t == PT_IFALSE) return ph_c1("php_echo_int", v, TY_I64);
    if (t == PT_BOOL)   return ph_c1("php_echo_bool", v, TY_I64);
    if (t == PT_FLOAT)  return ph_c1("php_echo_float", v, TY_I64);
    if (t == PT_STRING) return ph_c1("php_echo_str", v, TY_I64);
    if (t == PT_MIXED || t == PT_NULL) return ph_c1("php_echo_zv", v, TY_I64);
    if (t == PT_ARR)    return ph_c1("php_echo_zv", ph_to_mixed(v, t), TY_I64);
    ph_todo2(fl, line, "echo of", ph_tyname(t));
    return 0;
}

// sprintf/printf/vsprintf/vprintf: the FORMAT must be a literal (D1), so the
// compiler walks it and emits ONE php_spf call per conversion. There is no
// run-time format walker in the binary.
i64 ph_sprintf(uptr av, i64 na, uptr fl, i64 line, i64 vec) {
    i64 f = ph_a(av, 0);
    if (nd_kind(f) != N_CALL || !str_eq(nd_name(f), "php_str_lit"))
        ph_refuse(fl, line, "a printf format that is not a literal", "D1");
    i64 raw = nd_next(nd_a(f));                     // the N_STR argument
    uptr b = nd_name(raw);
    i64 n = nd_val(raw);
    // vsprintf: every argument comes out of ONE array, by position
    i64 arr = 0;
    if (vec) {
        if (na < 2) ph_todo2(fl, line, "the wrong number of arguments for", "vsprintf");
        i64 at = ph_aty(av, 1);
        arr = ph_a(av, 1);
        if (at == PT_MIXED) arr = ph_c1("php_zv_arr_r", arr, ty_parr);
        if (at != PT_MIXED && at != PT_ARR) ph_todo(fl, line, "vsprintf without an array");
        arr = ph_temp(arr, ty_parr, "phv_");
    }
    i64 acc = 0;
    i64 seg = 0;
    i64 i = 0;
    i64 ai = 1;
    i64 vi = 0;
    loop {
        if (i >= n) break;
        if (ld8(b + i) != 37) { i = i + 1; continue; }
        if (i > seg) {
            i64 lit = ph_strlit(xstrdup(b + seg, i - seg), i - seg);
            if (acc) acc = ph_c2("php_str_concat", acc, lit, ty_pstr);
            if (!acc) acc = lit;
        }
        i64 p = i + 1;
        if (p < n && ld8(b + p) == 37) {
            i64 pc = ph_strlit("%", 1);
            if (acc) acc = ph_c2("php_str_concat", acc, pc, ty_pstr);
            if (!acc) acc = pc;
            i = p + 1;
            seg = i;
            continue;
        }
        // [argnum$][flags][width][.precision]conv
        i64 argnum = 0;
        i64 q = p;
        i64 num = 0;
        i64 any = 0;
        loop {
            if (q >= n) break;
            i64 c = ld8(b + q);
            if (c < 48 || c > 57) break;
            num = num * 10 + (c - 48);
            any = 1;
            q = q + 1;
        }
        if (any && q < n && ld8(b + q) == 36) { argnum = num; p = q + 1; }
        i64 flags = 0;
        i64 pad = 32;
        loop {
            if (p >= n) break;
            i64 c = ld8(b + p);
            if (c == 45) { flags = flags | 1; p = p + 1; continue; }
            if (c == 43) { flags = flags | 2; p = p + 1; continue; }
            if (c == 32) { flags = flags | 4; p = p + 1; continue; }
            if (c == 48) { flags = flags | 8; pad = 48; p = p + 1; continue; }
            if (c == 39 && p + 1 < n) { pad = ld8(b + p + 1); p = p + 2; continue; }
            break;
        }
        i64 width = 0;
        loop {
            if (p >= n) break;
            i64 c = ld8(b + p);
            if (c < 48 || c > 57) break;
            width = width * 10 + (c - 48);
            p = p + 1;
        }
        i64 prec = -1;
        if (p < n && ld8(b + p) == 46) {
            p = p + 1;
            prec = 0;
            loop {
                if (p >= n) break;
                i64 c = ld8(b + p);
                if (c < 48 || c > 57) break;
                prec = prec * 10 + (c - 48);
                p = p + 1;
            }
        }
        if (p >= n) err_at(fl, line, "mc-php: a printf format that ends in %");
        i64 conv = ld8(b + p);
        p = p + 1;
        i64 val = 0;
        if (vec) {
            i64 idx = vi;
            if (argnum) idx = argnum - 1;
            if (!argnum) vi = vi + 1;
            val = ph_c2("php_arr_iget", ph_tref(arr), ph_int(idx), ty_pzv);
        }
        if (!vec) {
            i64 k = ai;
            if (argnum) k = argnum;
            if (!argnum) ai = ai + 1;
            if (k >= na) ph_todo(fl, line, "a printf format with more conversions than arguments");
            val = ph_to_mixed(ph_a(av, k), ph_aty(av, k));
        }
        u8 six[8];
        st64(six, val);
        i64 piece = ph_call("php_spf", 4, val, ph_int(flags), ph_int(width), ph_int(prec), ty_pstr);
        // php_spf takes six arguments; the last two go on with set_nd_next
        i64 t5 = ph_int(conv);
        i64 t6 = ph_int(pad);
        set_nd_next(ph_int(0), 0);
        i64 lastarg = nd_a(piece);
        loop { if (!nd_next(lastarg)) break; lastarg = nd_next(lastarg); }
        set_nd_next(lastarg, t5);
        set_nd_next(t5, t6);
        if (acc) acc = ph_c2("php_str_concat", acc, piece, ty_pstr);
        if (!acc) acc = piece;
        i = p;
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
    if (str_eq(name, "true") || str_eq(name, "TRUE") || str_eq(name, "True"))  { ph_next(); ph_ety = PT_BOOL; return ph_bool(1); }
    if (str_eq(name, "false") || str_eq(name, "FALSE") || str_eq(name, "False")) { ph_next(); ph_ety = PT_BOOL; return ph_bool(0); }
    if (str_eq(name, "null") || str_eq(name, "NULL") || str_eq(name, "Null")) {
        ph_next();
        ph_ety = PT_NULL;
        return ph_call("php_znull", 0, 0, 0, 0, 0, ty_pzv);
    }
    if (str_eq(name, "PHP_INT_MAX"))  { ph_next(); ph_ety = PT_INT; return ph_int(9223372036854775807); }
    if (str_eq(name, "PHP_INT_MIN"))  { ph_next(); ph_ety = PT_INT; return ph_bin(ph_tok("-", 1), ph_int(-9223372036854775807), ph_int(1), TY_I64); }
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
        i64 meth = str_eq(name, "__METHOD__");
        ph_next();
        ph_ety = PT_STRING;
        if (!ph_cur_fn) return ph_strlit("", 0);
        if (!meth || !ph_cur_cls) return ph_strlit(ph_cur_fn, cstrlen(ph_cur_fn));
        uptr q = p_cat(ph_cur_cls, "::", 0, 2);
        q = p_cat(q, ph_cur_fn, 0, cstrlen(ph_cur_fn));
        return ph_strlit(q, cstrlen(q));
    }
    i64 pi = ph_pre_find(name);
    if (pi >= 0) {
        ph_next();
        i64 pk = ld64(ph_prek + pi * 8);
        if (pk == 0) { ph_ety = PT_INT; return ph_int(ld64(ph_prev + pi * 8)); }
        if (pk == 1) {
            uptr sv = ld64(ph_pres + pi * 8);
            ph_ety = PT_STRING;
            return ph_strlit(sv, ld64(ph_prev + pi * 8));
        }
        uptr fv = ld64(ph_pres + pi * 8);
        ph_ety = PT_FLOAT;
        return ph_c1("php_stof", ph_strlit(fv, cstrlen(fv)), ty_f64);
    }
    if (str_eq(name, "NAN")) { ph_next(); ph_ety = PT_FLOAT; return ph_c1("php_nan", ph_int(0), ty_f64); }
    if (str_eq(name, "INF")) { ph_next(); ph_ety = PT_FLOAT; return ph_c1("php_inf", ph_int(0), ty_f64); }
    if (str_eq(name, "__CLASS__")) {
        ph_next();
        ph_ety = PT_STRING;
        if (!ph_cur_cls) return ph_strlit("", 0);
        return ph_strlit(ph_cur_cls, cstrlen(ph_cur_cls));
    }
    // a constant this program declared with `const` or define()
    i64 ci = ph_const_find(name);
    if (ci >= 0) {
        ph_next();
        i64 ct = ld64(ph_cty + ci * 8);
        if (ct < 0) { ph_ety = PT_MIXED; return ph_c1("php_const_get", ph_strlit(name, cstrlen(name)), ty_pzv); }
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
        i64 acc = 0;
        loop {
            if (ph_at(")", 1)) break;
            if (!ph_at("$", 1)) ph_todo2(fl, line, "isset/empty of", "something that is not a $variable");
            ph_next();
            if (!ph_wordish()) err_at(fl, line, "mc-php: a php variable needs a name");
            uptr d = p_cat("$", ph_tname, 0, cstrlen(ph_tname));
            ph_next();
            i64 one = 0;
            if (ph_var_find(d) < 0) {
                // an undefined variable: isset is false, empty is true, and
                // php does not warn for either
                loop { if (!ph_at("[", 1)) break; ph_next(); ph_expr(0); ph_want("]", 1, "expected ]"); }
                one = ph_bool(0);
                if (isempty) one = ph_bool(1);
            }
            if (ph_var_find(d) >= 0) {
                i64 t = ph_var_type(d);
                i64 v = node_new(N_IDENT, line, fl);
                set_nd_name(v, ph_mangle(d, "v_"));
                set_nd_type(v, ph_mcty(t));
                loop {
                    if (!ph_at("[", 1)) break;
                    if (t == PT_MIXED) { v = ph_c1("php_zv_arr_r", v, ty_parr); t = PT_ARR; }
                    if (t == PT_STRING) { ph_next(); v = ph_c2("php_str_off", v, ph_to_int(ph_expr(0), ph_ety), ty_pstr); ph_want("]", 1, "expected ]"); t = PT_STRING; continue; }
                    if (t != PT_ARR) ph_refuse2(fl, line, "indexing a value that is not an array", ph_tyname(t), "D4");
                    ph_next();
                    i64 k = ph_zkey(ph_expr(0), ph_ety);
                    ph_want("]", 1, "expected ] in isset/empty");
                    if (!isempty) v = ph_c2("php_zv_isset_key", v, k, TY_I64);
                    if (isempty)  v = ph_c2("php_arr_zget", v, k, ty_pzv);
                    t = PT_MIXED;
                    if (!isempty) t = PT_INT;
                    if (!isempty) { if (ph_at("[", 1)) ph_todo(fl, line, "isset of a nested array element"); }
                }
                if (!isempty) {
                    if (t == PT_INT)   one = ph_cast(TY_U8, ph_bin(ph_tok("!=", 2), v, ph_int(0), TY_U8));
                    if (t == PT_MIXED) one = ph_cast(TY_U8, ph_c1("php_zv_isset", v, TY_I64));
                    if (t != PT_INT && t != PT_MIXED) one = ph_bool(1);
                }
                if (isempty) {
                    i64 b = ph_to_bool(v, t);
                    i64 nn = node_new(N_UNARY, line, fl);
                    set_nd_op(nn, ph_tok("!", 1));
                    set_nd_a(nn, b);
                    set_nd_type(nn, TY_U8);
                    one = nn;
                }
            }
            if (!acc) acc = one;
            if (acc != one) acc = ph_bin(ph_tok("&&", 2), acc, one, TY_U8);
            if (!ph_accept(",", 1)) break;
        }
        ph_want(")", 1, "expected ) in a php call");
        ph_ety = PT_BOOL;
        if (!acc) acc = ph_bool(1);
        return acc;
    }
    ph_next();
    if (ph_at("::", 2)) {
        ph_next();
        i64 ce = ph_ce_of(name, fl, line);
        if (ph_is("class")) {
            ph_next();
            ph_ety = PT_STRING;
            if (str_eq(name, "self") || str_eq(name, "static") || str_eq(name, "parent"))
                return ph_c1("php_ce_name", ce, ty_pstr);
            return ph_strlit(name, cstrlen(name));
        }
        if (ph_at("$", 1)) {
            ph_next();
            uptr sp = ph_tname;
            ph_next();
            i64 slot = ph_c2("php_ce_sslot", ce, ph_strlit(sp, cstrlen(sp)), ty_pzv);
            ph_ety = PT_MIXED;
            // a static property is a zval SLOT, so a write is a store into it
            // and the whole thing stays an expression
            i64 op = 0;
            if (ph_at(".=", 2))  op = ph_tok(".", 1);
            if (ph_at("+=", 2))  op = ph_tok("+", 1);
            if (ph_at("-=", 2))  op = ph_tok("-", 1);
            if (ph_at("*=", 2))  op = ph_tok("*", 1);
            if (ph_at("/=", 2))  op = ph_tok("/", 1);
            if (ph_at("%=", 2))  op = ph_tok("%", 1);
            if (ph_at("++", 2) || ph_at("--", 2)) {
                uptr f = "php_zv_inc";
                if (ph_at("--", 2)) f = "php_zv_dec";
                ph_next();
                i64 t2 = ph_temp(slot, ty_pzv, "phs_");
                return ph_c2("php_zv_store", ph_tref(t2), ph_c1(f, ph_tref(t2), ty_pzv), ty_pzv);
            }
            if (op) {
                ph_next();
                i64 t3 = ph_temp(slot, ty_pzv, "phs_");
                i64 r = ph_expr(0);
                i64 rt = ph_ety;
                i64 v = 0;
                if (op == ph_tok(".", 1)) v = ph_c2("php_zv_concat", ph_tref(t3), ph_to_mixed(r, rt), ty_pzv);
                if (op != ph_tok(".", 1)) v = ph_arith_zv(op, ph_tref(t3), PT_MIXED, r, rt);
                ph_ety = PT_MIXED;
                return ph_c2("php_zv_store", ph_tref(t3), v, ty_pzv);
            }
            if (ph_at("=", 1)) {
                ph_next();
                i64 r2 = ph_expr(0);
                i64 v2 = ph_to_mixed(ph_own(r2, ph_ety), ph_ety);
                ph_ety = PT_MIXED;
                return ph_c2("php_zv_store", slot, v2, ty_pzv);
            }
            return slot;
        }
        if (ph_tid != T_IDENT) err_at2(fl, line, "mc-php: a php class member was expected", ph_tname);
        uptr mn = ph_tname;
        ph_next();
        if (ph_at("(", 1)) return ph_scall_node(ce, mn, fl, line);
        ph_ety = PT_MIXED;
        return ph_c2("php_ce_getconst", ce, ph_strlit(mn, cstrlen(mn)), ty_pzv);
    }
    if (!ph_at("(", 1)) {
        // php looks an unknown bare name up in the constant table at RUN time
        // and raises Error if it is not there
        ph_ety = PT_MIXED;
        return ph_c1("php_const_get", ph_strlit(name, cstrlen(name)), ty_pzv);
    }

    if (str_eq(name, "sprintf") || str_eq(name, "printf")
        || str_eq(name, "vsprintf") || str_eq(name, "vprintf")) {
        i64 vec = 0;
        if (str_eq(name, "vsprintf") || str_eq(name, "vprintf")) vec = 1;
        u8 pn0[8];
        uptr av0 = ph_read_args(16, fl, line, pn0);
        i64 s = ph_sprintf(av0, ld64(pn0), fl, line, vec);
        if (str_eq(name, "sprintf") || str_eq(name, "vsprintf")) { ph_ety = PT_STRING; return s; }
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
        if (t0 == PT_MIXED) { ph_ety = PT_INT; return ph_c1("php_count", ph_c1("php_zv_arr_r", a0, ty_parr), TY_I64); }
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
        if (at == PT_MIXED) { arr = ph_c1("php_zv_arr_r", arr, ty_parr); at = PT_ARR; }
        if (!ph_is_arr(at)) {                            // implode($arr, $sep), the legacy order
            sep = ph_a(av, 1);
            arr = a0;
            at = t0;
            if (at == PT_MIXED) { arr = ph_c1("php_zv_arr_r", arr, ty_parr); at = PT_ARR; }
            sep = ph_to_str(sep, ph_aty(av, 1));
        }
        if (!ph_is_arr(at)) ph_todo(fl, line, "implode() without an array");
        ph_ety = PT_STRING;
        return ph_c2("php_implode", ph_to_str(sep, ph_aty(av, 0)), arr, ty_pstr);
    }
    if (str_eq(name, "explode")) {
        if (na != 2) ph_need(na, 2, name, fl, line);
        ph_ety = PT_ARR;
        ph_efresh = 1;
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
        // a literal name is ALSO a compile-time constant, which keeps the
        // typed road; the run-time table is what constant()/defined() read
        if (t0 == PT_STRING && nd_kind(a0) == N_CALL && str_eq(nd_name(a0), "php_str_lit")) {
            i64 rawn = nd_next(nd_a(a0));
            uptr cn2 = xstrdup(nd_name(rawn), nd_val(rawn));
            if (ph_const_find(cn2) < 0) ph_const_add(cn2, ph_a(av, 1), ph_aty(av, 1), fl, line);
        }
        ph_ety = PT_BOOL;
        return ph_c2("php_f_define", ph_to_mixed(a0, t0), ph_to_mixed(ph_a(av, 1), ph_aty(av, 1)), TY_U8);
    }
    if (str_eq(name, "defined")) {
        ph_need(na, 1, name, fl, line);
        ph_ety = PT_BOOL;
        if (t0 == PT_STRING && nd_kind(a0) == N_CALL && str_eq(nd_name(a0), "php_str_lit")) {
            i64 rawd = nd_next(nd_a(a0));
            if (ph_const_find(xstrdup(nd_name(rawd), nd_val(rawd))) >= 0) return ph_bool(1);
            if (ph_pre_find(xstrdup(nd_name(rawd), nd_val(rawd))) >= 0) return ph_bool(1);
        }
        return ph_cast(TY_U8, ph_c1("php_f_defined", ph_to_mixed(a0, t0), TY_I64));
    }
    if (str_eq(name, "chr")) { ph_need(na, 1, name, fl, line); ph_ety = PT_STRING; return ph_c1("php_chr", ph_to_int(a0, t0), ty_pstr); }
    if (str_eq(name, "ord")) { ph_need(na, 1, name, fl, line); ph_ety = PT_INT; return ph_c1("php_ord", ph_to_str(a0, t0), TY_I64); }
    if (str_eq(name, "strtoupper")) { ph_need(na, 1, name, fl, line); ph_ety = PT_STRING; return ph_c1("php_strtoupper", ph_to_str(a0, t0), ty_pstr); }
    if (str_eq(name, "strtolower")) { ph_need(na, 1, name, fl, line); ph_ety = PT_STRING; return ph_c1("php_strtolower", ph_to_str(a0, t0), ty_pstr); }
    if (str_eq(name, "ucfirst")) { ph_need(na, 1, name, fl, line); ph_ety = PT_STRING; return ph_c1("php_ucfirst", ph_to_str(a0, t0), ty_pstr); }
    if (str_eq(name, "lcfirst")) { ph_need(na, 1, name, fl, line); ph_ety = PT_STRING; return ph_c1("php_lcfirst", ph_to_str(a0, t0), ty_pstr); }
    if (str_eq(name, "strrev")) { ph_need(na, 1, name, fl, line); ph_ety = PT_STRING; return ph_c1("php_strrev", ph_to_str(a0, t0), ty_pstr); }
    if (str_eq(name, "trim") || str_eq(name, "ltrim") || str_eq(name, "rtrim") || str_eq(name, "chop")) {
        if (na < 1 || na > 2) ph_todo2(fl, line, "the wrong number of arguments for", name);
        uptr f = "php_f_trim";
        if (str_eq(name, "ltrim")) f = "php_f_ltrim";
        if (str_eq(name, "rtrim") || str_eq(name, "chop")) f = "php_f_rtrim";
        i64 cl = ph_call("php_znull", 0, 0, 0, 0, 0, ty_pzv);
        if (na == 2) cl = ph_to_mixed(ph_a(av, 1), ph_aty(av, 1));
        ph_ety = PT_STRING;
        return ph_c2(f, ph_to_mixed(a0, t0), cl, ty_pstr);
    }
    if (str_eq(name, "str_pad")) {
        if (na < 2 || na > 4) ph_need(na, 2, name, fl, line);
        i64 pad = ph_strlit(" ", 1);
        i64 type = ph_int(1);                       // STR_PAD_RIGHT
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
    if (str_eq(name, "is_int") || str_eq(name, "is_integer") || str_eq(name, "is_long"))
        return ph_isof(na, t0, a0, PT_INT, 4, fl, line, name);
    if (str_eq(name, "is_scalar")) {
        ph_need(na, 1, name, fl, line); ph_ety = PT_BOOL;
        if (t0 == PT_MIXED || t0 == PT_NULL) return ph_cast(TY_U8, ph_c1("php_zv_isscalar", a0, TY_I64));
        if (t0 == PT_ARR) return ph_bool(0);
        return ph_bool(1);
    }
    if (str_eq(name, "is_object")) {
        ph_need(na, 1, name, fl, line); ph_ety = PT_BOOL;
        if (t0 == PT_MIXED) return ph_cast(TY_U8, ph_c2("php_zv_is", a0, ph_int(8), TY_I64));
        return ph_bool(0);
    }
    if (str_eq(name, "is_string")) return ph_isof(na, t0, a0, PT_STRING, 6, fl, line, name);
    if (str_eq(name, "is_float") || str_eq(name, "is_double")) return ph_isof(na, t0, a0, PT_FLOAT, 5, fl, line, name);
    if (str_eq(name, "is_bool")) return ph_isof(na, t0, a0, PT_BOOL, 3, fl, line, name);
    if (str_eq(name, "is_array")) return ph_isof(na, t0, a0, PT_ARR, 7, fl, line, name);
    if (str_eq(name, "is_null")) return ph_isof(na, t0, a0, PT_NULL, 1, fl, line, name);
    if (str_eq(name, "is_numeric")) {
        ph_need(na, 1, name, fl, line); ph_ety = PT_BOOL;
        if (t0 == PT_MIXED || t0 == PT_NULL) return ph_cast(TY_U8, ph_c1("php_zv_isnum", a0, TY_I64));
        if (t0 == PT_INT || t0 == PT_FLOAT) return ph_bool(1);
        if (t0 == PT_STRING) return ph_cast(TY_U8, ph_c1("php_zv_isnum", ph_to_mixed(a0, t0), TY_I64));
        return ph_bool(0);
    }
    if (str_eq(name, "function_exists")) { ph_ety = PT_BOOL; return ph_bool(0); }

    // a php function this program declared
    i64 fi = ph_fn_find(name);
    if (fi < 0) {
        i64 li = ph_lib_find(name);
        if (li >= 0) {
            i64 mn = ld64(ph_lmin + li * 8);
            i64 mx = ld64(ph_lmax + li * 8);
            if (na < mn || na > mx) ph_todo2(fl, line, "the wrong number of arguments for", name);
            i64 lhead = 0;
            i64 ltail = 0;
            i64 j = 0;
            loop {
                if (j >= mx) break;
                i64 an = ph_call("php_znull", 0, 0, 0, 0, 0, ty_pzv);
                if (j < na) an = ph_to_mixed(ph_a(av, j), ph_aty(av, j));
                if (ltail) set_nd_next(ltail, an);
                if (!ltail) lhead = an;
                ltail = an;
                j = j + 1;
            }
            i64 lc = node_new(N_CALL, line, fl);
            set_nd_name(lc, ld64(ph_lf + li * 8));
            set_nd_a(lc, lhead);
            i64 lr = ld64(ph_lret + li * 8);
            set_nd_type(lc, ph_mcty(lr));
            ph_ety = lr;
            if (lr == PT_ARR) ph_efresh = 1;
            return lc;
        }
        ph_todo2(fl, line, "a php function mc-php does not have", name);
    }
    i64 np = ld64(ph_fnp + fi * 8);
    i64 vararg = ld64(ph_fvar + fi * 8);
    if (na > np && !vararg) ph_todo2(fl, line, "the wrong number of arguments for", name);
    i64 head = 0;
    i64 tail = 0;
    i64 i = 0;
    loop {
        if (i >= np) break;
        i64 want = ld64(ph_fpt + (fi * PH_MAXP + i) * 8);
        i64 v = 0;
        if (vararg && i == np - 1) {
            // ...$rest: the caller packs what is left into an array
            ph_nonce = ph_nonce + 1;
            uptr rn = p_cat("phva_", php_dec(ph_nonce), 0, cstrlen(php_dec(ph_nonce)));
            ph_local(rn, ty_parr);
            i64 mk = ph_set(rn, ph_c1("php_arr_new", ph_int(8), ty_parr));
            i64 mt = mk;
            i64 j = i;
            loop {
                if (j >= na) break;
                i64 ar = node_new(N_IDENT, line, fl);
                set_nd_name(ar, rn);
                set_nd_type(ar, ty_parr);
                i64 ps = ph_stmt_of(ph_c2("php_arr_push", ar, ph_to_mixed(ph_a(av, j), ph_aty(av, j)), TY_VOID));
                set_nd_next(mt, ps);
                mt = ps;
                j = j + 1;
            }
            ph_pending_stmt(mk);
            v = node_new(N_IDENT, line, fl);
            set_nd_name(v, rn);
            set_nd_type(v, ty_parr);
        }
        if (!v && i >= na) {
            // not passed: a zval parameter takes 0, which its prologue reads
            if (want != PT_MIXED) ph_todo2(fl, line, "the wrong number of arguments for", name);
            v = ph_int(0);
        }
        if (!v) {
            i64 have = ph_aty(av, i);
            v = ph_a(av, i);
            if (want == PT_INT)    v = ph_to_int(v, have);
            if (want == PT_FLOAT)  v = ph_to_float(v, have);
            if (want == PT_STRING) v = ph_to_str(v, have);
            if (want == PT_BOOL)   v = ph_to_bool(v, have);
            if (want == PT_MIXED)  v = ph_to_mixed(v, have);
            if (want == PT_ARR && have == PT_MIXED) v = ph_c1("php_zv_arr_r", v, ty_parr);
        }
        if (tail) set_nd_next(tail, v);
        if (!tail) head = v;
        tail = v;
        i = i + 1;
    }
    ph_can_throw = 1;
    i64 c = node_new(N_CALL, line, fl);
    set_nd_name(c, ph_mangle(name, "f_"));
    set_nd_a(c, head);
    i64 rt = ld64(ph_fret + fi * 8);
    set_nd_type(c, ph_mcty(rt));
    ph_ety = rt;
    return c;
}


// ---- unwinding -------------------------------------------------------------
void ph_ls_push(i64 kind) {
    if (ph_nls >= PH_MAXLS) err_at(ph_tfile, ph_tline, "mc-php: loops nested too deep");
    st64(ph_lstack + ph_nls * 8, kind);
    ph_nls = ph_nls + 1;
}

void ph_ls_pop() { if (ph_nls) ph_nls = ph_nls - 1; }

// the mc break level for a php level of n LOOPS
i64 ph_ls_level(i64 n, uptr fl, i64 line) {
    i64 want = n;
    i64 lv = 0;
    i64 i = ph_nls - 1;
    loop {
        if (i < 0) break;
        lv = lv + 1;
        if (!ld64(ph_lstack + i * 8)) {
            want = want - 1;
            if (want == 0) return lv;
        }
        i = i - 1;
    }
    return lv;
}

// the propagation check emitted after a statement that can throw: break out
// of the innermost try, or leave the function
i64 ph_check(i64 line, uptr fl) {
    i64 cond = ph_call("php_thrown", 0, 0, 0, 0, 0, TY_I64);
    i64 act = 0;
    if (ph_in_try) {
        act = node_new(N_BREAK, line, fl);
        set_nd_val(act, 1);
    }
    if (!ph_in_try && ph_toplevel) act = ph_stmt_of(ph_call("php_uncaught", 0, 0, 0, 0, 0, TY_VOID));
    if (!ph_in_try && !ph_toplevel) {
        act = node_new(N_RETURN, line, fl);
        if (ph_fn_ret == PT_MIXED) set_nd_a(act, ph_call("php_znull", 0, 0, 0, 0, 0, ty_pzv));
        if (ph_fn_ret == PT_INT || ph_fn_ret == PT_BOOL || ph_fn_ret == PT_IFALSE) set_nd_a(act, ph_int(0));
        if (ph_fn_ret == PT_FLOAT) set_nd_a(act, ph_cast(ty_f64, ph_int(0)));
        if (ph_fn_ret == PT_STRING) set_nd_a(act, ph_strlit("", 0));
        if (ph_fn_ret == PT_ARR) set_nd_a(act, ph_c1("php_arr_new", ph_int(8), ty_parr));
    }
    i64 iff = node_new(N_IF, line, fl);
    set_nd_a(iff, ph_cast(TY_U8, cond));
    set_nd_b(iff, act);
    return iff;
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

// ---- the position php's diagnostics report ---------------------------------
// php prints "in FILE on line N", and FILE is the path php RESOLVED, so a
// relative argument comes out absolute. The compiler stores the pair into two
// runtime globals once per statement (php_pos); threading a file and a line
// through all 173 library rows instead would touch every one of them.
//
// Known and written down in RESULTS.md: a diagnostic raised after a user
// function RETURNED, inside the same statement, reports the line that callee
// last set. A statement whose warning comes before any user call -- which is
// nearly all of them -- is exact.
#define PH_MAXFL 64
uptr ph_flsrc[PH_MAXFL];
uptr ph_flabs[PH_MAXFL];
i64  ph_nfl;

uptr ph_absfile(uptr fl) {
    i64 i = 0;
    loop {
        if (i >= ph_nfl) break;
        if (str_eq(ld64(ph_flsrc + i * 8), fl)) return ld64(ph_flabs + i * 8);
        i = i + 1;
    }
    uptr a = fl;
    if (ld8(fl) != 47) {
        uptr cwd = host_getcwd();
        if (cwd) a = path_norm(path_join(p_cat(cwd, "/x", 0, 2), fl));
    }
    if (ph_nfl < PH_MAXFL) {
        st64(ph_flsrc + ph_nfl * 8, fl);
        st64(ph_flabs + ph_nfl * 8, a);
        ph_nfl = ph_nfl + 1;
    }
    return a;
}

i64 ph_posstmt(uptr fl, i64 line) {
    uptr a = ph_absfile(fl);
    i64 c = ph_c2("php_pos", ph_raw(a, cstrlen(a)), ph_int(line), TY_VOID);
    i64 s = node_new(N_EXPRSTMT, line, fl);
    set_nd_a(s, c);
    return s;
}

// a statement, followed by the unwinding check when it contains a call
i64 ph_stmt_checked() {
    i64 save = ph_can_throw;
    ph_can_throw = 0;
    i64 line = ph_tline;
    uptr fl = ph_tfile;
    i64 st = ph_stmt();
    if (ph_can_throw) {
        i64 t = st;
        loop { if (!nd_next(t)) break; t = nd_next(t); }
        set_nd_next(t, ph_check(line, fl));
    }
    ph_can_throw = save;
    return st;
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
        i64 s = ph_stmt_checked();
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
    i64 line = ph_tline;
    uptr fl = ph_tfile;
    i64 s = ph_stmt_checked();
    i64 b = node_new(N_BLOCK, line, fl);
    set_nd_a(b, s);
    return b;
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
        pre = ph_set(fn, ph_int(1));                 // spliced in before the loop, below
        i64 fref = node_new(N_IDENT, line, fl);
        set_nd_name(fref, fn);
        set_nd_type(fref, TY_I64);
        i64 clr = ph_set(fn, ph_int(0));
        i64 gate = node_new(N_IF, line, fl);
        set_nd_a(gate, fref);
        set_nd_b(gate, clr);
        set_nd_c(gate, step);
        step = 0;
        i64 hold = body;                             // gate, then the old body
        body = gate;
        set_nd_next(gate, hold);
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

// ---- lvalues ---------------------------------------------------------------
// A php variable holds a native value of its static type; the assignment of a
// value that OWNS memory (an array, a zval) makes an independent copy, because
// a php array is a value (see php_rt.txt "array value semantics").
i64 ph_own(i64 v, i64 t) {
    if (t == PT_ARR && !ph_efresh)   return ph_c1("php_arr_copy", v, ty_parr);
    if (t == PT_MIXED || t == PT_NULL) return ph_c1("php_zv_val", v, ty_pzv);
    return v;
}

// a temporary holding an already-computed node, so a compound assignment reads
// and writes the same container and key without evaluating either twice
i64 ph_temp(i64 v, i64 mcty, uptr pfx) {
    ph_nonce = ph_nonce + 1;
    uptr tn = p_cat(pfx, php_dec(ph_nonce), 0, cstrlen(php_dec(ph_nonce)));
    ph_local(tn, mcty);
    ph_pending_stmt(ph_set(tn, v));
    i64 r = node_new(N_IDENT, ph_tline, ph_tfile);
    set_nd_name(r, tn);
    set_nd_type(r, mcty);
    return r;
}

i64 ph_tref(i64 n) {
    i64 r = node_new(N_IDENT, nd_line(n), nd_file(n));
    set_nd_name(r, nd_name(n));
    set_nd_type(r, nd_type(n));
    return r;
}

// the container of `$d[k1][k2]...`, with the LAST key written through pkey
// (0 when the last subscript is the append form `[]`).
i64 ph_lv_walk(uptr d, uptr fl, i64 line, uptr pkey, i64 hoist) {
    i64 vt = ph_var_type(d);
    i64 base = node_new(N_IDENT, line, fl);
    set_nd_name(base, ph_mangle(d, "v_"));
    set_nd_type(base, ph_mcty(vt));
    i64 cur = base;
    if (vt == PT_MIXED) cur = ph_c1("php_zv_arr_w", base, ty_parr);
    if (vt != PT_MIXED && vt != PT_ARR)
        ph_refuse2(fl, line, "indexing a value that is not an array", ph_tyname(vt), "D4");
    loop {
        ph_want("[", 1, "expected [ in a php array assignment");
        i64 k = 0;
        if (!ph_at("]", 1)) k = ph_zkey(ph_expr(0), ph_ety);
        ph_want("]", 1, "expected ] in a php array assignment");
        if (!ph_at("[", 1)) {
            if (hoist) {
                cur = ph_temp(cur, ty_parr, "phc_");
                if (k) k = ph_temp(k, ty_pzv, "phk_");
            }
            st64(pkey, k);
            return cur;
        }
        if (k)  cur = ph_c2("php_arr_dim", cur, k, ty_parr);
        if (!k) cur = ph_c1("php_arr_dimn", cur, ty_parr);
    }
    return cur;
}

i64 ph_store(i64 cur, i64 k, i64 zv) {
    if (k) return ph_c3("php_arr_set", cur, k, zv, TY_VOID);
    return ph_c2("php_arr_push", cur, zv, TY_VOID);
}

// $v = expr / $v[i] = expr / $v[] = expr, and the compound forms
i64 ph_assign_stmt(uptr fl, i64 line, i64 semi) {
    ph_next();                                       // $
    if (ph_at("$", 1)) ph_refuse(fl, line, "a variable variable $$name", "D6");
    if (!ph_wordish()) err_at2(fl, line, "mc-php: a php variable needs a name", ph_tname);
    uptr d = p_cat("$", ph_tname, 0, cstrlen(ph_tname));
    ph_next();

    if (ph_at("->", 2) || ph_at("?->", 3)) {
        if (ph_var_find(d) < 0) ph_refuse2(fl, line, "an undefined php variable", d, "D4");
        return ph_obj_stmt(d, fl, line, semi);
    }
    if (ph_at("[", 1)) {
        // a php array springs into existence on its first [] write
        if (ph_var_find(d) < 0) {
            ph_var_bind(d, PT_ARR);
            ph_pending_stmt(ph_set(ph_mangle(d, "v_"), ph_c1("php_arr_new", ph_int(8), ty_parr)));
        }
        u8 kb[8];
        i64 op = 0;
        i64 incdec = 0;
        i64 save = p_cp();
        i64 cur = ph_lv_walk(d, fl, line, kb, 0);
        // a compound form has to read the element too, so redo the walk with
        // the container and the key hoisted into temporaries
        if (ph_at(".=", 2) || ph_at("+=", 2) || ph_at("-=", 2) || ph_at("*=", 2)
            || ph_at("/=", 2) || ph_at("%=", 2) || ph_at("**=", 3) || ph_at("??=", 3)
            || ph_at("++", 2) || ph_at("--", 2)) {
            ph_todo(fl, line, "a compound assignment to an array element");
        }
        i64 k = ld64(kb);
        ph_want("=", 1, "expected = after a php array index");
        if (ph_at("&", 1)) ph_todo(fl, line, "an assignment by reference");
        i64 v = ph_expr(0);
        i64 vt = ph_ety;
        if (semi) ph_semi("expected ; after a php assignment");
        return ph_expr_stmt_of(ph_store(cur, k, ph_to_mixed(ph_own(v, vt), vt)));
    }

    i64 op = 0;
    if (ph_at(".=", 2))  op = ph_tok(".", 1);
    if (ph_at("+=", 2))  op = ph_tok("+", 1);
    if (ph_at("-=", 2))  op = ph_tok("-", 1);
    if (ph_at("*=", 2))  op = ph_tok("*", 1);
    if (ph_at("/=", 2))  op = ph_tok("/", 1);
    if (ph_at("%=", 2))  op = ph_tok("%", 1);
    if (ph_at("**=", 3)) op = ph_tok("**", 2);
    if (ph_at("|=", 2))  op = ph_tok("|", 1);
    if (ph_at("&=", 2))  op = ph_tok("&", 1);
    if (ph_at("^=", 2))  op = ph_tok("^", 1);
    if (ph_at("<<=", 3)) op = ph_tok("<<", 2);
    if (ph_at(">>=", 3)) op = ph_tok(">>", 2);
    i64 incdec = 0;
    if (ph_at("++", 2)) incdec = 1;
    if (ph_at("--", 2)) incdec = -1;

    if (incdec) {
        ph_next();
        if (semi) ph_semi("expected ; after ++/--");
        if (ph_var_find(d) < 0) ph_refuse2(fl, line, "an undefined php variable", d, "D4");
        i64 t = ph_var_type(d);
        i64 lv = node_new(N_IDENT, line, fl);
        set_nd_name(lv, ph_mangle(d, "v_"));
        set_nd_type(lv, ph_mcty(t));
        i64 val = 0;
        if (t == PT_MIXED) {
            uptr f = "php_zv_inc";
            if (incdec < 0) f = "php_zv_dec";
            val = ph_c1(f, lv, ty_pzv);
        }
        if (t != PT_MIXED) {
            i64 one = ph_int(1);
            if (t == PT_FLOAT) one = ph_cast(ty_f64, ph_int(1));
            val = ph_bin(ph_tok("+", 1), lv, one, ph_mcty(t));
            if (incdec < 0) set_nd_op(val, ph_tok("-", 1));
        }
        if (ph_is_ref(d)) {
            i64 lvi = node_new(N_IDENT, line, fl);
            set_nd_name(lvi, ph_mangle(d, "v_"));
            set_nd_type(lvi, ty_pzv);
            return ph_wrap(ph_expr_stmt_of(ph_c2("php_zv_store", lvi, val, ty_pzv)));
        }
        i64 a = node_new(N_ASSIGN, line, fl);
        set_nd_name(a, ph_mangle(d, "v_"));
        set_nd_a(a, val);
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
        if (semi) ph_semi("expected ; after a php assignment");
        i64 v = 0;
        if (op == ph_tok(".", 1)) {
            if (lt == PT_MIXED) { v = ph_c2("php_zv_concat", lv, ph_to_mixed(r, rt), ty_pzv); ph_ety = PT_MIXED; }
            if (lt != PT_MIXED) { v = ph_c2("php_str_concat", ph_to_str(lv, lt), ph_to_str(r, rt), ty_pstr); ph_ety = PT_STRING; }
        }
        if (op != ph_tok(".", 1)) v = ph_arith(op, lv, lt, r, rt, fl, line);
        if (ph_ety != lt) {
            if (lt == PT_MIXED) { v = ph_to_mixed(v, ph_ety); ph_ety = PT_MIXED; }
            if (lt == PT_FLOAT && ph_ety == PT_INT) { v = ph_to_float(v, PT_INT); ph_ety = PT_FLOAT; }
        }
        if (ph_ety != lt) {
            uptr m = p_cat(d, " was ", 0, 5);
            m = p_cat(m, ph_tyname(lt), 0, cstrlen(ph_tyname(lt)));
            m = p_cat(m, ", assigned ", 0, 11);
            m = p_cat(m, ph_tyname(ph_ety), 0, cstrlen(ph_tyname(ph_ety)));
            ph_refuse2(fl, line, "a php variable has one type", m, "D4");
        }
        if (ph_is_ref(d)) {
            i64 lv2 = node_new(N_IDENT, line, fl);
            set_nd_name(lv2, ph_mangle(d, "v_"));
            set_nd_type(lv2, ty_pzv);
            return ph_wrap(ph_expr_stmt_of(ph_c2("php_zv_store", lv2, ph_to_mixed(v, ph_ety), ty_pzv)));
        }
        i64 a = node_new(N_ASSIGN, line, fl);
        set_nd_name(a, ph_mangle(d, "v_"));
        set_nd_a(a, v);
        return ph_wrap(a);
    }

    if (ph_at("??=", 3)) {
        ph_next();
        if (ph_var_find(d) < 0) { ph_var_bind(d, PT_MIXED); ph_pending_stmt(ph_set(ph_mangle(d, "v_"), ph_call("php_znull", 0, 0, 0, 0, 0, ty_pzv))); }
        i64 lt2 = ph_var_type(d);
        i64 lv3 = node_new(N_IDENT, line, fl);
        set_nd_name(lv3, ph_mangle(d, "v_"));
        set_nd_type(lv3, ph_mcty(lt2));
        i64 r3 = ph_expr(0);
        i64 rt3 = ph_ety;
        if (semi) ph_semi("expected ; after ??=");
        if (lt2 != PT_MIXED) ph_todo2(fl, line, "??= on a variable of type", ph_tyname(lt2));
        i64 nn3 = node_new(N_UNARY, line, fl);
        set_nd_op(nn3, ph_tok("!", 1));
        set_nd_a(nn3, ph_cast(TY_U8, ph_c1("php_zv_isset", lv3, TY_I64)));
        set_nd_type(nn3, TY_U8);
        i64 iff3 = node_new(N_IF, line, fl);
        set_nd_a(iff3, nn3);
        i64 lv4 = node_new(N_IDENT, line, fl);
        set_nd_name(lv4, ph_mangle(d, "v_"));
        set_nd_type(lv4, ty_pzv);
        if (ph_is_ref(d)) set_nd_b(iff3, ph_expr_stmt_of(ph_c2("php_zv_store", lv4, ph_to_mixed(r3, rt3), ty_pzv)));
        if (!ph_is_ref(d)) set_nd_b(iff3, ph_set(ph_mangle(d, "v_"), ph_to_mixed(r3, rt3)));
        return ph_wrap(iff3);
    }

    if (!ph_at("=", 1)) {
        if (ph_at("=>", 2)) err_at(fl, line, "mc-php: unexpected => outside foreach");
        ph_todo2(fl, line, "a php variable used as a statement", d);
    }
    ph_next();
    if (ph_at("&", 1)) {
        // $a = &$b: the two names share one zval from here on
        ph_next();
        if (!ph_at("$", 1)) ph_todo(fl, line, "an assignment by reference to something that is not a $variable");
        ph_next();
        uptr src = p_cat("$", ph_tname, 0, cstrlen(ph_tname));
        ph_next();
        if (semi) ph_semi("expected ; after a php assignment");
        if (ph_var_find(src) < 0) ph_refuse2(fl, line, "an undefined php variable", src, "D4");
        if (ph_var_type(src) != PT_MIXED)
            ph_todo2(fl, line, "a reference to a php variable of type", ph_tyname(ph_var_type(src)));
        if (!ph_is_ref(src)) ph_set_ref(src);
        if (!ph_is_ref(src)) ph_set_ref(src);
        if (ph_var_find(d) < 0) ph_var_bind(d, PT_MIXED);
        ph_set_ref(d);
        i64 sr = node_new(N_IDENT, line, fl);
        set_nd_name(sr, ph_mangle(src, "v_"));
        set_nd_type(sr, ty_pzv);
        return ph_wrap(ph_set(ph_mangle(d, "v_"), sr));
    }
    i64 v = ph_expr(0);
    i64 vt = ph_ety;
    if (semi) ph_semi("expected ; after a php assignment");
    if (vt == PT_VOID) ph_refuse(fl, line, "assigning the result of a void function", "D4");
    // `$x = null` makes $x a zval: null is a value of mixed, which is what
    // D4 (c) says a union lowers to.
    if (vt == PT_NULL) { v = ph_to_mixed(v, vt); vt = PT_MIXED; }
    i64 known = ph_var_find(d);
    if (known >= 0) {
        i64 was = ph_var_type(d);
        // a mixed variable accepts any value: its declared type IS the union
        if (was == PT_MIXED && vt != PT_MIXED) { v = ph_to_mixed(v, vt); vt = PT_MIXED; }
    }
    if (ph_var_find(d) < 0 && ph_refset_has(d)) {
        // first assignment to a name something else aliases: it is a zval.
        // A name some function declares `global` is THE global of that name.
        ph_var_bind(d, PT_MIXED);
        ph_set_ref(d);
        i64 box = ph_c1("php_zv_val", ph_to_mixed(v, vt), ty_pzv);
        if (ph_toplevel && ph_gset_has(d)) {
            i64 bind = ph_set(ph_mangle(d, "v_"), ph_c1("php_gvar", ph_strlit(d + 1, cstrlen(d + 1)), ty_pzv));
            i64 lvg = node_new(N_IDENT, line, fl);
            set_nd_name(lvg, ph_mangle(d, "v_"));
            set_nd_type(lvg, ty_pzv);
            set_nd_next(bind, ph_expr_stmt_of(ph_c2("php_zv_store", lvg, ph_to_mixed(v, vt), ty_pzv)));
            return ph_wrap(bind);
        }
        return ph_wrap(ph_set(ph_mangle(d, "v_"), box));
    }
    if (ph_is_ref(d)) {
        i64 lvr = node_new(N_IDENT, line, fl);
        set_nd_name(lvr, ph_mangle(d, "v_"));
        set_nd_type(lvr, ty_pzv);
        return ph_wrap(ph_expr_stmt_of(ph_c2("php_zv_store", lvr, ph_to_mixed(ph_own(v, vt), vt), ty_pzv)));
    }
    ph_var_bind(d, vt);
    // ph_var_bind may widen a string to `mixed` (a variable this source also
    // increments), so the value follows the type the variable actually got
    i64 bt = ph_var_type(d);
    if (bt != vt) return ph_wrap(ph_set(ph_mangle(d, "v_"), ph_to_mixed(ph_own(v, vt), vt)));
    return ph_wrap(ph_set(ph_mangle(d, "v_"), ph_own(v, vt)));
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

// every statement announces its position first; a declaration and an empty
// statement lower to nothing and get none.
i64 ph_stmt() {
    i64 line = ph_tline;
    uptr fl = ph_tfile;
    i64 s = ph_stmt_1();
    if (nd_kind(s) == N_BLOCK && !nd_a(s) && !nd_next(s)) return s;
    i64 p = ph_posstmt(fl, line);
    set_nd_next(p, s);
    return p;
}

i64 ph_stmt_1() {
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
            i64 sct = ph_can_throw;
            ph_can_throw = 0;
            i64 argpre = ph_take_pend();
            i64 e = ph_expr(0);
            i64 t = ph_ety;
            i64 thr = ph_can_throw;
            ph_can_throw = sct;
            // an argument that can throw is computed into a temporary first,
            // so the check sits BETWEEN computing it and printing it: php
            // stops the whole echo at the throwing argument.
            i64 pre = 0;
            if (thr) {
                ph_nonce = ph_nonce + 1;
                uptr tn = p_cat("phe_", php_dec(ph_nonce), 0, cstrlen(php_dec(ph_nonce)));
                ph_local(tn, ph_mcty(t));
                pre = ph_set(tn, e);
                e = node_new(N_IDENT, line, fl);
                set_nd_name(e, tn);
                set_nd_type(e, ph_mcty(t));
            }
            i64 c = ph_echo_of(e, t, fl, line);
            i64 s = node_new(N_EXPRSTMT, line, fl);
            set_nd_a(s, c);
            if (thr) {
                ph_can_throw = 1;
                i64 ck = ph_check(line, fl);
                set_nd_next(pre, ck);
                set_nd_next(ck, s);
                s = pre;
            }
            // an argument's own pending statements run just before it, not
            // before the whole echo: `echo ++$x, $x` must print 2 then 2
            s = ph_prefix_stmts(ph_take_pend(), s);
            s = ph_prefix_stmts(argpre, s);
            if (tail) set_nd_next(tail, s);
            if (!tail) head = s;
            tail = s;
            loop { if (!nd_next(tail)) break; tail = nd_next(tail); }
            if (isprint) break;
            if (!ph_accept(",", 1)) break;
        }
        ph_semi("expected ; after echo");
        i64 b = node_new(N_BLOCK, line, fl);
        set_nd_a(b, head);
        return ph_wrap(b);
    }
    if (ph_is("return")) {
        ph_next();
        i64 e = 0;
        if (!ph_at(";", 1)) {
            e = ph_expr(0);
            if (ph_fn_ret == PT_MIXED) e = ph_to_mixed(ph_own(e, ph_ety), ph_ety);
            if (ph_fn_ret == PT_STRING && ph_ety != PT_STRING) e = ph_to_str(e, ph_ety);
            if (ph_fn_ret == PT_INT && ph_ety != PT_INT) e = ph_to_int(e, ph_ety);
            if (ph_fn_ret == PT_FLOAT && ph_ety != PT_FLOAT) e = ph_to_float(e, ph_ety);
            if (ph_fn_ret == PT_BOOL && ph_ety != PT_BOOL) e = ph_to_bool(e, ph_ety);
        }
        if (!e && ph_fn_ret == PT_MIXED) e = ph_call("php_znull", 0, 0, 0, 0, 0, ty_pzv);
        ph_semi("expected ; after return");
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
        ph_ls_push(0);
        i64 body = ph_block_or_stmt();
        ph_ls_pop();
        return ph_loop_of(c, body, 0, line, fl);
    }
    if (ph_is("do")) {
        ph_next();
        ph_ls_push(0);
        i64 body = ph_block_or_stmt();
        ph_ls_pop();
        if (!ph_is("while")) err_at(fl, line, "mc-php: expected while after do");
        ph_next();
        ph_want("(", 1, "expected ( after do-while");
        i64 c = ph_to_bool(ph_expr(0), ph_ety);
        ph_want(")", 1, "expected ) after do-while");
        ph_semi("expected ; after do-while");
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
        i64 fopre = ph_take_pend();
        if (ph_at(":", 1)) ph_todo(fl, line, "the alternative for: endfor; syntax");
        ph_ls_push(0);
        i64 body = ph_block_or_stmt();
        ph_ls_pop();
        i64 lp = ph_loop_of(c, body, step, line, fl);
        i64 t2 = init;
        loop { if (!nd_next(t2)) break; t2 = nd_next(t2); }
        set_nd_next(t2, lp);
        i64 outer = node_new(N_BLOCK, line, fl);
        set_nd_a(outer, init);
        return ph_wrap(ph_prefix_stmts(fopre, outer));
    }
    if (ph_is("foreach")) return ph_foreach(fl, line);
    if (ph_is("break") || ph_is("continue")) {
        i64 isbrk = ph_is("break");
        ph_next();
        i64 lv = 1;
        if (ph_tid == T_INT) { lv = ph_tval; ph_next(); }
        ph_semi("expected ; after break/continue");
        i64 n = node_new(N_BREAK, line, fl);
        if (!isbrk) n = node_new(N_CONTINUE, line, fl);
        set_nd_val(n, ph_ls_level(lv, fl, line));
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
        ph_semi("expected ; after a php const");
        return ph_empty();
    }
    if (ph_is("unset")) {
        // unset($a[k]) removes the element; unset($x) on a zval variable makes
        // it null, which is what isset() then answers. A TYPED variable has no
        // "unset" state -- its type is its declaration (D4).
        ph_next();
        ph_want("(", 1, "expected ( after unset");
        i64 head = 0;
        i64 tail = 0;
        loop {
            if (ph_at(")", 1)) break;
            if (!ph_at("$", 1)) ph_todo(fl, line, "unset of something that is not a $variable");
            ph_next();
            if (!ph_wordish()) err_at(fl, line, "mc-php: a php variable needs a name");
            uptr d = p_cat("$", ph_tname, 0, cstrlen(ph_tname));
            ph_next();
            if (ph_var_find(d) < 0) ph_refuse2(fl, line, "an undefined php variable", d, "D4");
            i64 one = 0;
            if (ph_at("[", 1)) {
                u8 kb[8];
                i64 cur = ph_lv_walk(d, fl, line, kb, 0);
                i64 k = ld64(kb);
                if (!k) err_at(fl, line, "mc-php: cannot unset $a[]");
                one = node_new(N_EXPRSTMT, line, fl);
                set_nd_a(one, ph_c2("php_arr_unset", cur, k, TY_VOID));
            }
            if (!one) {
                i64 t = ph_var_type(d);
                if (t != PT_MIXED)
                    ph_refuse2(fl, line, "unset() of a typed php variable", ph_tyname(t), "D4");
                one = ph_set(ph_mangle(d, "v_"), ph_call("php_znull", 0, 0, 0, 0, 0, ty_pzv));
            }
            if (tail) set_nd_next(tail, one);
            if (!tail) head = one;
            tail = one;
            if (!ph_accept(",", 1)) break;
        }
        ph_want(")", 1, "expected ) after unset");
        ph_semi("expected ; after unset");
        if (!head) return ph_empty();
        i64 b = node_new(N_BLOCK, line, fl);
        set_nd_a(b, head);
        return ph_wrap(b);
    }
    if (ph_is("global")) {
        ph_next();
        i64 head = 0;
        i64 tail = 0;
        loop {
            if (!ph_at("$", 1)) err_at(fl, line, "mc-php: a php variable was expected after global");
            ph_next();
            uptr d = p_cat("$", ph_tname, 0, cstrlen(ph_tname));
            ph_next();
            if (ph_var_find(d) < 0) ph_var_bind(d, PT_MIXED);
            ph_set_ref(d);
            i64 g = ph_set(ph_mangle(d, "v_"), ph_c1("php_gvar", ph_strlit(d + 1, cstrlen(d + 1)), ty_pzv));
            if (tail) set_nd_next(tail, g);
            if (!tail) head = g;
            tail = g;
            if (!ph_accept(",", 1)) break;
        }
        ph_semi("expected ; after global");
        i64 b = node_new(N_BLOCK, line, fl);
        set_nd_a(b, head);
        return b;
    }
    if (ph_is("static")) {
        // `static $x = e;` -- one zval per declaration, made on the first call
        ph_next();
        if (!ph_at("$", 1)) ph_todo2(fl, line, "the storage keyword", "static");
        i64 head2 = 0;
        i64 tail2 = 0;
        loop {
            if (!ph_at("$", 1)) break;
            ph_next();
            uptr d = p_cat("$", ph_tname, 0, cstrlen(ph_tname));
            ph_next();
            i64 init = ph_call("php_znull", 0, 0, 0, 0, 0, ty_pzv);
            if (ph_accept("=", 1)) { i64 iv = ph_expr(0); init = ph_to_mixed(iv, ph_ety); }
            ph_nonce = ph_nonce + 1;
            uptr sg = p_cat("phst_", php_dec(ph_nonce), 0, cstrlen(php_dec(ph_nonce)));
            i64 gn = node_new(N_GLOBAL, line, fl);
            set_nd_name(gn, sg);
            set_nd_type(gn, TY_UPTR);
            set_nd_val(gn, 1);
            set_nd_a(gn, 0);
            top_add(gn);
            if (ph_var_find(d) < 0) ph_var_bind(d, PT_MIXED);
            ph_set_ref(d);
            i64 gref = node_new(N_IDENT, line, fl);
            set_nd_name(gref, sg);
            set_nd_type(gref, TY_UPTR);
            i64 st2 = ph_set(ph_mangle(d, "v_"), ph_c2("php_static", gref, init, ty_pzv));
            if (tail2) set_nd_next(tail2, st2);
            if (!tail2) head2 = st2;
            tail2 = st2;
            if (!ph_accept(",", 1)) break;
        }
        ph_semi("expected ; after static");
        i64 b2 = node_new(N_BLOCK, line, fl);
        set_nd_a(b2, head2);
        return ph_wrap(b2);
    }
    if (ph_is("switch")) {
        // php numbers the arms; `m` is the first arm to run, so fall-through
        // is `if (m <= k)` and `default` is just another number.
        ph_next();
        ph_want("(", 1, "expected ( after switch");
        i64 sv = ph_expr(0);
        i64 svt = ph_ety;
        ph_want(")", 1, "expected ) after switch");
        i64 spre = ph_take_pend();
        if (ph_at(":", 1)) ph_todo(fl, line, "the alternative switch: endswitch; syntax");
        ph_want("{", 1, "expected { after switch");
        ph_nonce = ph_nonce + 1;
        uptr tn = p_cat("phsw_", php_dec(ph_nonce), 0, cstrlen(php_dec(ph_nonce)));
        uptr mn2 = p_cat("phsm_", php_dec(ph_nonce), 0, cstrlen(php_dec(ph_nonce)));
        ph_local(tn, ty_pzv);
        ph_local(mn2, TY_I64);
        i64 setv = ph_set(tn, ph_to_mixed(sv, svt));
        // pass 1: the tests, in source order, as one else-if chain
        i64 thead = 0;
        i64 tlast = 0;
        i64 bhead = 0;
        i64 btail = 0;
        i64 k = 0;
        i64 dflt = 0;
        ph_ls_push(0);
        loop {
            if (ph_at("}", 1)) break;
            if (ph_tid == T_EOF) err_at(fl, line, "mc-php: unterminated switch");
            i64 isdef = 0;
            if (ph_is("default")) { ph_next(); isdef = 1; }
            if (!isdef) {
                if (!ph_is("case")) err_at2(fl, line, "mc-php: expected case or default in switch", ph_tname);
                ph_next();
            }
            k = k + 1;
            if (!isdef) {
                i64 cv = ph_expr(0);
                i64 cvt = ph_ety;
                i64 tref2 = node_new(N_IDENT, line, fl);
                set_nd_name(tref2, tn);
                set_nd_type(tref2, ty_pzv);
                i64 eq = ph_cast(TY_U8, ph_bin(ph_tok("==", 2),
                    ph_c2("php_zv_cmp", tref2, ph_to_mixed(cv, cvt), TY_I64), ph_int(0), TY_U8));
                i64 iff = node_new(N_IF, line, fl);
                set_nd_a(iff, eq);
                set_nd_b(iff, ph_set(mn2, ph_int(k)));
                if (tlast) set_nd_c(tlast, iff);
                if (!thead) thead = iff;
                tlast = iff;
            }
            if (isdef) dflt = k;
            if (!ph_accept(":", 1)) ph_accept(";", 1);
            // the arm body: every statement until the next case/default/}
            i64 ahead = 0;
            i64 atail = 0;
            loop {
                if (ph_at("}", 1)) break;
                if (ph_is("case") || ph_is("default")) break;
                if (ph_tid == T_EOF) break;
                i64 st2 = ph_stmt_checked();
                if (atail) set_nd_next(atail, st2);
                if (!ahead) ahead = st2;
                atail = st2;
                loop { if (!nd_next(atail)) break; atail = nd_next(atail); }
            }
            i64 mref = node_new(N_IDENT, line, fl);
            set_nd_name(mref, mn2);
            set_nd_type(mref, TY_I64);
            i64 gate = node_new(N_IF, line, fl);
            set_nd_a(gate, ph_cast(TY_U8, ph_bin(ph_tok("<=", 2), mref, ph_int(k), TY_U8)));
            i64 ab = node_new(N_BLOCK, line, fl);
            set_nd_a(ab, ahead);
            set_nd_b(gate, ab);
            if (btail) set_nd_next(btail, gate);
            if (!bhead) bhead = gate;
            btail = gate;
        }
        ph_ls_pop();
        ph_next();
        i64 none = k + 1;
        if (dflt) none = dflt;
        i64 setm = ph_set(mn2, ph_int(none));
        set_nd_next(setv, setm);
        if (thead) set_nd_next(setm, thead);
        i64 brk2 = node_new(N_BREAK, line, fl);
        set_nd_val(brk2, 1);
        if (btail) set_nd_next(btail, brk2);
        if (!bhead) bhead = brk2;
        i64 lb = node_new(N_BLOCK, line, fl);
        set_nd_a(lb, bhead);
        i64 lp2 = node_new(N_LOOP, line, fl);
        set_nd_a(lp2, lb);
        i64 t3 = setv;
        loop { if (!nd_next(t3)) break; t3 = nd_next(t3); }
        set_nd_next(t3, lp2);
        i64 ob2 = node_new(N_BLOCK, line, fl);
        set_nd_a(ob2, setv);
        return ph_wrap(ph_prefix_stmts(spre, ob2));
    }
    if (ph_is("match"))  ph_todo(fl, line, "match");
    if (ph_is("throw")) {
        ph_next();
        i64 e = ph_expr(0);
        i64 et = ph_ety;
        ph_semi("expected ; after throw");
        ph_can_throw = 1;
        return ph_expr_stmt_of(ph_c1("php_throw", ph_recv(e, et), ty_pzv));
    }
    if (ph_is("try")) {
        ph_next();
        i64 sin = ph_in_try;
        ph_in_try = 1;
        ph_ls_push(1);
        i64 body = ph_block();
        ph_ls_pop();
        ph_in_try = sin;
        i64 brk = node_new(N_BREAK, line, fl);
        set_nd_val(brk, 1);
        i64 bt = nd_a(body);
        if (!bt) set_nd_a(body, brk);
        if (bt) { loop { if (!nd_next(bt)) break; bt = nd_next(bt); } set_nd_next(bt, brk); }
        i64 lp = node_new(N_LOOP, line, fl);
        set_nd_a(lp, body);
        // the catches, as one if/else chain over the pending throwable
        i64 chain = 0;
        i64 last = 0;
        loop {
            if (!ph_is("catch")) break;
            ph_next();
            ph_want("(", 1, "expected ( after catch");
            i64 cond = 0;
            loop {
                ph_accept("\\", 1);
                if (ph_tid != T_IDENT) err_at2(fl, line, "mc-php: a php class name was expected in catch", ph_tname);
                uptr cn = ph_tname;
                ph_next();
                loop { if (!ph_accept("\\", 1)) break; cn = ph_tname; ph_next(); }
                i64 one = ph_cast(TY_U8, ph_c1("php_catches", ph_strlit(cn, cstrlen(cn)), TY_I64));
                if (!cond) cond = one;
                if (cond != one) cond = ph_bin(ph_tok("||", 2), cond, one, TY_U8);
                if (!ph_accept("|", 1)) break;
            }
            uptr cv = 0;
            if (ph_at("$", 1)) {
                ph_next();
                cv = p_cat("$", ph_tname, 0, cstrlen(ph_tname));
                ph_next();
            }
            ph_want(")", 1, "expected ) after catch");
            i64 take = 0;
            if (cv) {
                ph_var_bind(cv, PT_MIXED);
                take = ph_set(ph_mangle(cv, "v_"), ph_call("php_catch_take", 0, 0, 0, 0, 0, ty_pzv));
            }
            if (!cv) take = ph_stmt_of(ph_call("php_catch_take", 0, 0, 0, 0, 0, ty_pzv));
            i64 cbody = ph_block();
            set_nd_next(take, cbody);
            i64 cb = node_new(N_BLOCK, line, fl);
            set_nd_a(cb, take);
            i64 cif = node_new(N_IF, line, fl);
            set_nd_a(cif, cond);
            set_nd_b(cif, cb);
            if (last) set_nd_c(last, cif);
            if (!chain) chain = cif;
            last = cif;
        }
        i64 fin = 0;
        if (ph_is("finally")) { ph_next(); fin = ph_block(); }
        i64 head = lp;
        i64 t = lp;
        if (chain) { set_nd_next(t, chain); t = chain; }
        if (fin) { set_nd_next(t, fin); t = fin; }
        ph_can_throw = 1;
        i64 ob = node_new(N_BLOCK, line, fl);
        set_nd_a(ob, head);
        return ob;
    }
    if (ph_is("catch") || ph_is("finally")) err_at(fl, line, "mc-php: catch without try");
    if (ph_is("class") || ph_is("interface") || ph_is("trait")) { ph_class(fl, line, 0); return ph_empty(); }
    if (ph_is("enum")) {
        // `enum` is only a declaration when a NAME follows (php 8 keeps it
        // usable as an ordinary identifier)
        ph_class(fl, line, 0);
        return ph_empty();
    }
    if (ph_is("abstract") || ph_is("final")) {
        i64 f = 0;
        i64 na = 0;
        i64 nf = 0;
        loop {
            uptr cfl = ph_tfile;
            i64 cln = ph_tline;
            if (ph_is("abstract")) { ph_next(); f = f | 1; na = na + 1;
                if (na > 1) ph_phpfatal(cfl, cln, "Multiple abstract modifiers are not allowed"); continue; }
            if (ph_is("final")) { ph_next(); f = f | 2; nf = nf + 1;
                if (nf > 1) ph_phpfatal(cfl, cln, "Multiple final modifiers are not allowed"); continue; }
            if (ph_is("readonly")) { ph_next(); continue; }
            break;
        }
        if (!ph_is("class")) err_at(fl, line, "mc-php: expected class after abstract/final");
        ph_class(fl, line, f);
        return ph_empty();
    }
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
    if (ph_is("function")) { top_add(ph_function()); return ph_empty(); }

    i64 e = ph_expr(0);
    if (!ph_at(")", 1)) ph_semi("expected ; after a php expression");
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

// foreach ($a as $v) / ($a as $k => $v) / ($a as $k => &$v), over php's
// ordered hash: the cursor is a BUCKET index, so a string key, a hole left by
// unset() and the insertion order all come out right.
//
//   $arr = <src>            (php iterates a copy, unless it is by reference)
//   $i   = php_it_next($arr, 0)
//   loop { step: $i = php_it_next($arr, $i + 1)
//          if (!($i >= 0)) break
//          $k = php_it_key($arr, $i); $v = php_it_val($arr, $i)
//          <body> }
i64 ph_foreach(uptr fl, i64 line) {
    ph_next();
    ph_want("(", 1, "expected ( after foreach");
    i64 src = ph_expr(0);
    i64 st = ph_ety;
    if (st == PT_MIXED || st == PT_OBJ) { src = ph_c1("php_zv_iter", ph_recv(src, st), ty_parr); st = PT_ARR; ph_efresh = 1; }
    if (!ph_is_arr(st)) ph_todo2(fl, line, "foreach over", ph_tyname(st));
    i64 fpre = ph_take_pend();
    if (!ph_is("as")) err_at(fl, line, "mc-php: expected as in foreach");
    ph_next();
    i64 byref = 0;
    if (ph_at("&", 1)) { ph_next(); byref = 1; }
    if (!ph_at("$", 1)) ph_todo(fl, line, "foreach without a $variable");
    ph_next();
    uptr k1 = p_cat("$", ph_tname, 0, cstrlen(ph_tname));
    ph_next();
    uptr kv = 0;
    if (ph_at("=>", 2)) {
        ph_next();
        if (ph_at("&", 1)) { ph_next(); byref = 1; }
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
    // by reference iterates the array ITSELF; by value iterates a copy
    i64 srcv = src;
    if (!byref && !ph_efresh) srcv = ph_c1("php_arr_copy", src, ty_parr);
    i64 av = ph_set(an, srcv);
    i64 aref0 = node_new(N_IDENT, line, fl);
    set_nd_name(aref0, an);
    set_nd_type(aref0, ty_parr);
    i64 iv = ph_set(iname, ph_c2("php_it_next", aref0, ph_int(0), TY_I64));
    set_nd_next(av, iv);

    i64 iref = node_new(N_IDENT, line, fl);
    set_nd_name(iref, iname);
    set_nd_type(iref, TY_I64);
    i64 cond = ph_bin(ph_tok(">=", 2), iref, ph_int(0), TY_U8);

    if (key) ph_var_bind(key, PT_MIXED);
    ph_var_bind(val, PT_MIXED);
    if (byref) ph_set_ref(val);

    i64 aref2 = node_new(N_IDENT, line, fl);
    set_nd_name(aref2, an);
    set_nd_type(aref2, ty_parr);
    i64 iref2 = node_new(N_IDENT, line, fl);
    set_nd_name(iref2, iname);
    set_nd_type(iref2, TY_I64);
    uptr getf = "php_it_val";
    if (byref) getf = "php_it_ref";
    i64 setv = ph_set(ph_mangle(val, "v_"), ph_c2(getf, aref2, iref2, ty_pzv));
    i64 head = setv;
    if (key) {
        i64 aref3 = node_new(N_IDENT, line, fl);
        set_nd_name(aref3, an);
        set_nd_type(aref3, ty_parr);
        i64 iref3 = node_new(N_IDENT, line, fl);
        set_nd_name(iref3, iname);
        set_nd_type(iref3, TY_I64);
        i64 setk = ph_set(ph_mangle(key, "v_"), ph_c2("php_it_key", aref3, iref3, ty_pzv));
        set_nd_next(setk, setv);
        head = setk;
    }
    ph_ls_push(0);
    i64 body = ph_block_or_stmt();
    ph_ls_pop();
    i64 t = head;
    loop { if (!nd_next(t)) break; t = nd_next(t); }
    set_nd_next(t, body);

    i64 aref4 = node_new(N_IDENT, line, fl);
    set_nd_name(aref4, an);
    set_nd_type(aref4, ty_parr);
    i64 iref4 = node_new(N_IDENT, line, fl);
    set_nd_name(iref4, iname);
    set_nd_type(iref4, TY_I64);
    i64 bump = ph_set(iname, ph_c2("php_it_next", aref4,
                                   ph_bin(ph_tok("+", 1), iref4, ph_int(1), TY_I64), TY_I64));

    i64 lp = ph_loop_of(cond, head, bump, line, fl);
    set_nd_next(iv, lp);
    i64 outer = node_new(N_BLOCK, line, fl);
    set_nd_a(outer, av);
    return ph_wrap(ph_prefix_stmts(fpre, outer));
}


// ---- closures --------------------------------------------------------------
// `function (...) use (...) {}` and `fn(...) => expr` lower to
// `uptr cl_N(uptr use, uptr thisp, uptr a1..a5)` plus a Closure object holding
// the function pointer, the captured array and the bound $this -- which is
// exactly what php_call_zv calls through. D6 refuses a callable spelled as a
// STRING; this is the value form, and it is kept.
i64 ph_closure(uptr fl, i64 line, i64 arrow) {
    ph_nonce = ph_nonce + 1;
    uptr cn = p_cat("cl_", php_dec(ph_nonce), 0, cstrlen(php_dec(ph_nonce)));

    // the parameters, read in the ENCLOSING scope's tokens but bound in the new one
    u8 pnames[64];
    u8 pdefs[64];
    i64 np = 0;
    ph_want("(", 1, "expected ( in a php closure");
    loop {
        if (ph_at(")", 1)) break;
        if (ph_at("...", 3)) ph_todo(fl, line, "a variadic parameter in a closure");
        if (!ph_at("$", 1)) ph_skip_type();
        if (ph_at("&", 1)) ph_todo(fl, line, "a by-reference parameter in a closure");
        if (!ph_at("$", 1)) ph_todo2(fl, line, "a php parameter", ph_tname);
        ph_next();
        uptr d = p_cat("$", ph_tname, 0, cstrlen(ph_tname));
        ph_next();
        i64 dflt = 0;
        if (ph_accept("=", 1)) { i64 dv = ph_expr(0); dflt = ph_to_mixed(dv, ph_ety); }
        if (np >= 5) ph_todo(fl, line, "more than five parameters in a closure");
        st64(pnames + np * 8, d);
        st64(pdefs + np * 8, dflt);
        np = np + 1;
        if (!ph_accept(",", 1)) break;
    }
    ph_want(")", 1, "expected ) in a php closure");

    // what it captures, and from which enclosing variable
    u8 unames[128];
    i64 nu = 0;
    if (arrow) {
        // fn() captures every enclosing variable by value
        i64 i = 0;
        loop {
            if (i >= ph_nvar) break;
            if (nu < 16) {
                uptr vn = ld64(ph_vname + i * 8);
                if (!str_eq(vn, "$this")) { st64(unames + nu * 8, vn); nu = nu + 1; }
            }
            i = i + 1;
        }
    }
    if (!arrow) {
        if (ph_is("use")) {
            ph_next();
            ph_want("(", 1, "expected ( after use");
            loop {
                if (ph_at(")", 1)) break;
                if (ph_at("&", 1)) ph_todo(fl, line, "a by-reference use in a closure");
                if (!ph_at("$", 1)) err_at(fl, line, "mc-php: a php variable was expected in use");
                ph_next();
                uptr un = p_cat("$", ph_tname, 0, cstrlen(ph_tname));
                ph_next();
                if (ph_var_find(un) < 0) ph_refuse2(fl, line, "an undefined php variable in use", un, "D4");
                if (nu >= 16) ph_todo(fl, line, "more than sixteen captured variables");
                st64(unames + nu * 8, un);
                nu = nu + 1;
                if (!ph_accept(",", 1)) break;
            }
            ph_want(")", 1, "expected ) after use");
        }
    }
    if (ph_at(":", 1)) { ph_next(); ph_skip_type(); }

    // the creation site, built while the enclosing variables are still in scope
    ph_nonce = ph_nonce + 1;
    uptr an = p_cat("phu_", php_dec(ph_nonce), 0, cstrlen(php_dec(ph_nonce)));
    ph_local(an, ty_parr);
    i64 mk = ph_set(an, ph_c1("php_arr_new", ph_int(8), ty_parr));
    i64 mt = mk;
    i64 ui = 0;
    loop {
        if (ui >= nu) break;
        uptr un2 = ld64(unames + ui * 8);
        i64 vt = ph_var_type(un2);
        i64 vr = node_new(N_IDENT, line, fl);
        set_nd_name(vr, ph_mangle(un2, "v_"));
        set_nd_type(vr, ph_mcty(vt));
        i64 ar = node_new(N_IDENT, line, fl);
        set_nd_name(ar, an);
        set_nd_type(ar, ty_parr);
        i64 st2 = ph_stmt_of(ph_c3("php_arr_set", ar, ph_to_mixed(ph_strlit(un2 + 1, cstrlen(un2 + 1)), PT_STRING),
                                   ph_to_mixed(vr, vt), TY_VOID));
        set_nd_next(mt, st2);
        mt = st2;
        ui = ui + 1;
    }
    ph_pending_stmt(mk);
    i64 thisp = ph_int(0);
    if (ph_in_method && !ph_in_static) thisp = ph_this(fl, line);
    i64 fp = node_new(N_ADDR, line, fl);
    set_nd_name(fp, cn);
    set_nd_type(fp, TY_UPTR);
    i64 aref = node_new(N_IDENT, line, fl);
    set_nd_name(aref, an);
    set_nd_type(aref, ty_parr);
    i64 made = ph_c3("php_closure_new", fp, aref, thisp, ty_pzv);

    // now the body, in its own scope
    uptr savenv = ph_scope_save();
    i64 hh = ph_hoist_head;
    i64 ht = ph_hoist_tail;
    i64 sret = ph_fn_ret;
    i64 sm = ph_in_method;
    i64 sst = ph_in_static;
    i64 stl = ph_toplevel;
    i64 sls = ph_nls;
    i64 sph = ph_pend_head;
    i64 spt = ph_pend_tail;
    ph_pend_head = 0;
    ph_pend_tail = 0;
    ph_hoist_head = 0;
    ph_hoist_tail = 0;
    ph_fn_ret = PT_MIXED;
    ph_toplevel = 0;
    ph_nls = 0;
    ph_in_method = 1;
    ph_in_static = 0;

    i64 head = param_new(TY_UPTR, "v_use");
    i64 tail = head;
    i64 tp = param_new(TY_UPTR, "v_this");
    set_nd_next(tail, tp);
    tail = tp;
    ph_var_bind_raw("$this", PT_OBJ);
    i64 pre = 0;
    i64 pret = 0;
    i64 i2 = 0;
    loop {
        if (i2 >= np) break;
        uptr d2 = ld64(pnames + i2 * 8);
        ph_var_bind_raw(d2, PT_MIXED);
        i64 pn = param_new(TY_UPTR, ph_mangle(d2, "v_"));
        set_nd_next(tail, pn);
        tail = pn;
        i64 miss = node_new(N_UNARY, line, fl);
        set_nd_op(miss, ph_tok("!", 1));
        i64 pr = node_new(N_IDENT, line, fl);
        set_nd_name(pr, ph_mangle(d2, "v_"));
        set_nd_type(pr, ty_pzv);
        set_nd_a(miss, pr);
        set_nd_type(miss, TY_U8);
        i64 dflt2 = ld64(pdefs + i2 * 8);
        if (!dflt2) dflt2 = ph_call("php_znull", 0, 0, 0, 0, 0, ty_pzv);
        i64 iff = node_new(N_IF, line, fl);
        set_nd_a(iff, miss);
        set_nd_b(iff, ph_set(ph_mangle(d2, "v_"), dflt2));
        if (pret) set_nd_next(pret, iff);
        if (!pret) pre = iff;
        pret = iff;
        i2 = i2 + 1;
    }
    // the captured variables, read out of the use array
    i64 ui2 = 0;
    loop {
        if (ui2 >= nu) break;
        uptr un3 = ld64(unames + ui2 * 8);
        ph_var_bind(un3, PT_MIXED);
        i64 ur = node_new(N_IDENT, line, fl);
        set_nd_name(ur, "v_use");
        set_nd_type(ur, ty_parr);
        i64 get = ph_c2("php_arr_zget", ur, ph_to_mixed(ph_strlit(un3 + 1, cstrlen(un3 + 1)), PT_STRING), ty_pzv);
        i64 asg = ph_set(ph_mangle(un3, "v_"), get);
        if (pret) set_nd_next(pret, asg);
        if (!pret) pre = asg;
        pret = asg;
        ui2 = ui2 + 1;
    }
    i64 body = 0;
    if (arrow) {
        ph_want("=>", 2, "expected => in a php arrow function");
        i64 rv = ph_expr(0);
        i64 r = node_new(N_RETURN, line, fl);
        set_nd_a(r, ph_to_mixed(ph_own(rv, ph_ety), ph_ety));
        body = node_new(N_BLOCK, line, fl);
        set_nd_a(body, ph_wrap(r));
    }
    if (!arrow) body = ph_block();
    if (pre) {
        i64 t = pre;
        loop { if (!nd_next(t)) break; t = nd_next(t); }
        set_nd_next(t, nd_a(body));
        set_nd_a(body, pre);
    }
    if (ph_hoist_head) {
        set_nd_next(ph_hoist_tail, nd_a(body));
        set_nd_a(body, ph_hoist_head);
    }
    i64 t2 = nd_a(body);
    if (!t2) set_nd_a(body, ph_ret_null(line, fl));
    if (t2) { loop { if (!nd_next(t2)) break; t2 = nd_next(t2); } set_nd_next(t2, ph_ret_null(line, fl)); }
    i64 f = node_new(N_FUNC, line, fl);
    set_nd_name(f, cn);
    set_nd_type(f, TY_UPTR);
    set_nd_a(f, head);
    set_nd_b(f, body);
    top_add(f);

    ph_scope_restore(savenv);
    ph_hoist_head = hh;
    ph_hoist_tail = ht;
    ph_fn_ret = sret;
    ph_in_method = sm;
    ph_in_static = sst;
    ph_toplevel = stl;
    ph_nls = sls;
    ph_pend_head = sph;
    ph_pend_tail = spt;
    ph_ety = PT_MIXED;
    return made;
}

// ---- classes, interfaces, traits and enums --------------------------------
// The class entry is built at run time by statements this compiler emits in
// front of main, and every member is reached BY NAME through the registry.
// That is not reflection (D6): the name is a literal in the source and no
// program can enumerate the tables.
//
// A method is `uptr m_<Class>_<name>(uptr this, uptr a1..)`: every argument is
// a zval and so is the result, which is what lets php_mcall dispatch through
// one function pointer. An argument that was not passed arrives as 0, which is
// how a default parameter and ArgumentCountError are both expressible.
i64 ph_cnew_head;
i64 ph_cnew_tail;
i64 ph_cfill_head;
i64 ph_cfill_tail;
uptr ph_cur_ceg;               // the mc global holding its class entry
i64  ph_in_method;             // 1 while a method body is being parsed
i64  ph_in_static;

void ph_cnew(i64 s) {
    if (ph_cnew_tail) set_nd_next(ph_cnew_tail, s);
    if (!ph_cnew_tail) ph_cnew_head = s;
    ph_cnew_tail = s;
}

void ph_cfill(i64 s) {
    if (ph_cfill_tail) set_nd_next(ph_cfill_tail, s);
    if (!ph_cfill_tail) ph_cfill_head = s;
    ph_cfill_tail = s;
}

i64 ph_stmt_of(i64 c) {
    i64 s = node_new(N_EXPRSTMT, ph_tline, ph_tfile);
    set_nd_a(s, c);
    return s;
}

// the class entry of the code doing an access, for the visibility check
// the class entry lives in a one-slot global, like a string literal's cache:
// mc's N_GLOBAL with a size is storage, and the value is read with ld64.
i64 ph_cegvar(uptr g) {
    i64 n = node_new(N_IDENT, ph_tline, ph_tfile);
    set_nd_name(n, g);
    set_nd_type(n, TY_UPTR);
    return n;
}

i64 ph_ceref(uptr g) { return ph_c1("ld64", ph_cegvar(g), TY_UPTR); }

i64 ph_scope() {
    if (!ph_cur_ceg) return ph_int(0);
    return ph_ceref(ph_cur_ceg);
}

// a class entry looked up by its literal name
i64 ph_ce_of(uptr name, uptr fl, i64 line) {
    if (str_eq(name, "self") || str_eq(name, "static")) {
        if (!ph_cur_ceg) err_at(fl, line, "mc-php: self:: outside a class");
        return ph_ceref(ph_cur_ceg);
    }
    if (str_eq(name, "parent")) {
        if (!ph_cur_ceg) err_at(fl, line, "mc-php: parent:: outside a class");
        return ph_c1("php_ce_parent", ph_ceref(ph_cur_ceg), TY_UPTR);
    }
    return ph_c1("php_ce_byname", ph_strlit(name, cstrlen(name)), TY_UPTR);
}

// `this` inside a method
i64 ph_this(uptr fl, i64 line) {
    if (!ph_in_method) err_at(fl, line, "mc-php: $this outside a method");
    i64 n = node_new(N_IDENT, line, fl);
    set_nd_name(n, "v_this");
    set_nd_type(n, TY_UPTR);
    return n;
}

// the receiver of -> as a zval, whatever it was
i64 ph_recv(i64 v, i64 t) {
    if (t == PT_OBJ) return ph_c1("php_zobj", v, ty_pzv);
    return ph_to_mixed(v, t);
}

// the call arguments of a method: zvals, at most six (callp takes seven and
// the receiver is the first)
uptr ph_margs(uptr pn, uptr fl, i64 line) {
    u8 nb[8];
    uptr av = ph_read_args(6, fl, line, nb);
    i64 n = ld64(nb);
    if (n > 6) ph_todo(fl, line, "more than six arguments to a method");
    uptr out = xalloc(6 * 8 + 8);
    i64 i = 0;
    loop {
        if (i >= 6) break;
        i64 a = ph_int(0);
        if (i < n) a = ph_to_mixed(ph_a(av, i), ph_aty(av, i));
        st64(out + i * 8, a);
        i = i + 1;
    }
    st64(pn, n);
    return out;
}

i64 ph_calln(uptr fn, uptr args, i64 n, i64 ty) {
    ph_can_throw = 1;
    i64 c = node_new(N_CALL, ph_tline, ph_tfile);
    set_nd_name(c, fn);
    i64 head = 0;
    i64 tail = 0;
    i64 i = 0;
    loop {
        if (i >= n) break;
        i64 a = ld64(args + i * 8);
        if (tail) set_nd_next(tail, a);
        if (!tail) head = a;
        tail = a;
        i = i + 1;
    }
    set_nd_a(c, head);
    set_nd_type(c, ty);
    return c;
}

// $recv->name(args)
i64 ph_mcall_node(i64 recv, uptr name, uptr fl, i64 line) {
    u8 nb[8];
    uptr ma = ph_margs(nb, fl, line);
    u8 all[80];
    st64(all, recv);
    st64(all + 8, ph_strlit(name, cstrlen(name)));
    st64(all + 16, ph_scope());
    st64(all + 24, ph_int(ld64(nb)));
    i64 i = 0;
    loop { if (i >= 6) break; st64(all + 32 + i * 8, ld64(ma + i * 8)); i = i + 1; }
    ph_ety = PT_MIXED;
    return ph_calln("php_zv_mcall", all, 10, ty_pzv);
}

// Cls::name(args), with `this` forwarded when there is one (parent::__construct)
i64 ph_scall_node(i64 ce, uptr name, uptr fl, i64 line) {
    u8 nb[8];
    uptr ma = ph_margs(nb, fl, line);
    i64 thisp = ph_int(0);
    if (ph_in_method && !ph_in_static) thisp = ph_this(fl, line);
    u8 all[88];
    st64(all, ce);
    st64(all + 8, ph_strlit(name, cstrlen(name)));
    st64(all + 16, thisp);
    st64(all + 24, ph_scope());
    st64(all + 32, ph_int(ld64(nb)));
    i64 i = 0;
    loop { if (i >= 6) break; st64(all + 40 + i * 8, ld64(ma + i * 8)); i = i + 1; }
    ph_ety = PT_MIXED;
    return ph_calln("php_scall", all, 11, ty_pzv);
}

// ---- the member list -------------------------------------------------------
i64 ph_visword() {
    if (ph_is("public"))    { ph_next(); return V_PUBLIC; }
    if (ph_is("protected")) { ph_next(); return V_PROTECTED; }
    if (ph_is("private"))   { ph_next(); return V_PRIVATE; }
    return -1;
}

// a php type in a member position, accepted and discarded: D4 types the
// variable by its value, and a property is a zval whatever it declares
void ph_skip_type() {
    ph_accept("?", 1);
    loop {
        if (ph_tid != T_IDENT && ph_tid != T_STR) break;
        if (ph_at("$", 1)) break;
        ph_next();
        if (ph_accept("|", 1)) { ph_accept("?", 1); continue; }
        if (ph_accept("&", 1)) { ph_accept("?", 1); continue; }
        if (ph_accept("\\", 1)) continue;
        break;
    }
}

i64 ph_is_typeword() {
    if (ph_at("?", 1)) return 1;
    if (ph_tid != T_IDENT) return 0;
    if (ph_at("$", 1)) return 0;
    return 1;
}

void ph_method_body(uptr mcname, uptr cname, uptr ceg, i64 vis, i64 stat, i64 line, uptr fl, i64 abstract);

// ---- the declaration -------------------------------------------------------
void ph_class(uptr fl, i64 line, i64 flags) {
    i64 kind = 0;                                    // 0 class 1 interface 2 trait 3 enum
    if (ph_is("interface")) kind = 1;
    if (ph_is("trait")) kind = 2;
    if (ph_is("enum")) kind = 3;
    ph_next();
    if (ph_tid != T_IDENT) err_at2(fl, line, "mc-php: a php class needs a name", ph_tname);
    uptr cname = ph_tname;
    ph_next();
    if (kind == 3) { if (ph_accept(":", 1)) ph_skip_type(); }

    ph_nonce = ph_nonce + 1;
    uptr ceg = p_cat("ce_", cname, 0, cstrlen(cname));
    ceg = p_cat(ceg, php_dec(ph_nonce), 0, cstrlen(php_dec(ph_nonce)));
    i64 g = node_new(N_GLOBAL, line, fl);
    set_nd_name(g, ceg);
    set_nd_type(g, TY_UPTR);
    set_nd_val(g, 1);
    set_nd_a(g, 0);
    top_add(g);
    ph_cnew(ph_stmt_of(ph_c2("st64", ph_cegvar(ceg), ph_c1("php_ce_new", ph_strlit(cname, cstrlen(cname)), TY_UPTR), TY_VOID)));

    if (kind == 1) flags = flags | 4;
    if (kind == 3) flags = flags | 8;
    if (flags) ph_cfill(ph_stmt_of(ph_c2("php_ce_flag", ph_ceref(ceg), ph_int(flags), TY_VOID)));

    if (ph_is("extends")) {
        ph_next();
        loop {
            ph_accept("\\", 1);
            if (ph_tid != T_IDENT) err_at(fl, line, "mc-php: a php class name was expected after extends");
            uptr pn = ph_tname;
            ph_next();
            // an interface `extends` several: they are all interfaces here
            if (kind == 1) ph_cfill(ph_stmt_of(ph_c2("php_ce_iface", ph_ceref(ceg), ph_strlit(pn, cstrlen(pn)), TY_VOID)));
            if (kind != 1) ph_cfill(ph_stmt_of(ph_c2("php_ce_extend", ph_ceref(ceg), ph_strlit(pn, cstrlen(pn)), TY_VOID)));
            if (!ph_accept(",", 1)) break;
        }
    }
    if (ph_is("implements")) {
        ph_next();
        loop {
            ph_accept("\\", 1);
            if (ph_tid != T_IDENT) err_at(fl, line, "mc-php: a php interface name was expected");
            uptr inm = ph_tname;
            ph_next();
            ph_cfill(ph_stmt_of(ph_c2("php_ce_iface", ph_ceref(ceg), ph_strlit(inm, cstrlen(inm)), TY_VOID)));
            if (!ph_accept(",", 1)) break;
        }
    }

    uptr savec = ph_cur_cls;
    uptr saveg = ph_cur_ceg;
    ph_cur_cls = cname;
    ph_cur_ceg = ceg;

    ph_want("{", 1, "expected { in a php class");
    loop {
        if (ph_at("}", 1)) break;
        if (ph_tid == T_EOF) err_at(fl, line, "mc-php: unterminated php class");
        i64 mline = ph_tline;
        uptr mfl = ph_tfile;
        i64 mflags = 0;
        i64 vis = -1;
        i64 stat = 0;

        if (ph_is("use")) {
            ph_next();
            loop {
                ph_accept("\\", 1);
                uptr tn = ph_tname;
                ph_next();
                ph_cfill(ph_stmt_of(ph_c2("php_ce_use", ph_ceref(ceg), ph_strlit(tn, cstrlen(tn)), TY_VOID)));
                if (!ph_accept(",", 1)) break;
            }
            if (ph_at("{", 1)) { loop { if (ph_at("}", 1)) break; if (ph_tid == T_EOF) break; ph_next(); } ph_next(); }
            if (!ph_at("}", 1)) ph_accept(";", 1);
            continue;
        }
        if (kind == 3 && ph_is("case")) {
            ph_next();
            uptr en = ph_tname;
            ph_next();
            i64 ev = ph_call("php_znull", 0, 0, 0, 0, 0, ty_pzv);
            if (ph_accept("=", 1)) { i64 x = ph_expr(0); ev = ph_to_mixed(x, ph_ety); }
            ph_semi("expected ; after an enum case");
            ph_cfill(ph_stmt_of(ph_c3("php_enum_case", ph_ceref(ceg), ph_strlit(en, cstrlen(en)), ev, ty_pzv)));
            continue;
        }
        i64 nvis = 0;
        i64 nstat = 0;
        i64 nabs = 0;
        i64 nfin = 0;
        loop {
            i64 mfl2 = ph_tfile;
            i64 mln2 = ph_tline;
            if (ph_is("abstract")) { ph_next(); mflags = mflags | 1; nabs = nabs + 1;
                if (nabs > 1) ph_phpfatal(mfl2, mln2, "Multiple abstract modifiers are not allowed"); continue; }
            if (ph_is("final"))    { ph_next(); mflags = mflags | 2; nfin = nfin + 1;
                if (nfin > 1) ph_phpfatal(mfl2, mln2, "Multiple final modifiers are not allowed"); continue; }
            if (ph_is("readonly")) { ph_next(); continue; }
            if (ph_is("static"))   { ph_next(); stat = 1; nstat = nstat + 1;
                if (nstat > 1) ph_phpfatal(mfl2, mln2, "Multiple static modifiers are not allowed"); continue; }
            i64 v = ph_visword();
            if (v >= 0) {
                vis = v;
                nvis = nvis + 1;
                if (nvis > 1) ph_phpfatal(mfl2, mln2, "Multiple access type modifiers are not allowed");
                continue;
            }
            break;
        }
        if (vis < 0) vis = V_PUBLIC;

        if (ph_is("const")) {
            ph_next();
            if (!ph_at("=", 1) && ph_is_typeword()) {
                // `const TYPE NAME = ...`, but `const NAME = ...` is the common shape
                uptr first = ph_tname;
                i64 save = ph_tid;
                ph_next();
                if (ph_at("=", 1)) {
                    ph_want("=", 1, "expected = in a class constant");
                    i64 cv = ph_expr(0);
                    ph_cfill(ph_stmt_of(ph_c3("php_ce_const", ph_ceref(ceg), ph_strlit(first, cstrlen(first)),
                                              ph_to_mixed(cv, ph_ety), TY_VOID)));
                    loop {
                        if (!ph_accept(",", 1)) break;
                        uptr n2 = ph_tname;
                        ph_next();
                        ph_want("=", 1, "expected = in a class constant");
                        i64 cv2 = ph_expr(0);
                        ph_cfill(ph_stmt_of(ph_c3("php_ce_const", ph_ceref(ceg), ph_strlit(n2, cstrlen(n2)),
                                                  ph_to_mixed(cv2, ph_ety), TY_VOID)));
                    }
                    ph_semi("expected ; after a class constant");
                    continue;
                }
            }
            loop {
                uptr n3 = ph_tname;
                ph_next();
                ph_want("=", 1, "expected = in a class constant");
                i64 cv3 = ph_expr(0);
                ph_cfill(ph_stmt_of(ph_c3("php_ce_const", ph_ceref(ceg), ph_strlit(n3, cstrlen(n3)),
                                          ph_to_mixed(cv3, ph_ety), TY_VOID)));
                if (!ph_accept(",", 1)) break;
            }
            ph_semi("expected ; after a class constant");
            continue;
        }

        if (ph_is("function")) {
            ph_next();
            ph_accept("&", 1);
            if (ph_tid != T_IDENT) err_at2(mfl, mline, "mc-php: a php method needs a name", ph_tname);
            uptr mname = ph_tname;
            ph_next();
            uptr mcname = p_cat("m_", cname, 0, cstrlen(cname));
            mcname = p_cat(mcname, "_", 0, 1);
            mcname = p_cat(mcname, mname, 0, cstrlen(mname));
            mcname = p_cat(mcname, php_dec(ph_nonce), 0, cstrlen(php_dec(ph_nonce)));
            i64 isabs = 0;
            if (mflags & 1) isabs = 1;
            if (kind == 1) isabs = 1;
            i64 saves = ph_in_static;
            ph_in_static = stat;
            uptr savefn = ph_cur_fn;
            ph_cur_fn = mname;
            ph_method_body(mcname, cname, ceg, vis, stat, mline, mfl, isabs);
            ph_cur_fn = savefn;
            ph_in_static = saves;
            if (!isabs) {
                // mc's N_ADDR carries the NAME itself (res_addr reads
                // nd_name of the node), not a child N_IDENT
                i64 fp = node_new(N_ADDR, mline, mfl);
                set_nd_name(fp, mcname);
                set_nd_type(fp, TY_UPTR);
                ph_cfill(ph_stmt_of(ph_c4("php_ce_method", ph_ceref(ceg), ph_strlit(mname, cstrlen(mname)),
                                          fp, ph_int(vis), TY_VOID)));
            }
            continue;
        }

        // a property, with or without a declared type
        if (!ph_at("$", 1)) ph_skip_type();
        if (!ph_at("$", 1)) ph_todo2(mfl, mline, "a php class member", ph_tname);
        loop {
            ph_next();
            if (ph_tid != T_IDENT) err_at(mfl, mline, "mc-php: a php property needs a name");
            uptr pname = ph_tname;
            ph_next();
            i64 def = ph_call("php_znull", 0, 0, 0, 0, 0, ty_pzv);
            if (ph_accept("=", 1)) { i64 dv = ph_expr(0); def = ph_to_mixed(dv, ph_ety); }
            uptr fn = "php_ce_prop";
            if (stat) fn = "php_ce_sprop";
            ph_cfill(ph_stmt_of(ph_c4(fn, ph_ceref(ceg), ph_strlit(pname, cstrlen(pname)), def, ph_int(vis), TY_VOID)));
            if (!ph_accept(",", 1)) break;
        }
        ph_semi("expected ; after a php property");
    }
    ph_next();
    ph_cur_cls = savec;
    ph_cur_ceg = saveg;
}

// ---- a method body ---------------------------------------------------------
// Uniform shape so php_mcall can dispatch through one pointer: every
// parameter is a zval, the result is a zval, and an argument that was not
// passed arrives as 0 -- which is what makes a default value and
// ArgumentCountError both expressible without the caller knowing the arity.
void ph_method_body(uptr mcname, uptr cname, uptr ceg, i64 vis, i64 stat, i64 line, uptr fl, i64 abstract) {
    uptr savenv = ph_scope_save();
    i64 hh = ph_hoist_head;
    i64 ht = ph_hoist_tail;
    i64 sret = ph_fn_ret;
    i64 sm = ph_in_method;
    ph_hoist_head = 0;
    ph_hoist_tail = 0;
    ph_fn_ret = PT_MIXED;
    ph_in_method = 1;
    i64 stl = ph_toplevel;
    ph_toplevel = 0;
    i64 sls = ph_nls;
    ph_nls = 0;

    i64 head = 0;
    i64 tail = 0;
    if (!stat) {
        i64 tp = param_new(TY_UPTR, "v_this");
        head = tp;
        tail = tp;
        ph_var_bind_raw("$this", PT_OBJ);
    }
    ph_want("(", 1, "expected ( in a php method");
    i64 pre = 0;
    i64 pret = 0;
    i64 np = 0;
    loop {
        if (ph_at(")", 1)) break;
        i64 pvis = -1;
        loop {
            i64 v = ph_visword();
            if (v >= 0) { pvis = v; continue; }
            if (ph_is("readonly")) { ph_next(); if (pvis < 0) pvis = V_PUBLIC; continue; }
            break;
        }
        if (ph_at("...", 3)) ph_todo(fl, line, "a variadic parameter ...$args");
        i64 byref = 0;
        if (!ph_at("$", 1)) ph_skip_type();
        if (ph_at("&", 1)) { ph_next(); byref = 1; }
        if (byref) ph_todo(fl, line, "a by-reference parameter in a method");
        if (!ph_at("$", 1)) ph_todo2(fl, line, "a php parameter", ph_tname);
        ph_next();
        uptr d = p_cat("$", ph_tname, 0, cstrlen(ph_tname));
        ph_next();
        if (np >= 6) ph_todo(fl, line, "more than six parameters in a method");
        i64 dflt = 0;
        if (ph_accept("=", 1)) { i64 dv = ph_expr(0); dflt = ph_to_mixed(dv, ph_ety); }
        ph_var_bind_raw(d, PT_MIXED);
        i64 pn = param_new(TY_UPTR, ph_mangle(d, "v_"));
        if (tail) set_nd_next(tail, pn);
        if (!tail) head = pn;
        tail = pn;
        // the prologue: a missing argument is 0
        i64 miss = node_new(N_UNARY, line, fl);
        set_nd_op(miss, ph_tok("!", 1));
        i64 pr = node_new(N_IDENT, line, fl);
        set_nd_name(pr, ph_mangle(d, "v_"));
        set_nd_type(pr, ty_pzv);
        set_nd_a(miss, pr);
        set_nd_type(miss, TY_U8);
        i64 fill = 0;
        if (dflt) fill = ph_set(ph_mangle(d, "v_"), dflt);
        if (!dflt) fill = ph_stmt_of(ph_c2("php_argcount", ph_strlit(cname, cstrlen(cname)),
                                           ph_strlit(mcname, cstrlen(mcname)), TY_VOID));
        i64 iff = node_new(N_IF, line, fl);
        set_nd_a(iff, miss);
        set_nd_b(iff, fill);
        if (pret) set_nd_next(pret, iff);
        if (!pret) pre = iff;
        pret = iff;
        // constructor promotion
        if (pvis >= 0) {
            uptr bare = d + 1;
            ph_cfill(ph_stmt_of(ph_c4("php_ce_prop", ph_ceref(ceg), ph_strlit(bare, cstrlen(bare)),
                                      ph_call("php_znull", 0, 0, 0, 0, 0, ty_pzv), ph_int(pvis), TY_VOID)));
            i64 pr2 = node_new(N_IDENT, line, fl);
            set_nd_name(pr2, ph_mangle(d, "v_"));
            set_nd_type(pr2, ty_pzv);
            i64 asg = ph_stmt_of(ph_c4("php_obj_set", ph_this(fl, line), ph_strlit(bare, cstrlen(bare)),
                                       pr2, ph_scope(), TY_VOID));
            set_nd_next(pret, asg);
            pret = asg;
        }
        np = np + 1;
        if (!ph_accept(",", 1)) break;
    }
    ph_want(")", 1, "expected ) in a php method");
    if (ph_at(":", 1)) { ph_next(); ph_skip_type(); }
    if (abstract) {
        ph_accept(";", 1);
        if (ph_at("{", 1)) ph_block();
        ph_scope_restore(savenv);
        ph_hoist_head = hh;
        ph_hoist_tail = ht;
        ph_fn_ret = sret;
        ph_in_method = sm;
        return;
    }
    p_set_decl_name(mcname);
    i64 body = ph_block();
    if (pre) {
        i64 t = pre;
        loop { if (!nd_next(t)) break; t = nd_next(t); }
        set_nd_next(t, nd_a(body));
        set_nd_a(body, pre);
    }
    if (ph_hoist_head) {
        set_nd_next(ph_hoist_tail, nd_a(body));
        set_nd_a(body, ph_hoist_head);
    }
    // a php function with no explicit return answers null
    i64 t2 = nd_a(body);
    if (!t2) { set_nd_a(body, ph_ret_null(line, fl)); }
    if (t2) {
        loop { if (!nd_next(t2)) break; t2 = nd_next(t2); }
        set_nd_next(t2, ph_ret_null(line, fl));
    }
    i64 f = node_new(N_FUNC, line, fl);
    set_nd_name(f, mcname);
    set_nd_type(f, TY_UPTR);
    set_nd_a(f, head);
    set_nd_b(f, body);
    top_add(f);
    ph_scope_restore(savenv);
    ph_hoist_head = hh;
    ph_hoist_tail = ht;
    ph_fn_ret = sret;
    ph_in_method = sm;
    ph_toplevel = stl;
    ph_nls = sls;
}


i64 ph_ret_null(i64 line, uptr fl) {
    i64 r = node_new(N_RETURN, line, fl);
    set_nd_a(r, ph_call("php_znull", 0, 0, 0, 0, 0, ty_pzv));
    return r;
}

// $d->a->b = v / $d->m() / $d->a[k] = v, as a STATEMENT. The read of an
// intermediate step is materialised as it is walked; only the last step can
// be an lvalue.
i64 ph_obj_stmt(uptr d, uptr fl, i64 line, i64 semi) {
    i64 t = ph_var_type(d);
    i64 cur = node_new(N_IDENT, line, fl);
    set_nd_name(cur, ph_mangle(d, "v_"));
    set_nd_type(cur, ph_mcty(t));
    loop {
        if (!ph_at("->", 2) && !ph_at("?->", 3)) break;
        ph_next();
        if (ph_at("$", 1) || ph_at("{", 1)) ph_refuse(fl, line, "a property name that is not a literal", "D6");
        if (ph_tid != T_IDENT) err_at2(fl, line, "mc-php: a php property needs a name", ph_tname);
        uptr pname = ph_tname;
        ph_next();
        i64 recv = ph_recv(cur, t);
        if (ph_at("(", 1)) {
            cur = ph_mcall_node(recv, pname, fl, line);
            t = PT_MIXED;
            continue;
        }
        if (ph_at("->", 2) || ph_at("?->", 3)) {
            cur = ph_c3("php_zv_pget", recv, ph_strlit(pname, cstrlen(pname)), ph_scope(), ty_pzv);
            t = PT_MIXED;
            continue;
        }
        if (ph_at("[", 1)) {
            // $o->p[k]... : the property is used as an array in place
            i64 arr = ph_c3("php_zv_parr", recv, ph_strlit(pname, cstrlen(pname)), ph_scope(), ty_parr);
            loop {
                ph_want("[", 1, "expected [");
                i64 k = 0;
                if (!ph_at("]", 1)) k = ph_zkey(ph_expr(0), ph_ety);
                ph_want("]", 1, "expected ]");
                if (!ph_at("[", 1)) {
                    ph_want("=", 1, "expected = after a php property index");
                    i64 v = ph_expr(0);
                    i64 vt = ph_ety;
                    if (semi) ph_semi("expected ; after a php assignment");
                    return ph_expr_stmt_of(ph_store(arr, k, ph_to_mixed(ph_own(v, vt), vt)));
                }
                if (k)  arr = ph_c2("php_arr_dim", arr, k, ty_parr);
                if (!k) arr = ph_c1("php_arr_dimn", arr, ty_parr);
            }
        }
        // the last step: an assignment, a compound assignment or a read
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
        if (ph_at("=", 1) || op || incdec) {
            i64 rt = ph_temp(recv, ty_pzv, "pho_");
            // every use of the property name needs its OWN node: nd_next is
            // the argument link, so one node in two argument lists is a CYCLE
            i64 v = 0;
            if (incdec) {
                ph_next();
                uptr f = "php_zv_inc";
                if (incdec < 0) f = "php_zv_dec";
                v = ph_c1(f, ph_c3("php_zv_pget", ph_tref(rt), ph_strlit(pname, cstrlen(pname)), ph_scope(), ty_pzv), ty_pzv);
            }
            if (!incdec && op) {
                ph_next();
                i64 r = ph_expr(0);
                i64 rrt = ph_ety;
                i64 old = ph_c3("php_zv_pget", ph_tref(rt), ph_strlit(pname, cstrlen(pname)), ph_scope(), ty_pzv);
                if (op == ph_tok(".", 1)) v = ph_c2("php_zv_concat", old, ph_to_mixed(r, rrt), ty_pzv);
                if (op != ph_tok(".", 1)) v = ph_arith_zv(op, old, PT_MIXED, r, rrt);
            }
            if (!incdec && !op) {
                ph_next();
                if (ph_at("&", 1)) ph_todo(fl, line, "an assignment by reference");
                i64 r2 = ph_expr(0);
                v = ph_to_mixed(ph_own(r2, ph_ety), ph_ety);
            }
            if (semi) ph_semi("expected ; after a php assignment");
            return ph_expr_stmt_of(ph_c4("php_zv_pset", ph_tref(rt), ph_strlit(pname, cstrlen(pname)), v, ph_scope(), TY_VOID));
        }
        cur = ph_c3("php_zv_pget", recv, ph_strlit(pname, cstrlen(pname)), ph_scope(), ty_pzv);
        t = PT_MIXED;
    }
    if (semi) ph_semi("expected ; after a php expression");
    return ph_expr_stmt_of(cur);
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
    st64(ph_fret + fi * 8, PT_MIXED);
    st64(ph_fnp + fi * 8, 0);
    st64(ph_fvar + fi * 8, 0);

    ph_want("(", 1, "expected ( in a php function");
    uptr save = ph_scope_save();
    i64 head = 0;
    i64 tail = 0;
    i64 np = 0;
    i64 pre = 0;
    i64 pret = 0;
    loop {
        if (ph_at(")", 1)) break;
        i64 variadic = 0;
        if (ph_at("...", 3)) { ph_next(); variadic = 1; }
        if (ph_at("&", 1)) ph_todo(fl, line, "a by-reference parameter in a typed function");
        i64 pt = -1;
        if (!ph_at("$", 1)) pt = ph_type_word(0);
        if (!ph_at("$", 1)) ph_todo2(fl, line, "a php parameter", ph_tname);
        ph_next();
        uptr d = p_cat("$", ph_tname, 0, cstrlen(ph_tname));
        ph_next();
        i64 dflt = 0;
        if (ph_accept("=", 1)) { i64 dv = ph_expr(0); dflt = ph_to_mixed(dv, ph_ety); }
        // a parameter with no declared type IS mixed (D4 (c)); so is one with
        // a default, because "not passed" has to be expressible
        if (pt < 0 || dflt) pt = PT_MIXED;
        if (variadic) pt = PT_ARR;
        if (np >= PH_MAXP) ph_todo(fl, line, "more than 12 parameters");
        ph_var_bind_raw(d, pt);
        st64(ph_fpt + (fi * PH_MAXP + np) * 8, pt);
        st64(ph_fpd + (fi * PH_MAXP + np) * 8, dflt);
        np = np + 1;
        i64 pn = param_new(ph_mcty(pt), ph_mangle(d, "v_"));
        if (tail) set_nd_next(tail, pn);
        if (!tail) head = pn;
        tail = pn;
        if (pt == PT_MIXED) {
            // a zval parameter that was not passed arrives as 0
            i64 miss = node_new(N_UNARY, line, fl);
            set_nd_op(miss, ph_tok("!", 1));
            i64 pr = node_new(N_IDENT, line, fl);
            set_nd_name(pr, ph_mangle(d, "v_"));
            set_nd_type(pr, ty_pzv);
            set_nd_a(miss, pr);
            set_nd_type(miss, TY_U8);
            i64 fill = 0;
            if (dflt) fill = ph_set(ph_mangle(d, "v_"), dflt);
            if (!dflt) fill = ph_stmt_of(ph_c2("php_argcount", ph_strlit("", 0),
                                               ph_strlit(name, cstrlen(name)), TY_VOID));
            i64 iff = node_new(N_IF, line, fl);
            set_nd_a(iff, miss);
            set_nd_b(iff, fill);
            if (pret) set_nd_next(pret, iff);
            if (!pret) pre = iff;
            pret = iff;
        }
        if (variadic) { st64(ph_fvar + fi * 8, 1); break; }
        if (!ph_accept(",", 1)) break;
    }
    ph_want(")", 1, "expected ) in a php function");
    st64(ph_fnp + fi * 8, np);
    i64 rt = PT_MIXED;
    if (ph_at(":", 1)) { ph_next(); rt = ph_type_word(1); }
    st64(ph_fret + fi * 8, rt);
    uptr mn = ph_mangle(name, "f_");
    p_set_decl_name(mn);
    uptr savefn = ph_cur_fn;
    ph_cur_fn = name;
    i64 sret = ph_fn_ret;
    ph_fn_ret = rt;
    i64 stl2 = ph_toplevel;
    ph_toplevel = 0;
    i64 sls2 = ph_nls;
    ph_nls = 0;
    i64 hh = ph_hoist_head;
    i64 ht = ph_hoist_tail;
    ph_hoist_head = 0;
    ph_hoist_tail = 0;
    i64 body = ph_block();
    if (pre) {
        i64 t = pre;
        loop { if (!nd_next(t)) break; t = nd_next(t); }
        set_nd_next(t, nd_a(body));
        set_nd_a(body, pre);
    }
    if (ph_hoist_head) {
        set_nd_next(ph_hoist_tail, nd_a(body));
        set_nd_a(body, ph_hoist_head);
    }
    // a php function that falls off the end answers null
    if (rt == PT_MIXED) {
        i64 t2 = nd_a(body);
        if (!t2) set_nd_a(body, ph_ret_null(line, fl));
        if (t2) { loop { if (!nd_next(t2)) break; t2 = nd_next(t2); } set_nd_next(t2, ph_ret_null(line, fl)); }
    }
    ph_hoist_head = hh;
    ph_hoist_tail = ht;
    ph_scope_restore(save);
    ph_cur_fn = savefn;
    ph_fn_ret = sret;
    ph_toplevel = stl2;
    ph_nls = sls2;
    i64 f = node_new(N_FUNC, line, fl);
    set_nd_name(f, mn);
    set_nd_type(f, ph_mcty(rt));
    set_nd_a(f, head);
    set_nd_b(f, body);
    return f;
}

void ph_lib_init() {
    ph_lib("str_rot13", "php_f_str_rot13", 1, 1, PT_STRING);
    ph_lib("quotemeta", "php_f_quotemeta", 1, 1, PT_STRING);
    ph_lib("strpbrk", "php_f_strpbrk", 2, 2, PT_MIXED);
    ph_lib("substr_compare", "php_f_substr_compare", 3, 5, PT_INT);
    ph_lib("levenshtein", "php_f_levenshtein", 2, 2, PT_INT);
    ph_lib("similar_text", "php_f_similar_text", 2, 3, PT_INT);
    ph_lib("soundex", "php_f_soundex", 1, 1, PT_STRING);
    ph_lib("count_chars", "php_f_count_chars", 1, 2, PT_MIXED);
    ph_lib("str_word_count", "php_f_str_word_count", 1, 3, PT_ARR);
    ph_lib("basename", "php_f_basename", 1, 2, PT_STRING);
    ph_lib("dirname", "php_f_dirname", 1, 2, PT_STRING);
    ph_lib("crc32", "php_f_crc32", 1, 1, PT_INT);
    ph_lib("urlencode", "php_f_urlencode0", 1, 1, PT_STRING);
    ph_lib("rawurlencode", "php_f_rawurlencode", 1, 1, PT_STRING);
    ph_lib("urldecode", "php_f_urldecode", 1, 1, PT_STRING);
    ph_lib("rawurldecode", "php_f_urldecode", 1, 1, PT_STRING);
    ph_lib("htmlspecialchars_decode", "php_f_hsd2", 1, 2, PT_STRING);
    ph_lib("html_entity_decode", "php_f_htmlspecialchars_decode", 1, 3, PT_STRING);
    ph_lib("str_increment", "php_f_str_increment", 1, 1, PT_STRING);
    ph_lib("array_is_list", "php_f_array_is_list", 1, 1, PT_BOOL);
    ph_lib("array_push", "php_f_array_push", 2, 4, PT_INT);
    ph_lib("array_column", "php_f_array_column", 2, 3, PT_ARR);
    ph_lib("array_diff", "php_f_array_diff", 2, 2, PT_ARR);
    ph_lib("array_diff_key", "php_f_array_diff", 2, 2, PT_ARR);
    ph_lib("array_intersect", "php_f_array_intersect", 2, 2, PT_ARR);
    ph_lib("array_pad", "php_f_array_pad", 3, 3, PT_ARR);
    ph_lib("array_chunk", "php_f_array_chunk", 2, 3, PT_ARR);
    ph_lib("current", "php_f_current", 1, 1, PT_MIXED);
    ph_lib("reset", "php_f_current", 1, 1, PT_MIXED);
    ph_lib("end", "php_f_end", 1, 1, PT_MIXED);
    ph_lib("key", "php_f_key", 1, 1, PT_MIXED);
    ph_lib("md5", "php_f_md5", 1, 2, PT_STRING);
    ph_lib("sha1", "php_f_sha1", 1, 2, PT_STRING);
    ph_lib("ucfirst", "php_f_ucfirst", 1, 1, PT_STRING);
    ph_lib("iterator_to_array", "php_f_iterator", 1, 2, PT_MIXED);
    ph_lib("lcg_value", "php_f_pi", 0, 0, PT_FLOAT);
    ph_lib("microtime", "php_f_noop", 0, 1, PT_INT);
    ph_lib("time", "php_f_zero", 0, 0, PT_INT);
    ph_lib("php_sapi_name", "php_f_sapi", 0, 0, PT_STRING);
    ph_lib("phpversion", "php_f_phpversion", 0, 1, PT_STRING);
    ph_lib("zend_version", "php_f_ver0", 0, 0, PT_STRING);
    ph_lib("func_num_args", "php_f_zero", 0, 0, PT_INT);
    ph_lib("trigger_error", "php_f_trigger", 1, 2, PT_BOOL);
    ph_lib("set_time_limit", "php_f_noop", 0, 1, PT_BOOL);
    ph_lib("date_default_timezone_set", "php_f_noop", 0, 1, PT_BOOL);
    ph_lib("assert_options", "php_f_null2", 0, 2, PT_MIXED);
    ph_lib("flush", "php_f_zero", 0, 0, PT_VOID);
    ph_lib("constant", "php_f_constant", 1, 1, PT_MIXED);
    ph_lib("str_contains", "php_f_contains", 2, 2, PT_BOOL);
    ph_lib("ctype_digit", "php_f_ctype", 1, 1, PT_BOOL);
    ph_lib("ctype_alpha", "php_f_ctype_a", 1, 1, PT_BOOL);
    ph_lib("ctype_alnum", "php_f_ctype_an", 1, 1, PT_BOOL);
    ph_lib("ctype_space", "php_f_ctype_sp", 1, 1, PT_BOOL);
    ph_lib("ctype_upper", "php_f_ctype_up", 1, 1, PT_BOOL);
    ph_lib("ctype_lower", "php_f_ctype_lo", 1, 1, PT_BOOL);
    ph_lib("ctype_punct", "php_f_ctype_pu", 1, 1, PT_BOOL);
    ph_lib("ctype_xdigit", "php_f_ctype_xd", 1, 1, PT_BOOL);
    ph_lib("get_class", "php_f_get_class", 0, 1, PT_MIXED);
    ph_lib("get_parent_class", "php_f_get_parent_class", 0, 1, PT_MIXED);
    ph_lib("class_exists", "php_f_class_exists", 1, 2, PT_BOOL);
    ph_lib("interface_exists", "php_f_class_exists", 1, 2, PT_BOOL);
    ph_lib("enum_exists", "php_f_class_exists", 1, 2, PT_BOOL);
    ph_lib("method_exists", "php_f_method_exists", 2, 2, PT_BOOL);
    ph_lib("property_exists", "php_f_property_exists", 2, 2, PT_BOOL);
    ph_lib("is_callable", "php_f_is_callable", 1, 3, PT_BOOL);
    ph_lib("array_map", "php_f_array_map", 2, 2, PT_ARR);
    ph_lib("array_filter", "php_f_array_filter", 1, 3, PT_ARR);
    ph_lib("array_reduce", "php_f_array_reduce", 2, 3, PT_MIXED);
    ph_lib("usort", "php_f_usort_a", 2, 2, PT_BOOL);
    ph_lib("uasort", "php_f_uasort", 2, 2, PT_BOOL);
    ph_lib("uksort", "php_f_uksort", 2, 2, PT_BOOL);
    ph_lib("spl_object_id", "php_f_obj_id", 1, 1, PT_INT);
    ph_lib("spl_object_hash", "php_f_obj_id", 1, 1, PT_INT);
    ph_lib("array_key_exists", "php_f_array_key_exists", 2, 2, PT_BOOL);
    ph_lib("key_exists", "php_f_array_key_exists", 2, 2, PT_BOOL);
    ph_lib("array_keys", "php_f_array_keys", 1, 1, PT_ARR);
    ph_lib("array_values", "php_f_array_values", 1, 1, PT_ARR);
    ph_lib("in_array", "php_f_in_array", 2, 3, PT_BOOL);
    ph_lib("array_search", "php_f_array_search", 2, 3, PT_MIXED);
    ph_lib("array_merge", "php_f_array_merge", 1, 4, PT_ARR);
    ph_lib("array_pop", "php_f_array_pop", 1, 1, PT_MIXED);
    ph_lib("array_shift", "php_f_array_shift", 1, 1, PT_MIXED);
    ph_lib("array_unshift", "php_f_array_unshift", 2, 2, PT_INT);
    ph_lib("array_slice", "php_f_array_slice", 2, 4, PT_ARR);
    ph_lib("array_reverse", "php_f_array_reverse", 1, 2, PT_ARR);
    ph_lib("array_sum", "php_f_array_sum", 1, 1, PT_MIXED);
    ph_lib("array_product", "php_f_array_product", 1, 1, PT_MIXED);
    ph_lib("array_flip", "php_f_array_flip", 1, 1, PT_ARR);
    ph_lib("array_unique", "php_f_array_unique", 1, 2, PT_ARR);
    ph_lib("array_combine", "php_f_array_combine", 2, 2, PT_ARR);
    ph_lib("array_fill", "php_f_array_fill", 3, 3, PT_ARR);
    ph_lib("array_fill_keys", "php_f_array_fill_keys", 2, 2, PT_ARR);
    ph_lib("array_key_first", "php_f_array_key_first", 1, 1, PT_MIXED);
    ph_lib("array_key_last", "php_f_array_key_last", 1, 1, PT_MIXED);
    ph_lib("range", "php_f_range", 2, 3, PT_ARR);
    ph_lib("sort", "php_f_sort_a", 1, 2, PT_BOOL);
    ph_lib("rsort", "php_f_rsort", 1, 2, PT_BOOL);
    ph_lib("asort", "php_f_asort", 1, 2, PT_BOOL);
    ph_lib("arsort", "php_f_arsort", 1, 2, PT_BOOL);
    ph_lib("ksort", "php_f_ksort", 1, 2, PT_BOOL);
    ph_lib("krsort", "php_f_krsort", 1, 2, PT_BOOL);
    ph_lib("bin2hex", "php_f_bin2hex", 1, 1, PT_STRING);
    ph_lib("hex2bin", "php_f_hex2bin", 1, 1, PT_STRING);
    ph_lib("base64_encode", "php_f_base64_encode", 1, 1, PT_STRING);
    ph_lib("base64_decode", "php_f_base64_decode", 1, 2, PT_STRING);
    ph_lib("strspn", "php_f_strspn", 2, 4, PT_INT);
    ph_lib("strcspn", "php_f_strcspn", 2, 4, PT_INT);
    ph_lib("chunk_split", "php_f_chunk_split", 1, 3, PT_STRING);
    ph_lib("substr_replace", "php_f_substr_replace", 3, 4, PT_STRING);
    ph_lib("substr_count", "php_f_substr_count", 2, 2, PT_INT);
    ph_lib("strrpos", "php_f_strrpos", 2, 3, PT_IFALSE);
    ph_lib("stripos", "php_f_stripos", 2, 3, PT_IFALSE);
    ph_lib("strripos", "php_f_strripos", 2, 3, PT_IFALSE);
    ph_lib("strstr", "php_f_strstr", 2, 3, PT_MIXED);
    ph_lib("stristr", "php_f_stristr", 2, 3, PT_MIXED);
    ph_lib("strchr", "php_f_strstr", 2, 3, PT_MIXED);
    ph_lib("strrchr", "php_f_strrchr", 2, 2, PT_MIXED);
    ph_lib("strncmp", "php_f_strncmp", 3, 3, PT_INT);
    ph_lib("strncasecmp", "php_f_strncasecmp", 3, 3, PT_INT);
    ph_lib("str_ireplace", "php_f_str_ireplace", 3, 3, PT_STRING);
    ph_lib("str_split", "php_f_str_split", 1, 2, PT_ARR);
    ph_lib("ucwords", "php_f_ucwords", 1, 2, PT_STRING);
    ph_lib("nl2br", "php_f_nl2br", 1, 2, PT_STRING);
    ph_lib("strip_tags", "php_f_strip_tags", 1, 2, PT_STRING);
    ph_lib("addslashes", "php_f_addslashes", 1, 1, PT_STRING);
    ph_lib("stripslashes", "php_f_stripslashes", 1, 1, PT_STRING);
    ph_lib("htmlspecialchars", "php_f_htmlspecialchars", 1, 4, PT_STRING);
    ph_lib("htmlentities", "php_f_htmlspecialchars", 1, 4, PT_STRING);
    ph_lib("wordwrap", "php_f_wordwrap", 1, 4, PT_STRING);
    ph_lib("strtr", "php_f_strtr", 2, 3, PT_STRING);
    ph_lib("number_format", "php_f_number_format", 1, 4, PT_STRING);
    ph_lib("dechex", "php_f_dechex", 1, 1, PT_STRING);
    ph_lib("decbin", "php_f_decbin", 1, 1, PT_STRING);
    ph_lib("decoct", "php_f_decoct", 1, 1, PT_STRING);
    ph_lib("hexdec", "php_f_hexdec", 1, 1, PT_INT);
    ph_lib("bindec", "php_f_bindec", 1, 1, PT_INT);
    ph_lib("octdec", "php_f_octdec", 1, 1, PT_INT);
    ph_lib("base_convert", "php_f_base_convert", 3, 3, PT_STRING);
    ph_lib("floor", "php_f_floor", 1, 1, PT_FLOAT);
    ph_lib("ceil", "php_f_ceil", 1, 1, PT_FLOAT);
    ph_lib("round", "php_f_round", 1, 3, PT_FLOAT);
    ph_lib("sqrt", "php_f_sqrt", 1, 1, PT_FLOAT);
    ph_lib("fmod", "php_f_fmod", 2, 2, PT_FLOAT);
    ph_lib("exp", "php_f_exp", 1, 1, PT_FLOAT);
    ph_lib("log", "php_f_log", 1, 2, PT_FLOAT);
    ph_lib("log10", "php_f_log10", 1, 1, PT_FLOAT);
    ph_lib("pi", "php_f_pi", 0, 0, PT_FLOAT);
    ph_lib("is_nan", "php_f_is_nan", 1, 1, PT_BOOL);
    ph_lib("is_infinite", "php_f_is_infinite", 1, 1, PT_BOOL);
    ph_lib("is_finite", "php_f_is_finite", 1, 1, PT_BOOL);
    ph_lib("pow", "php_f_pow", 2, 2, PT_MIXED);
    ph_lib("mt_rand", "php_f_mt_rand", 0, 2, PT_INT);
    ph_lib("rand", "php_f_mt_rand", 0, 2, PT_INT);
    ph_lib("random_int", "php_f_mt_rand", 2, 2, PT_INT);
    ph_lib("mt_srand", "php_f_srand", 0, 2, PT_VOID);
    ph_lib("srand", "php_f_srand", 0, 2, PT_VOID);
    ph_lib("mt_getrandmax", "php_f_mt_getrandmax", 0, 0, PT_INT);
    ph_lib("getrandmax", "php_f_mt_getrandmax", 0, 0, PT_INT);
    ph_lib("gettype", "php_f_gettype", 1, 1, PT_STRING);
    ph_lib("get_debug_type", "php_f_get_debug_type", 1, 1, PT_STRING);
    ph_lib("print_r", "php_f_print_r", 1, 2, PT_STRING);
    ph_lib("var_export", "php_f_var_export", 1, 2, PT_STRING);
    ph_lib("ob_start", "php_ob_start", 0, 0, PT_VOID);
    ph_lib("ob_get_clean", "php_ob_get", 0, 0, PT_STRING);
    ph_lib("ob_get_contents", "php_ob_get", 0, 0, PT_STRING);
    ph_lib("error_reporting", "php_f_error_reporting", 0, 1, PT_INT);
    ph_lib("ini_set", "php_f_nullf", 0, 3, PT_MIXED);
    ph_lib("ini_get", "php_f_null1", 0, 1, PT_MIXED);
    ph_lib("set_error_handler", "php_f_null2", 0, 2, PT_MIXED);
    ph_lib("setlocale", "php_f_null2", 0, 2, PT_MIXED);
    ph_lib("gc_collect_cycles", "php_f_noop", 0, 1, PT_INT);
    ph_lib("error_log", "php_f_false1", 0, 1, PT_BOOL);
    ph_lib("usleep", "php_f_noop", 0, 1, PT_INT);
}

// ---- the one registration --------------------------------------------------
void ph_program() {
    i64 line = ph_tline;
    uptr fl = p_file();
    ph_toplevel = 1;
    ph_fn_ret = PT_VOID;
    ph_sync();
    ph_next();                                    // <?php
    loop {
        if (ph_tid == T_EOF) break;
        if (ph_is("function")) {
            top_add(ph_function());
            continue;
        }
        i64 s = ph_stmt_checked();
        if (ph_main_tail) set_nd_next(ph_main_tail, s);
        if (!ph_main_tail) ph_main_head = s;
        ph_main_tail = s;
        loop { if (!nd_next(ph_main_tail)) break; ph_main_tail = nd_next(ph_main_tail); }
    }
    i64 fin = node_new(N_EXPRSTMT, line, fl);
    set_nd_a(fin, ph_call("php_uncaught", 0, 0, 0, 0, 0, TY_VOID));
    // D7 has no refcount, so the honest destructor point is the end of the
    // program: php runs every surviving __destruct there too.
    i64 fin1 = node_new(N_EXPRSTMT, line, fl);
    set_nd_a(fin1, ph_call("php_shutdown", 0, 0, 0, 0, 0, TY_VOID));
    i64 fin2 = node_new(N_EXPRSTMT, line, fl);
    set_nd_a(fin2, ph_call("php_flush", 0, 0, 0, 0, 0, TY_VOID));
    set_nd_next(fin, fin1);
    set_nd_next(fin1, fin2);
    if (ph_main_tail) set_nd_next(ph_main_tail, fin);
    if (!ph_main_tail) ph_main_head = fin;
    i64 r = node_new(N_RETURN, line, fl);
    set_nd_a(r, ph_int(0));
    set_nd_next(fin2, r);
    // every class entry is created first, then filled: a class may extend one
    // that is declared later in the file, which php hoists too.
    if (ph_cfill_head) {
        if (ph_cnew_tail) set_nd_next(ph_cnew_tail, ph_cfill_head);
        if (!ph_cnew_tail) ph_cnew_head = ph_cfill_head;
    }
    i64 boot = ph_stmt_of(ph_call("php_bootstrap", 0, 0, 0, 0, 0, TY_VOID));
    set_nd_next(boot, ph_cnew_head);
    ph_cnew_head = boot;
    if (ph_cnew_head) {
        i64 ct = ph_cnew_head;
        loop { if (!nd_next(ct)) break; ct = nd_next(ct); }
        set_nd_next(ct, ph_main_head);
        ph_main_head = ph_cnew_head;
    }
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

// the byte scan that finds every aliased name, before a token is lexed
i64 ph_nmb(i64 c, i64 first) {
    if (c >= 97 && c <= 122) return 1;
    if (c >= 65 && c <= 90) return 1;
    if (c == 95) return 1;
    if (!first && c >= 48 && c <= 57) return 1;
    return 0;
}

uptr ph_scan_name(uptr src, i64 len, uptr pi) {
    i64 i = ld64(pi);
    i64 st = i;
    loop { if (i >= len) break; if (!ph_nmb(ld8(src + i), i == st)) break; i = i + 1; }
    if (i == st) return 0;
    uptr o = xalloc(i - st + 2);
    st8(o, 36);
    i64 k = 0;
    loop { if (k >= i - st) break; st8(o + 1 + k, ld8(src + st + k)); k = k + 1; }
    st8(o + 1 + (i - st), 0);
    st64(pi, i);
    return o;
}

void ph_scan_refs(uptr src, i64 len) {
    i64 i = 0;
    loop {
        if (i >= len) break;
        i64 c = ld8(src + i);
        if (c == 38 && i + 1 < len && ld8(src + i + 1) == 36) {     // &$name
            u8 pb[8];
            st64(pb, i + 2);
            uptr n = ph_scan_name(src, len, pb);
            if (n) { ph_refset_add(n); i = ld64(pb); continue; }
        }
        if (c == 36 && i + 1 < len) {                               // $name++ / $name--
            u8 pb3[8];
            st64(pb3, i + 1);
            uptr n3 = ph_scan_name(src, len, pb3);
            if (n3) {
                i64 j3 = ld64(pb3);
                loop { if (j3 >= len) break; if (!ph_space(ld8(src + j3))) break; j3 = j3 + 1; }
                if (j3 + 1 < len) {
                    i64 c1 = ld8(src + j3);
                    if ((c1 == 43 || c1 == 45) && ld8(src + j3 + 1) == c1) ph_incset_add(n3);
                }
                i = ld64(pb3);
                continue;
            }
        }
        if ((c == 43 || c == 45) && i + 2 < len && ld8(src + i + 1) == c) {   // ++$name
            i64 j4 = i + 2;
            loop { if (j4 >= len) break; if (!ph_space(ld8(src + j4))) break; j4 = j4 + 1; }
            if (j4 < len && ld8(src + j4) == 36) {
                u8 pb4[8];
                st64(pb4, j4 + 1);
                uptr n4 = ph_scan_name(src, len, pb4);
                if (n4) { ph_incset_add(n4); i = ld64(pb4); continue; }
            }
        }
        if (c == 103 && i + 6 < len) {                              // global
            if (ld8(src + i + 1) == 108 && ld8(src + i + 2) == 111 && ld8(src + i + 3) == 98
                && ld8(src + i + 4) == 97 && ld8(src + i + 5) == 108 && !ph_nmb(ld8(src + i + 6), 0)) {
                i64 j = i + 6;
                loop {
                    loop { if (j >= len) break; if (!ph_space(ld8(src + j))) break; j = j + 1; }
                    if (j >= len || ld8(src + j) != 36) break;
                    u8 pb2[8];
                    st64(pb2, j + 1);
                    uptr n2 = ph_scan_name(src, len, pb2);
                    if (!n2) break;
                    ph_refset_add(n2);
                    ph_gset_add(n2);
                    j = ld64(pb2);
                    loop { if (j >= len) break; if (!ph_space(ld8(src + j))) break; j = j + 1; }
                    if (j < len && ld8(src + j) == 44) { j = j + 1; continue; }
                    break;
                }
                i = j;
                continue;
            }
        }
        i = i + 1;
    }
}

void ph_on_source(uptr name, uptr src, i64 len) {
    ph_scan_refs(src, len);
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
    ty_pzv  = type_new("php_zval", 8, 8, TK_INT);
    ph_tokens();
    ph_lib_init();
    ph_pre_init();
    syntax_expr("$", &ph_dollar_expr);            // makes `$name` lex as `$` + name
    on_source(&ph_on_source);
    syntax("<?php", &ph_program);
    p_push_source("php runtime", ph_rt, ph_rt_size);
}

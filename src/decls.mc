// decls.mc -- the vocabulary, and the refusals.
// 
// The php type codes (docs/plan.md D10's left column), the visibility codes
// php_rt.mc repeats, the three mc type handles a php value lowers to, every
// forward declaration the single-pass compiler needs, and the NAMED refusals:
// D1 (no eval), D4 (one type per variable), D5, D6 (no reflection) and this
// compiler's own limits. A refusal is a design answer with a message and
// exit 3; anything else is an ordinary compile error.


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
i64  ph_expr_tail(i64 lhs, i64 lt, i64 minp);
i64  ph_stmt();
i64  ph_stmt_1();
i64  ph_block();
i64  ph_block_or_stmt();
i64  ph_if(uptr fl, i64 line);
i64  ph_foreach(uptr fl, i64 line);
i64  ph_builtin(uptr name, i64 line, uptr fl);
uptr ph_read_args(i64 maxn, uptr fl, i64 line, uptr pn);
uptr ph_alit(uptr av, i64 i);
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
i64  ph_nmb(i64 c, i64 first);
i64  ph_temp(i64 v, i64 mcty, uptr pfx);
i64  ph_tref(i64 t);
i64  ph_mcall_node(i64 recv, uptr name, uptr fl, i64 line);
i64  ph_mcall_ns(i64 recv, uptr name, uptr fl, i64 line, i64 ns);
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
void ph_brf_add(uptr n);
void ph_brf_init();
void ph_bind_undef(uptr d, uptr fl, i64 line, i64 quiet);
i64  ph_brf_has(uptr n);
i64  ph_incset_has(uptr n);
void ph_set_ref(uptr d);
uptr ph_scope_save();
void ph_scope_restore(uptr b);
i64  ph_closure(uptr fl, i64 line, i64 arrow);
void ph_tail(i64 head, i64 n);
i64  ph_prefix_stmts(i64 pre, i64 s);
void ph_ls_push(i64 kind);
void ph_ls_pop();
i64  ph_ls_level(i64 n, uptr fl, i64 line);
i64  ph_ls_try();
i64  ph_check(i64 line, uptr fl);
i64  ph_lv_walk(uptr d, uptr fl, i64 line, uptr pkey, i64 hoist);
uptr ph_lv_prop;
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
uptr ph_disp(uptr p);
i64  ph_scan_hop(uptr src, i64 len, i64 i);
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
i64  ph_truthy(i64 n);
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
// php runs a `finally` on the way out of a `return` in the try or the catch.
// The try body is a one-iteration mc loop, so a `return` inside it left the
// function without ever reaching the finally beside it. It becomes a value
// and a flag in two locals plus a break out to that loop; the finally then
// runs as the ordinary next statement and an `if` after it does the return.
// Per FUNCTION, not per try, so nested trys cascade: the inner one's `if`
// breaks out to the outer try, whose own `if` finishes the job.
uptr ph_frv;                   // the local holding the value, 0 = no try yet
uptr ph_frf;                   // its flag
i64 ph_toplevel;               // parsing main: an uncaught throwable is fatal
// The extension road (src/ext.mc). Here and not there because src/lvalue.mc
// reads it and mc is single pass; ext.mc is included after both.
i64 ph_ext;
uptr ph_entry;                 // the absolute path of the file mc-php was given
i64  ph_pushing;
i64  ph_type_word(i64 must);
i64  ph_type_tail(i64 t);
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
// probes/t8/mcphp.sh passes 255 through instead of calling it a compile
// error. It is neither a refusal (the grid's third column) nor an mc
// diagnostic: it is php's answer, produced where php produces it.
void ph_phpfatal(uptr fl, i64 line, uptr msg) {
    uptr a = ph_disp(ph_absfile(fl));
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
    m = p_cat(m, " is not implemented yet (probes/t10/RESULTS.md)", 0, 47);
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


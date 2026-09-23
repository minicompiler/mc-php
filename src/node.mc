// node.mc -- mc AST helpers, and where a php local lives.
// 
// The node constructors this module builds mc trees with, and the rule that
// every php local is hoisted to the top of the mc function: php declares a
// variable by assigning it and mc does not.

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

// `if (POINTER)` -- and NOT `(u8) POINTER`, which keeps the low BYTE and is
// false for every address that happens to end in 0x00. It cost a whole
// afternoon: the by-value copy of a parameter (and func_num_args's counter
// before it) was skipped whenever the arena put the zval on a 256-byte
// boundary, which two class methods rather than one or three was enough to
// arrange. `!!x` is mc's own 64-bit test, twice.
i64 ph_truthy(i64 n) {
    i64 a = node_new(N_UNARY, ph_tline, ph_tfile);
    set_nd_op(a, ph_tok("!", 1));
    set_nd_a(a, n);
    set_nd_type(a, TY_U8);
    i64 b = node_new(N_UNARY, ph_tline, ph_tfile);
    set_nd_op(b, ph_tok("!", 1));
    set_nd_a(b, a);
    set_nd_type(b, TY_U8);
    return b;
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


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

// a call that can neither raise nor throw -- an mc intrinsic such as ld64, or
// a runtime leaf that only reads memory -- and so does not make its statement
// announce a position or check for an exception (ph_stmt's rule). Only for a
// callee that provably calls nothing that raises: a wrong entry here is a
// diagnostic naming a stale line.
i64 ph_quiet(uptr name, i64 nargs, i64 a0, i64 a1, i64 a2, i64 a3, i64 ty) {
    i64 save = ph_can_throw;
    i64 c = ph_call(name, nargs, a0, a1, a2, a3, ty);
    ph_can_throw = save;
    return c;
}

// the length of a native php string: the zend_string's len field, loaded in
// place (php_strlen is exactly that load, behind a call)
i64 ph_strlen_of(i64 s) {
    return ph_quiet("ld64", 1, ph_bin(ph_tok("+", 1), s, ph_int(16), TY_UPTR), 0, 0, 0, TY_I64);
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
    // quiet: building a literal allocates and cannot raise, so a literal
    // must not make its statement announce a position or check for an
    // exception -- nor make ph_read_args spill it into a temporary, which
    // is what hid it from ph_is_strlit
    i64 c = ph_quiet("php_str_lit", 3, cache, ph_raw(bytes, len), ph_int(len), 0, ty_pstr);
    // Every literal is BUILT once, before the program's first statement
    // (ph_lit_finish), so a USE is one load from its cache. The node keeps
    // the php_str_lit shape until then, because the lowering reads literals
    // by that shape (define(), a class name, a map's set).
    if (ph_nlits == ph_litcap) {
        i64 cap = ph_litcap * 2;
        if (cap == 0) cap = 256;
        uptr nl = xalloc(cap * 8);
        i64 i = 0;
        loop { if (i >= ph_nlits) break; st64(nl + i * 8, ld64(ph_lits + i * 8)); i = i + 1; }
        ph_lits = nl;
        ph_litcap = cap;
    }
    st64(ph_lits + ph_nlits * 8, c);
    ph_nlits = ph_nlits + 1;
    return c;
}

uptr ph_lits;
i64  ph_nlits;
i64  ph_litcap;
uptr ph_bmaps;             // ph_bmap_of's sites, built beside the literals
i64  ph_nbmaps;
i64  ph_bmapcap;

// The end of the unit: one function that builds every literal the unit
// uses, called first thing by main (or MINIT), and every USE turned into a
// load of the cache that function filled -- php_str_lit was a call, and a
// test of the cache, per use. A literal lives in module memory either way.
i64 ph_lit_finish(uptr fl, i64 line) {
    i64 head = 0;
    i64 tail = 0;
    i64 i = 0;
    loop {
        if (i >= ph_nlits) break;
        i64 c = ld64(ph_lits + i * 8);
        i64 cache = nd_a(c);
        i64 raw = nd_next(cache);
        i64 len = nd_next(raw);
        i64 c2 = node_new(N_IDENT, nd_line(c), nd_file(c));
        set_nd_name(c2, nd_name(cache));
        set_nd_next(c2, ph_raw(nd_name(raw), nd_val(raw)));
        set_nd_next(nd_next(c2), ph_int(nd_val(len)));
        i64 bc = node_new(N_CALL, nd_line(c), nd_file(c));
        set_nd_name(bc, "php_str_lit");
        set_nd_a(bc, c2);
        set_nd_type(bc, ty_pstr);
        i64 st = node_new(N_EXPRSTMT, nd_line(c), nd_file(c));
        set_nd_a(st, bc);
        if (tail) set_nd_next(tail, st);
        if (!tail) head = st;
        tail = st;
        // the use: ld64(&cache)
        set_nd_name(c, "ld64");
        set_nd_next(cache, 0);
        i = i + 1;
    }
    // the byte maps, AFTER the literals they are built from; the literal
    // argument is already a load of its cache by now
    i = 0;
    loop {
        if (i >= ph_nbmaps) break;
        i64 m = ld64(ph_bmaps + i * 8);
        i64 mc = nd_a(m);
        i64 lit = nd_next(mc);
        i64 tr = nd_next(lit);
        i64 m2 = node_new(N_IDENT, nd_line(m), nd_file(m));
        set_nd_name(m2, nd_name(mc));
        i64 l2 = node_new(N_IDENT, nd_line(m), nd_file(m));
        set_nd_name(l2, nd_name(nd_a(lit)));
        i64 lc = node_new(N_CALL, nd_line(m), nd_file(m));
        set_nd_name(lc, "ld64");
        set_nd_a(lc, l2);
        set_nd_type(lc, ty_pstr);
        set_nd_next(m2, lc);
        set_nd_next(lc, ph_int(nd_val(tr)));
        i64 bc2 = node_new(N_CALL, nd_line(m), nd_file(m));
        set_nd_name(bc2, "php_bmap_lit");
        set_nd_a(bc2, m2);
        set_nd_type(bc2, TY_UPTR);
        i64 st2 = node_new(N_EXPRSTMT, nd_line(m), nd_file(m));
        set_nd_a(st2, bc2);
        if (tail) set_nd_next(tail, st2);
        if (!tail) head = st2;
        tail = st2;
        set_nd_name(m, "ld64");
        set_nd_next(mc, 0);
        i = i + 1;
    }
    i64 b = node_new(N_BLOCK, line, fl);
    set_nd_a(b, head);
    i64 f = node_new(N_FUNC, line, fl);
    set_nd_name(f, "ph_lit_init");
    set_nd_type(f, TY_VOID);
    set_nd_b(f, b);
    return f;
}

// one uptr global the runtime fills once and reads ever after -- the shape a
// literal's cache has, for anything else built once per literal site (a
// byte map, below). The IDENT is the global's address, as for php_str_lit.
i64 ph_cache_slot(uptr pfx) {
    ph_nonce = ph_nonce + 1;
    uptr nm = p_cat(pfx, "", 0, 0);
    nm = p_cat(nm, php_dec(ph_nonce), 0, cstrlen(php_dec(ph_nonce)));
    i64 g = node_new(N_GLOBAL, ph_tline, ph_tfile);
    set_nd_name(g, nm);
    set_nd_type(g, TY_UPTR);
    set_nd_val(g, 1);
    set_nd_a(g, 0);
    top_add(g);
    i64 cache = node_new(N_IDENT, ph_tline, ph_tfile);
    set_nd_name(cache, nm);
    return cache;
}

// the byte map of a LITERAL set (strspn/strcspn, trim's mask): built with
// the literals, before the first statement, and a use is one load -- it was
// a php_bmap_lit call and a cache test per use (examples/decimal: 2.6%)
i64 ph_bmap_of(i64 lit, i64 trim) {
    i64 c = ph_quiet("php_bmap_lit", 3, ph_cache_slot("phm_"), lit, ph_int(trim), 0, TY_UPTR);
    if (ph_nbmaps == ph_bmapcap) {
        i64 cap = ph_bmapcap * 2;
        if (cap == 0) cap = 64;
        uptr nb = xalloc(cap * 8);
        i64 i = 0;
        loop { if (i >= ph_nbmaps) break; st64(nb + i * 8, ld64(ph_bmaps + i * 8)); i = i + 1; }
        ph_bmaps = nb;
        ph_bmapcap = cap;
    }
    st64(ph_bmaps + ph_nbmaps * 8, c);
    ph_nbmaps = ph_nbmaps + 1;
    return c;
}

// is `n` a php string literal (ph_strlit's node)?
i64 ph_is_strlit(i64 n) {
    return nd_kind(n) == N_CALL && str_eq(nd_name(n), "php_str_lit");
}

// a literal's length, -1 when `n` is not one; and its first byte
i64 ph_lit_len(i64 n) {
    if (!ph_is_strlit(n)) return 0 - 1;
    return nd_val(nd_next(nd_a(n)));
}
i64 ph_lit_byte(i64 n) { return ld8(nd_name(nd_next(nd_a(n)))); }

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


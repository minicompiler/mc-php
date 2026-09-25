// opt.mc -- rewrites over a function's finished mc tree, run after src/rc.mc's
// on every road. Each one removes work the lowering asked for piece by piece
// and that a whole expression does not need.

i64 ph_opt_is(i64 n, uptr name) {
    if (!n) return 0;
    if (nd_kind(n) != N_CALL) return 0;
    return str_eq(nd_name(n), name);
}

// ---- substr() pieces of a concatenation are windows, not strings ------------
// `substr($c, 0, $k) . '.' . substr($c, $k)` built each substring, then the
// result, then dropped the two: three allocations for one string. A
// concatenation (php_str_concat, cat3, cat4 -- the chain expr.mc folds) with a
// substr() among its pieces becomes php_str_catwN, whose pieces are
// (string, start, length) with php's substr bounds (lib/php_rt.mc): the
// substrings are never built. It runs after src/rc.mc, which is what still
// sees `$s = $s . x` and `$s .= x` as the in-place appends they are.
i64 ph_opt_catn(i64 c) {
    if (ph_opt_is(c, "php_str_concat")) return 2;
    if (ph_opt_is(c, "php_str_cat3")) return 3;
    if (ph_opt_is(c, "php_str_cat4")) return 4;
    return 0;
}

i64 ph_opt_imax(i64 line, uptr fl) {
    i64 n = node_new(N_INT, line, fl);
    set_nd_val(n, 9223372036854775807);
    set_nd_type(n, TY_I64);
    return n;
}

i64 ph_opt_i0(i64 line, uptr fl) {
    i64 n = node_new(N_INT, line, fl);
    set_nd_val(n, 0);
    set_nd_type(n, TY_I64);
    return n;
}

void ph_opt_catw(i64 c) {
    i64 k = ph_opt_catn(c);
    if (!k) return;
    i64 p = nd_a(c);
    i64 any = 0;
    loop { if (!p) break; if (ph_opt_is(p, "php_substr")) any = 1; p = nd_next(p); }
    if (!any) return;
    i64 line = nd_line(c);
    uptr fl = nd_file(c);
    i64 head = 0;
    i64 tail = 0;
    p = nd_a(c);
    loop {
        if (!p) break;
        i64 nx = nd_next(p);
        i64 s = p;
        i64 st = 0;
        i64 ln = 0;
        if (ph_opt_is(p, "php_substr")) {
            s = nd_a(p);
            st = nd_next(s);
            ln = nd_next(st);
            i64 has = nd_next(ln);
            if (nd_kind(has) == N_INT && nd_val(has) == 0) ln = ph_opt_imax(line, fl);
        }
        if (!st) {
            st = ph_opt_i0(line, fl);
            ln = ph_opt_imax(line, fl);
        }
        set_nd_next(s, st);
        set_nd_next(st, ln);
        set_nd_next(ln, 0);
        if (tail) set_nd_next(tail, s);
        if (!tail) head = s;
        tail = ln;
        p = nx;
    }
    set_nd_a(c, head);
    if (k == 2) set_nd_name(c, "php_str_catw2");
    if (k == 3) set_nd_name(c, "php_str_catw3");
    if (k == 4) set_nd_name(c, "php_str_catw4");
}

// children first, so a concatenation nested in another is rewritten before
// its parent looks at it
void ph_opt_walk(i64 n) {
    loop {
        if (!n) break;
        ph_opt_walk(nd_a(n));
        ph_opt_walk(nd_b(n));
        ph_opt_walk(nd_c(n));
        ph_opt_walk(nd_d(n));
        if (nd_kind(n) == N_CALL) ph_opt_catw(n);
        n = nd_next(n);
    }
}

void ph_opt_fn(i64 f) {
    ph_opt_walk(nd_b(f));
}

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

// `$s . str_repeat('0', $n)` -- a pad: one string of the final length, where
// the repeat was a string of its own and the concatenation a second
void ph_opt_catrep(i64 c) {
    if (!ph_opt_is(c, "php_str_concat")) return;
    i64 a = nd_a(c);
    i64 r = nd_next(a);
    if (!r || nd_next(r) || !ph_opt_is(r, "php_str_repeat")) return;
    i64 ch = nd_a(r);
    set_nd_next(a, ch);
    set_nd_name(c, "php_str_catrep");
}

void ph_opt_catw(i64 c) {
    ph_opt_catrep(c);
    i64 k = ph_opt_catn(c);
    if (!k) return;
    i64 p = nd_a(c);
    i64 any = 0;
    loop { if (!p) break; if (ph_opt_is(p, "php_substr") || ph_opt_is(p, "php_vstr")) any = 1; p = nd_next(p); }
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
        // a window local made a string (ph_view_fn): its window as it is
        if (ph_opt_is(p, "php_vstr")) {
            s = nd_a(p);
            st = nd_next(s);
            ln = nd_next(st);
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

// ---- a short circuit is mc's own && and || again ------------------------------
// php's `a && b` is lowered through a u8 temporary (src/expr.mc): `t = a;
// if (t) { t = b; }` -- the right side may need statements of its own, and
// an mc expression has none. When it needed none, the temporary is only a
// value that goes through the frame: these rewrites, on adjacent statements,
// give mc the expression back, and mc's && and || short-circuit it the same
// way, in the same order, with no store and no load.
//   S1  t = a; if (t) { t = b; }         ->  t = a && b;     (b does not read t)
//   S2  t = a; if (!t) { t = b; }        ->  t = a || b;
//   S3  t = a; u = t;                    ->  u = a;          (t read nowhere else)
//   S4  t = a; if (t) X else Y           ->  if (a) X else Y (t read nowhere else;
//       and `if (!t)` alike)
uptr sc_body;

// a short circuit's temporary: phs_N, or an inlined copy's piK_phs_N
i64 sc_temp(i64 s) {
    if (nd_kind(s) != N_ASSIGN) return 0;
    uptr n = nd_name(s);
    loop {
        if (!ld8(n)) return 0;
        if (ld8(n) == 'p' && ld8(n + 1) == 'h' && ld8(n + 2) == 's' && ld8(n + 3) == '_') return 1;
        n = n + 1;
    }
    return 0;
}

// the if's condition is t (1) or !t (2), else 0
i64 sc_cond(i64 c, uptr t) {
    if (nd_kind(c) == N_IDENT && str_eq(nd_name(c), t)) return 1;
    if (nd_kind(c) == N_UNARY && nd_op(c) == ph_tok("!", 1) && nd_kind(nd_a(c)) == N_IDENT && str_eq(nd_name(nd_a(c)), t)) return 2;
    return 0;
}

i64 sc_list(i64 s);

// field f (0 a, 1 b, 2 c) of s: a block's list, or a lone statement
void sc_sub(i64 s, i64 f) {
    i64 x = nd_a(s);
    if (f == 1) x = nd_b(s);
    if (f == 2) x = nd_c(s);
    if (nd_kind(x) == N_BLOCK) { set_nd_a(x, sc_list(nd_a(x))); return; }
    x = sc_list(x);
    if (f == 0) set_nd_a(s, x);
    if (f == 1) set_nd_b(s, x);
    if (f == 2) set_nd_c(s, x);
}

void sc_inner(i64 s) {
    loop {
        if (!s) break;
        i64 k = nd_kind(s);
        if (k == N_IF) {
            if (nd_b(s)) sc_sub(s, 1);
            if (nd_c(s)) sc_sub(s, 2);
        }
        if (k == N_BLOCK) set_nd_a(s, sc_list(nd_a(s)));
        if (k == N_LOOP && nd_a(s)) sc_sub(s, 0);
        s = nd_next(s);
    }
}

i64 sc_list(i64 s) {
    sc_inner(s);
    i64 h = s;
    i64 pv = 0;
    loop {
        if (!s) break;
        i64 n2 = nd_next(s);
        if (sc_temp(s) && n2) {
            uptr t = nd_name(s);
            i64 k2 = nd_kind(n2);
            // S1 / S2
            if (k2 == N_IF && !nd_c(n2)) {
                i64 w = sc_cond(nd_a(n2), t);
                i64 b = phi_blist(nd_b(n2));
                if (w && b && !nd_next(b) && nd_kind(b) == N_ASSIGN && str_eq(nd_name(b), t) && !phi_uses(nd_a(b), t)) {
                    i64 op = node_new(N_BINARY, nd_line(s), nd_file(s));
                    if (w == 1) set_nd_op(op, ph_tok("&&", 2));
                    if (w == 2) set_nd_op(op, ph_tok("||", 2));
                    set_nd_type(op, TY_U8);
                    set_nd_a(op, nd_a(s));
                    set_nd_b(op, nd_a(b));
                    set_nd_a(s, op);
                    set_nd_next(s, nd_next(n2));
                    continue;
                }
            }
            if (phi_uses(sc_body, t) == 1) {
                // S3
                if (k2 == N_ASSIGN && nd_kind(nd_a(n2)) == N_IDENT && str_eq(nd_name(nd_a(n2)), t)) {
                    set_nd_a(n2, nd_a(s));
                    if (pv) set_nd_next(pv, n2);
                    if (!pv) h = n2;
                    s = n2;
                    continue;
                }
                // S4
                if (k2 == N_IF) {
                    i64 w2 = sc_cond(nd_a(n2), t);
                    if (w2 == 1) set_nd_a(n2, nd_a(s));
                    if (w2 == 2) set_nd_a(nd_a(n2), nd_a(s));
                    if (w2) {
                        if (pv) set_nd_next(pv, n2);
                        if (!pv) h = n2;
                        s = n2;
                        continue;
                    }
                }
            }
        }
        pv = s;
        s = n2;
    }
    return h;
}

// `if (a && b) X` with no else is `if (a) { if (b) X }`: the branches
// themselves, where mc's && would first make the value
void sc_nest(i64 s) {
    loop {
        if (!s) break;
        i64 k = nd_kind(s);
        if (k == N_IF) {
            loop {
                i64 c = nd_a(s);
                if (nd_c(s) || nd_kind(c) != N_BINARY || nd_op(c) != ph_tok("&&", 2)) break;
                i64 in = node_new(N_IF, nd_line(s), nd_file(s));
                set_nd_a(in, nd_b(c));
                set_nd_b(in, nd_b(s));
                set_nd_a(s, nd_a(c));
                set_nd_b(s, phi_block(in, nd_line(s), nd_file(s)));
            }
            sc_nest(phi_blist(nd_b(s)));
            if (nd_c(s)) sc_nest(phi_blist(nd_c(s)));
        }
        if (k == N_BLOCK) sc_nest(nd_a(s));
        if (k == N_LOOP) sc_nest(phi_blist(nd_a(s)));
        s = nd_next(s);
    }
}

void ph_sc_fn(i64 f) {
    i64 body = nd_b(f);
    if (!body) return;
    sc_body = body;
    set_nd_a(body, sc_list(nd_a(body)));
    sc_nest(nd_a(body));
}

void phr_fn(i64 f);
void ph_ac_walk(i64 n);

// ---- an array local's last read is a move, not a copy ----------------------
// `$row = []; ...fill $row...; $rows[] = $row;` in a loop copied the row into
// the list (ph_own's php_arr_copy) and then dropped the original when the
// next iteration made a new one: a copy per row of something no one reads
// again. A copy whose source is an array local that is dead after it -- every
// mention of the local is inside one loop's body, the body's first mention
// is a store of a value that does not read it (so the next iteration never
// sees the old array), the copy's statement mentions it once and none after
// it in the body does -- hands the array itself over (php_arr_mv). Runtime
// arrays have no free (D7), so the one array now has one name.
i64 vw_isparam(i64 f, uptr name);
i64 mv_cnt(i64 n, uptr v) {
    i64 c = 0;
    loop {
        if (!n) break;
        i64 k = nd_kind(n);
        if ((k == N_IDENT || k == N_ASSIGN) && str_eq(nd_name(n), v)) c = c + 1;
        if (k == N_ADDR) c = c + 1000;          // its address taken: never moved
        c = c + mv_cnt(nd_a(n), v) + mv_cnt(nd_b(n), v) + mv_cnt(nd_c(n), v) + mv_cnt(nd_d(n), v);
        n = nd_next(n);
    }
    return c;
}
i64 mv_cnt1(i64 n, uptr v) {
    i64 nx = nd_next(n);
    set_nd_next(n, 0);
    i64 c = mv_cnt(n, v);
    set_nd_next(n, nx);
    return c;
}
// the loop body's statements in order, blocks opened
uptr mv_seq;
i64  mv_n;
i64  mv_cap;
void mv_flat(i64 s) {
    loop {
        if (!s) break;
        if (nd_kind(s) == N_BLOCK) mv_flat(nd_a(s));
        else {
            if (mv_n == mv_cap) {
                i64 cap = mv_cap * 2 + 32;
                uptr nb = xalloc(cap * 8);
                i64 i = 0;
                loop { if (i >= mv_n) break; st64(nb + i * 8, ld64(mv_seq + i * 8)); i = i + 1; }
                mv_seq = nb;
                mv_cap = cap;
            }
            st64(mv_seq + mv_n * 8, s);
            mv_n = mv_n + 1;
        }
        s = nd_next(s);
    }
}
// php_arr_copy(IDENT v) inside n (not its siblings): renamed php_arr_mv
i64 mv_mark(i64 n, uptr v) {
    if (!n) return 0;
    if (nd_kind(n) == N_CALL && str_eq(nd_name(n), "php_arr_copy")) {
        i64 a = nd_a(n);
        if (a && nd_kind(a) == N_IDENT && str_eq(nd_name(a), v) && !nd_next(a)) { set_nd_name(n, "php_arr_mv"); return 1; }
    }
    i64 c = nd_a(n);
    loop { if (!c) break; if (mv_mark(c, v)) return 1; c = nd_next(c); }
    c = nd_b(n);
    loop { if (!c) break; if (mv_mark(c, v)) return 1; c = nd_next(c); }
    c = nd_c(n);
    loop { if (!c) break; if (mv_mark(c, v)) return 1; c = nd_next(c); }
    c = nd_d(n);
    loop { if (!c) break; if (mv_mark(c, v)) return 1; c = nd_next(c); }
    return 0;
}
// a copy of `v` in statement n?
i64 mv_hascopy(i64 n, uptr v) {
    if (!n) return 0;
    if (nd_kind(n) == N_CALL && str_eq(nd_name(n), "php_arr_copy")) {
        i64 a = nd_a(n);
        if (a && nd_kind(a) == N_IDENT && str_eq(nd_name(a), v) && !nd_next(a)) return 1;
    }
    i64 c = nd_a(n);
    loop { if (!c) break; if (mv_hascopy(c, v)) return 1; c = nd_next(c); }
    c = nd_b(n);
    loop { if (!c) break; if (mv_hascopy(c, v)) return 1; c = nd_next(c); }
    c = nd_c(n);
    loop { if (!c) break; if (mv_hascopy(c, v)) return 1; c = nd_next(c); }
    c = nd_d(n);
    loop { if (!c) break; if (mv_hascopy(c, v)) return 1; c = nd_next(c); }
    return 0;
}
void mv_loops(i64 s, uptr v, i64 total) {
    loop {
        if (!s) break;
        i64 k = nd_kind(s);
        if (k == N_LOOP && nd_a(s) && mv_cnt(nd_a(s), v) == total) {
            mv_n = 0;
            mv_flat(nd_a(s));
            // the body's first mention: a store whose value does not read v
            i64 i = 0;
            i64 ok = 0;
            loop {
                if (i >= mv_n) break;
                i64 e = ld64(mv_seq + i * 8);
                if (mv_cnt1(e, v)) {
                    ok = nd_kind(e) == N_ASSIGN && str_eq(nd_name(e), v) && mv_cnt(nd_a(e), v) == 0;
                    break;
                }
                i = i + 1;
            }
            if (ok) {
                // the last statement that mentions v, a copy and nothing else of v
                i64 j = mv_n - 1;
                loop {
                    if (j < 0) break;
                    i64 e = ld64(mv_seq + j * 8);
                    if (mv_cnt1(e, v)) {
                        if (j > i && mv_cnt1(e, v) == 1 && mv_hascopy(e, v)) mv_mark(e, v);
                        break;
                    }
                    j = j - 1;
                }
                return;
            }
            // not this loop's shape: an inner loop may hold every mention
            mv_loops(nd_a(s), v, total);
            return;
        }
        mv_loops(nd_a(s), v, total);
        mv_loops(nd_b(s), v, total);
        mv_loops(nd_c(s), v, total);
        mv_loops(nd_d(s), v, total);
        s = nd_next(s);
    }
}
void ph_mv_fn(i64 f) {
    i64 body = nd_b(f);
    if (!body) return;
    i64 v = nd_a(body);
    loop {
        if (!v || nd_kind(v) != N_VAR) break;
        if (nd_type(v) == ty_parr && !nd_a(v) && !vw_isparam(f, nd_name(v))) {
            uptr nm = nd_name(v);
            i64 t = mv_cnt(nd_next(v), nm);
            if (t > 0 && t < 1000) mv_loops(nd_next(v), nm, t);
        }
        v = nd_next(v);
    }
}

// ---- `$a[k] = v` with a string key or value boxes neither -------------------
// src/lvalue.mc writes the key into a zval temporary (phk_N = php_zstr(K))
// and the value as php_zstr(V); php_arr_set then copies the two words out of
// each box. A key temporary read only by the set that follows it, and a
// string value, go to the slot directly (php_arr_set_k/_s/_ks).
uptr aset_fn;
i64 aset_n(i64 n, uptr name) {
    i64 c = 0;
    loop {
        if (!n) break;
        if ((nd_kind(n) == N_IDENT || nd_kind(n) == N_ASSIGN) && str_eq(nd_name(n), name)) c = c + 1;
        c = c + aset_n(nd_a(n), name) + aset_n(nd_b(n), name) + aset_n(nd_c(n), name) + aset_n(nd_d(n), name);
        n = nd_next(n);
    }
    return c;
}
i64 ph_ext_pfx(uptr s, uptr p);
void ph_opt_aset(i64 s) {
    loop {
        if (!s) break;
        i64 k = nd_kind(s);
        i64 nx = nd_next(s);
        // the key's box, then the set reading it
        if (k == N_ASSIGN && ph_ext_pfx(nd_name(s), "phk_") && ph_opt_is(nd_a(s), "php_zstr") && nx
            && nd_kind(nx) == N_EXPRSTMT && ph_opt_is(nd_a(nx), "php_arr_set")) {
            i64 c = nd_a(nx);
            i64 ka = nd_next(nd_a(c));
            if (nd_kind(ka) == N_IDENT && str_eq(nd_name(ka), nd_name(s)) && aset_n(nd_b(aset_fn), nd_name(s)) == 2) {
                i64 key = nd_a(nd_a(s));
                set_nd_next(key, nd_next(ka));
                set_nd_next(nd_a(c), key);
                set_nd_name(c, "php_arr_set_k");
                // the box's statement goes: the set is in its place
                set_nd_kind(s, N_BLOCK);
                set_nd_a(s, 0);
            }
        }
        if (k == N_EXPRSTMT && (ph_opt_is(nd_a(s), "php_arr_set") || ph_opt_is(nd_a(s), "php_arr_set_k"))) {
            i64 c = nd_a(s);
            i64 v = nd_next(nd_next(nd_a(c)));
            if (ph_opt_is(v, "php_zstr")) {
                i64 y = nd_a(v);
                set_nd_next(nd_next(nd_a(c)), y);
                if (str_eq(nd_name(c), "php_arr_set")) set_nd_name(c, "php_arr_set_s");
                else set_nd_name(c, "php_arr_set_ks");
            }
        }
        if (k == N_BLOCK) ph_opt_aset(nd_a(s));
        if (k == N_IF) { ph_opt_aset(nd_b(s)); ph_opt_aset(nd_c(s)); }
        if (k == N_LOOP) ph_opt_aset(nd_a(s));
        s = nd_next(s);
    }
}

void ph_opt_fn(i64 f) {
    ph_mv_fn(f);
    aset_fn = f;
    if (nd_b(f)) ph_opt_aset(nd_a(nd_b(f)));
    ph_opt_walk(nd_b(f));
    phr_fn(f);
    // after the runtime's copies: a read the short circuit's right side made
    // is a copy by now, so the right side is still one expression
    ph_sc_fn(f);
    if (!phi_noac) ph_ac_walk(nd_b(f));
}

// ---- small php functions are inlined -----------------------------------------
// A call costs the callee's prologue and epilogue, its pool mark, and the
// position and unwinding check around it -- measured at 3.5 ns a call, and
// examples/decimal makes about twenty of them per dec_add. A small function
// with no loop is copied into its caller instead, BEFORE src/rc.mc sees
// either of them: the copy's locals become the caller's, its temporaries the
// caller's, and the caller's own pass counts (or borrows) them by its own
// rule, which is why the callee may have no loop -- a loop would turn a
// borrowing caller into a counting one.
//
// What is copied is the callee's finished pre-rc tree, taken when its own
// declaration ended, so only a function declared EARLIER is inlined (a later
// one's literals are globals mc has not seen yet), and a function never
// inlines itself. Its `return`s become stores into a local of the caller and
// the statements after an early one move into the branch that does not
// return; its parameters become locals assigned from the arguments, in their
// order, unless the argument is a local of the caller or an integer that the
// callee never assigns. The position a statement announced is announced again
// after the copy, which announced its own.
#define PHI_MAXN   450                // nodes in a callee's body, its own inlined copies included
uptr phi_name;                        // the candidates: mangled name, FUNC copy
uptr phi_fn;
i64  phi_n;
i64  phi_cap;
i64  phi_k;                           // one prefix per inlined copy
i64  phi_off;                         // MCPHP_INLINE=0 in the compiler's environment
uptr phi_vh;                          // the caller's new declarations
uptr phi_vt;
uptr phi_cf;                          // the caller being rewritten
i64  phi_term;
uptr phi_rn_old;                      // the rename of one copy
uptr phi_rn_new;
i64  phi_rn_n;
i64  phi_rn_cap;

i64 phi_noac;                         // MCPHP_AC=0: addresses keep their constants where they are

void phi_env() {
    uptr e = host_environ();
    if (!e) return;
    i64 i = 0;
    loop {
        uptr s = ld64(e + i * 8);
        if (!s) return;
        if (str_eq(s, "MCPHP_INLINE=0")) { phi_off = 1; return; }
        if (str_eq(s, "MCPHP_AC=0")) phi_noac = 1;
        i = i + 1;
    }
}

// a list, copied node by node
i64 phi_copy(i64 n) {
    i64 h = 0;
    i64 t = 0;
    loop {
        if (!n) break;
        i64 c = node_new(nd_kind(n), nd_line(n), nd_file(n));
        set_nd_name(c, nd_name(n));
        set_nd_type(c, nd_type(n));
        set_nd_op(c, nd_op(n));
        set_nd_val(c, nd_val(n));
        set_nd_sect(c, nd_sect(n));
        set_nd_a(c, phi_copy(nd_a(n)));
        set_nd_b(c, phi_copy(nd_b(n)));
        set_nd_c(c, phi_copy(nd_c(n)));
        set_nd_d(c, phi_copy(nd_d(n)));
        // a literal's use is rewritten into a load of its cache at the end
        // of the unit (ph_lit_finish): the copy has to be too
        if (nd_kind(n) == N_CALL && (str_eq(nd_name(n), "php_str_lit") || str_eq(nd_name(n), "php_bmap_lit")))
            ph_lit_copied(c);
        if (t) set_nd_next(t, c);
        if (!t) h = c;
        t = c;
        n = nd_next(n);
    }
    return h;
}

i64 phi_find(uptr name) {
    i64 i = 0;
    loop {
        if (i >= phi_n) break;
        if (str_eq(ld64(phi_name + i * 8), name)) return i;
        i = i + 1;
    }
    return 0 - 1;
}

// ---- which function may be copied --------------------------------------------
i64 phi_size;
i64 phi_bad;
i64 phi_rt;                           // scanning a runtime routine: its stores to globals are its own

// is `name` declared in the function (a parameter or a local)?
i64 phi_decl_in(i64 s, uptr name) {
    loop {
        if (!s) break;
        i64 k = nd_kind(s);
        if ((k == N_VAR || k == N_PARAM) && str_eq(nd_name(s), name)) return 1;
        if (phi_decl_in(nd_a(s), name)) return 1;
        if (phi_decl_in(nd_b(s), name)) return 1;
        if (phi_decl_in(nd_c(s), name)) return 1;
        s = nd_next(s);
    }
    return 0;
}

i64 phi_denied(uptr c) {
    if (str_eq(c, "php_static")) return 1;
    if (str_eq(c, "php_global")) return 1;
    i64 n = cstrlen(c);
    // anything that asks about the frame it runs in
    if (n > 9 && ld8(c) == 'p' && ld8(c + 4) == 'f' && ld8(c + 5) == 'u' && ld8(c + 6) == 'n' && ld8(c + 7) == 'c') return 1;
    return 0;
}

i64 rp_pfx(uptr s, uptr p) {
    i64 i = 0;
    loop { i64 c = ld8(p + i); if (!c) return 1; if (ld8(s + i) != c) return 0; i = i + 1; }
    return 0;
}

void phi_scan(i64 f, i64 s) {
    loop {
        if (!s) break;
        phi_size = phi_size + 1;
        i64 k = nd_kind(s);
        if (k == N_LOOP || k == N_BREAK || k == N_CONTINUE || k == N_ADDR || k == N_HOLE
            || k == N_FUNC || k == N_GLOBAL || k == N_BLOB || k == N_INDEX) phi_bad = 1;
        // a local array is not copied -- except the rope's (ph_rope_fn), whose
        // every slot is stored before the return reads it, so a copy declared
        // once at the caller's head is the same array on every pass
        if (k == N_VAR && nd_val(s) && (nd_a(s) || !rp_pfx(nd_name(s), "ph_rope_"))) phi_bad = 1;
        if (k == N_ASSIGN && !phi_rt && !str_eq(nd_name(s), "ph_dfile") && !str_eq(nd_name(s), "ph_dline")
            && !phi_decl_in(f, nd_name(s))) phi_bad = 1;
        if (k == N_CALL && phi_denied(nd_name(s))) phi_bad = 1;
        phi_scan(f, nd_a(s));
        phi_scan(f, nd_b(s));
        phi_scan(f, nd_c(s));
        phi_scan(f, nd_d(s));
        s = nd_next(s);
    }
}

// ---- the copy: renamed, its declarations lifted out, its returns stores -------
void phi_rn_add(uptr old, uptr nw) {
    if (phi_rn_n == phi_rn_cap) {
        i64 cap = phi_rn_cap * 2 + 16;
        uptr a = xalloc(cap * 8);
        uptr b = xalloc(cap * 8);
        i64 i = 0;
        loop { if (i >= phi_rn_n) break; st64(a + i * 8, ld64(phi_rn_old + i * 8)); st64(b + i * 8, ld64(phi_rn_new + i * 8)); i = i + 1; }
        phi_rn_old = a;
        phi_rn_new = b;
        phi_rn_cap = cap;
    }
    st64(phi_rn_old + phi_rn_n * 8, old);
    st64(phi_rn_new + phi_rn_n * 8, nw);
    phi_rn_n = phi_rn_n + 1;
}

uptr phi_rn_get(uptr old) {
    i64 i = 0;
    loop {
        if (i >= phi_rn_n) break;
        if (str_eq(ld64(phi_rn_old + i * 8), old)) return ld64(phi_rn_new + i * 8);
        i = i + 1;
    }
    return 0;
}

uptr phi_pfx;
uptr phi_local(uptr old) { return p_cat(phi_pfx, old, 0, cstrlen(old)); }

void phi_rename(i64 s) {
    loop {
        if (!s) break;
        i64 k = nd_kind(s);
        if (k == N_IDENT || k == N_ASSIGN || k == N_VAR) {
            uptr nw = phi_rn_get(nd_name(s));
            if (nw) set_nd_name(s, nw);
        }
        phi_rename(nd_a(s));
        phi_rename(nd_b(s));
        phi_rename(nd_c(s));
        phi_rename(nd_d(s));
        s = nd_next(s);
    }
}

// a declaration for the caller's head
void phi_declare(uptr name, i64 ty, i64 line, uptr fl) {
    i64 v = node_new(N_VAR, line, fl);
    set_nd_name(v, name);
    set_nd_type(v, ty);
    if (phi_vt) set_nd_next(phi_vt, v);
    if (!phi_vt) phi_vh = v;
    phi_vt = v;
}

// every N_VAR out of the list (declared at the caller's head instead); one
// with an initialiser leaves its store where it was
i64 phi_hoist(i64 s) {
    i64 h = 0;
    i64 t = 0;
    loop {
        if (!s) break;
        i64 nx = nd_next(s);
        set_nd_next(s, 0);
        i64 k = nd_kind(s);
        i64 keep = s;
        if (k == N_VAR) {
            phi_declare(nd_name(s), nd_type(s), nd_line(s), nd_file(s));
            set_nd_val(phi_vt, nd_val(s));          // an array keeps its size
            keep = 0;
            if (nd_a(s)) {
                keep = node_new(N_ASSIGN, nd_line(s), nd_file(s));
                set_nd_name(keep, nd_name(s));
                set_nd_a(keep, nd_a(s));
            }
        }
        if (k == N_BLOCK) set_nd_a(s, phi_hoist(nd_a(s)));
        if (k == N_IF) { set_nd_b(s, phi_hoist(nd_b(s))); set_nd_c(s, phi_hoist(nd_c(s))); }
        if (keep) {
            if (t) set_nd_next(t, keep);
            if (!t) h = keep;
            t = keep;
        }
        s = nx;
    }
    return h;
}

i64 phi_last(i64 s) {
    if (!s) return 0;
    loop { if (!nd_next(s)) break; s = nd_next(s); }
    return s;
}

i64 phi_cat(i64 a, i64 b) {
    if (!a) return b;
    set_nd_next(phi_last(a), b);
    return a;
}

// an IF branch as a list, and back
i64 phi_blist(i64 x) {
    if (!x) return 0;
    if (nd_kind(x) == N_BLOCK) return nd_a(x);
    return x;
}

i64 phi_block(i64 list, i64 line, uptr fl) {
    i64 b = node_new(N_BLOCK, line, fl);
    set_nd_a(b, list);
    return b;
}

// does every path through the list reach a return? (the tree is not touched)
i64 phi_ends(i64 s) {
    loop {
        if (!s) break;
        i64 k = nd_kind(s);
        if (k == N_RETURN) return 1;
        if (k == N_BLOCK) { if (phi_ends(nd_a(s))) return 1; }
        if (k == N_IF) { if (phi_ends(phi_blist(nd_b(s))) && phi_ends(phi_blist(nd_c(s)))) return 1; }
        s = nd_next(s);
    }
    return 0;
}

// is there a return anywhere in it?
i64 phi_has_ret(i64 s) {
    loop {
        if (!s) break;
        if (nd_kind(s) == N_RETURN) return 1;
        if (phi_has_ret(nd_a(s))) return 1;
        if (phi_has_ret(nd_b(s))) return 1;
        if (phi_has_ret(nd_c(s))) return 1;
        s = nd_next(s);
    }
    return 0;
}

// No N_RETURN left: `return e` is `rv = e`. What follows a statement where
// SOME path returned runs only on the others: moved into the branch that did
// not return when one of an if's branches always does, and otherwise guarded
// by a flag the returns set (phi_useflag; phi_needflag says a guard was
// wanted without one). phi_term says whether every path returned.
i64  phi_useflag;
i64  phi_needflag;
uptr phi_flag;

i64 phi_st(uptr name, i64 v, i64 line, uptr fl) {
    i64 a = node_new(N_ASSIGN, line, fl);
    set_nd_name(a, name);
    set_nd_a(a, v);
    return a;
}

i64 phi_i(i64 v, i64 line, uptr fl) {
    i64 n = node_new(N_INT, line, fl);
    set_nd_val(n, v);
    set_nd_type(n, TY_I64);
    return n;
}

i64 phi_lift(i64 s, uptr rv) {
    i64 h = 0;
    i64 t = 0;
    loop {
        if (!s) { phi_term = 0; return h; }
        i64 nx = nd_next(s);
        set_nd_next(s, 0);
        i64 k = nd_kind(s);
        i64 line = nd_line(s);
        uptr fl = nd_file(s);
        if (k == N_RETURN) {
            i64 r = 0;
            if (rv && nd_a(s)) r = phi_st(rv, nd_a(s), line, fl);
            if (phi_useflag) r = phi_cat(r, phi_st(phi_flag, phi_i(1, line, fl), line, fl));
            if (r) {
                if (t) set_nd_next(t, r);
                if (!t) h = r;
            }
            phi_term = 1;
            return h;
        }
        if (k == N_BLOCK) {
            s = phi_cat(nd_a(s), nx);
            continue;
        }
        if (k == N_IF) {
            i64 bb = phi_blist(nd_b(s));
            i64 cc = phi_blist(nd_c(s));
            i64 eb = phi_ends(bb);
            i64 ec = phi_ends(cc);
            i64 pr = phi_has_ret(bb) || phi_has_ret(cc);
            i64 tr = 0;
            i64 done = 1;
            if (eb && ec) { bb = phi_lift(bb, rv); cc = phi_lift(cc, rv); tr = 1; }
            if (eb && !ec) { bb = phi_lift(bb, rv); cc = phi_lift(phi_cat(cc, nx), rv); tr = phi_term; }
            if (ec && !eb) { cc = phi_lift(cc, rv); bb = phi_lift(phi_cat(bb, nx), rv); tr = phi_term; }
            if (!eb && !ec) { bb = phi_lift(bb, rv); cc = phi_lift(cc, rv); done = 0; }
            set_nd_b(s, phi_block(bb, line, fl));
            set_nd_c(s, 0);
            if (cc) set_nd_c(s, phi_block(cc, line, fl));
            if (t) set_nd_next(t, s);
            if (!t) h = s;
            t = s;
            if (done) { phi_term = tr; return h; }
            if (pr && nx) {
                if (!phi_useflag) phi_needflag = 1;
                i64 rest = phi_lift(nx, rv);
                tr = phi_term;
                i64 id = node_new(N_IDENT, line, fl);
                set_nd_name(id, phi_flag);
                set_nd_type(id, TY_I64);
                i64 nt = node_new(N_UNARY, line, fl);
                set_nd_op(nt, ph_tok("!", 1));
                set_nd_a(nt, id);
                set_nd_type(nt, TY_U8);
                i64 g = node_new(N_IF, line, fl);
                set_nd_a(g, nt);
                set_nd_b(g, phi_block(rest, line, fl));
                set_nd_next(t, g);
                phi_term = tr;
                return h;
            }
            s = nx;
            continue;
        }
        if (t) set_nd_next(t, s);
        if (!t) h = s;
        t = s;
        s = nx;
    }
    return h;
}

i64 phi_copy1(i64 n) {
    i64 nx = nd_next(n);
    set_nd_next(n, 0);
    i64 c = phi_copy(n);
    set_nd_next(n, nx);
    return c;
}

// ---- the constant of an address goes to the top ---------------------------------
// A copied byte read of `$s[$n - 1 - $j]` is ld8((s + 24) + ((n - 1) - j)): two
// constants the machine adds one at a time, each an instruction on the path to
// the load. Here the integer terms of the address are summed and put last,
// ld8((s + (n - j)) + 23), and src/mach.mc's P2 makes that 23 the load's own
// offset. The arithmetic wraps as C's does, so the sum is the same address.
i64 ph_ac_c;
i64 ph_ac_bad;
i64 ph_ac_split(i64 n, i64 sgn) {
    i64 k = nd_kind(n);
    if (k == N_INT) { ph_ac_c = ph_ac_c + sgn * nd_val(n); return 0; }
    if (k != N_BINARY) return n;
    i64 add = nd_op(n) == ph_tok("+", 1);
    if (!add && nd_op(n) != ph_tok("-", 1)) return n;
    i64 ra = ph_ac_split(nd_a(n), sgn);
    i64 sb = sgn;
    if (!add) sb = 0 - sgn;
    i64 rb = ph_ac_split(nd_b(n), sb);
    if (!rb) return ra;
    if (!ra) { if (!add) ph_ac_bad = 1; return rb; }
    set_nd_a(n, ra);
    set_nd_b(n, rb);
    return n;
}

void ph_ac_walk(i64 n) {
    loop {
        if (!n) break;
        if (nd_kind(n) == N_CALL && phi_intrinsic(nd_name(n)) && nd_a(n) && nd_kind(nd_a(n)) == N_BINARY) {
            i64 a = nd_a(n);
            i64 nx = nd_next(a);
            ph_ac_c = 0;
            ph_ac_bad = 0;
            i64 r = ph_ac_split(phi_copy1(a), 1);
            if (!ph_ac_bad && r && ph_ac_c != 0) {
                i64 t = node_new(N_BINARY, nd_line(a), nd_file(a));
                set_nd_op(t, ph_tok("+", 1));
                set_nd_a(t, r);
                i64 c = node_new(N_INT, nd_line(a), nd_file(a));
                set_nd_val(c, ph_ac_c);
                set_nd_type(c, TY_I64);
                set_nd_b(t, c);
                set_nd_type(t, nd_type(a));
                set_nd_next(t, nx);
                set_nd_a(n, t);
            }
        }
        ph_ac_walk(nd_a(n));
        ph_ac_walk(nd_b(n));
        ph_ac_walk(nd_c(n));
        ph_ac_walk(nd_d(n));
        n = nd_next(n);
    }
}


// ---- where a call may be taken out of its statement ---------------------------
// The first call to a candidate, in evaluation order, before which nothing
// but reads and arithmetic ran: its arguments go before the copy in their own
// order, and what was evaluated left of it is pure, so moving the call ahead
// of it changes nothing. Never the right side of && or ||, which may not run.
i64 phi_hit;
i64 phi_hold;
i64 phi_field;
i64 phi_dirty;

i64 phi_intrinsic(uptr c) {
    if (ld8(c) != 'l' && ld8(c) != 's') return 0;
    if (ld8(c + 1) != 'd' && ld8(c + 1) != 't') return 0;
    return str_eq(c + 2, "8") || str_eq(c + 2, "16") || str_eq(c + 2, "32") || str_eq(c + 2, "64");
}

// a copy binds each parameter to an argument, so only a call that passes
// exactly as many as the candidate declares is copied (mc-php refuses any
// other count of a plain signature while lowering, and the rest keep the call)
i64 phi_len(i64 n) {
    i64 k = 0;
    loop { if (!n) break; k = k + 1; n = nd_next(n); }
    return k;
}

i64 phi_arity_ok(i64 c) {
    i64 fc = ld64(phi_fn + phi_find(nd_name(c)) * 8);
    return phi_len(nd_a(c)) == phi_len(nd_a(fc));
}

void phi_seek(i64 hold, i64 field, i64 n, i64 sel) {
    if (!n) return;
    if (phi_hit) return;
    i64 k = nd_kind(n);
    if (k == N_IDENT || k == N_INT || k == N_STR) return;
    if (k == N_UNARY || k == N_CAST) { phi_seek(n, 0, nd_a(n), sel); return; }
    if (k == N_BINARY) {
        phi_seek(n, 0, nd_a(n), sel);
        i64 sc = nd_op(n) == ph_tok("&&", 2) || nd_op(n) == ph_tok("||", 2);
        if (sc) sel = 0;
        phi_seek(n, 1, nd_b(n), sel);
        return;
    }
    if (k == N_CALL) {
        i64 d0 = phi_dirty;
        i64 hh = n;
        i64 ff = 0;
        i64 p = nd_a(n);
        loop {
            if (!p) break;
            if (phi_hit) return;
            phi_seek(hh, ff, p, sel);
            hh = p;
            ff = 4;
            p = nd_next(p);
        }
        if (phi_hit) return;
        uptr nm = nd_name(n);
        if (phi_intrinsic(nm)) return;
        if (sel && !d0 && phi_find(nm) >= 0 && phi_arity_ok(n)) { phi_hit = n; phi_hold = hold; phi_field = field; return; }
        phi_dirty = 1;
        return;
    }
    phi_dirty = 1;
}

void phi_put(i64 hold, i64 field, i64 old, i64 nw) {
    set_nd_next(nw, nd_next(old));
    if (field == 0) set_nd_a(hold, nw);
    if (field == 1) set_nd_b(hold, nw);
    if (field == 2) set_nd_c(hold, nw);
    if (field == 3) set_nd_d(hold, nw);
    if (field == 4) set_nd_next(hold, nw);
}

void phi_vars(i64 s) {
    loop {
        if (!s) break;
        if (nd_kind(s) == N_VAR) phi_rn_add(nd_name(s), phi_local(nd_name(s)));
        phi_vars(nd_a(s));
        phi_vars(nd_b(s));
        phi_vars(nd_c(s));
        s = nd_next(s);
    }
}

i64 phi_local_of_caller(uptr name) {
    if (phi_decl_in(phi_vh, name)) return 1;
    return phi_decl_in(phi_cf, name);
}

i64 phi_list(i64 s);

// the runtime pass (phr_fn) substitutes an argument for a parameter of a
// different type of the same width and signedness -- a php string handle for
// a uptr -- and lets a routine return straight into the local it is assigned
// to; the php pass keeps to exact types (src/rc.mc tells strings by type)
i64 phi_rtpass;
i64 phi_drop;

i64 phi_cls(i64 t) {
    if (type_width(t) != 8) return 0 - 1;
    i64 k = type_kind(t);
    if (k != TK_INT && k != TK_SINT) return 0 - 1;
    return type_signed(t);
}

i64 phi_same_ty(i64 a, i64 b) {
    if (a == b) return 1;
    if (!phi_rtpass) return 0;
    return phi_cls(a) >= 0 && phi_cls(a) == phi_cls(b);
}

// the declared type of a local of the caller (0 when none is found)
i64 phi_decl_ty1(i64 s, uptr name) {
    loop {
        if (!s) break;
        i64 k = nd_kind(s);
        if ((k == N_VAR || k == N_PARAM) && str_eq(nd_name(s), name)) return nd_type(s);
        i64 t = phi_decl_ty1(nd_a(s), name);
        if (t) return t;
        t = phi_decl_ty1(nd_b(s), name);
        if (t) return t;
        t = phi_decl_ty1(nd_c(s), name);
        if (t) return t;
        s = nd_next(s);
    }
    return 0;
}

i64 phi_decl_ty(uptr name) {
    i64 t = phi_decl_ty1(phi_vh, name);
    if (t) return t;
    t = phi_decl_ty1(nd_a(phi_cf), name);
    if (t) return t;
    return phi_decl_ty1(nd_b(phi_cf), name);
}

// ---- an argument read once is the expression, not a local of its own ----------
// A parameter the copy reads exactly once and never assigns, bound to an
// argument that reads nothing but the caller's locals and integers, is
// replaced by the argument itself: a local of its own is one more value for
// mc's ten registers to hold, and in a loop that is inlined code a C compiler
// keeps in registers spilled to the frame. Evaluating the argument where the
// copy reads it instead of before the copy moves nothing observable: it reads
// no memory and calls nothing, and the copy cannot assign a caller's local.
i64 phi_pure_n;
i64 phi_pure_div;
i64 phi_pure1(i64 a) {
    phi_pure_n = phi_pure_n + 1;
    if (phi_pure_n > 16 || nd_next(a)) return 0;
    i64 k = nd_kind(a);
    if (k == N_INT) return 1;
    if (k == N_IDENT) return phi_local_of_caller(nd_name(a));
    if (k == N_UNARY) {
        if (nd_op(a) != ph_tok("-", 1) && nd_op(a) != ph_tok("~", 1)) return 0;
        return phi_pure1(nd_a(a));
    }
    if (k == N_BINARY) {
        i64 o = nd_op(a);
        // a division or remainder by a positive literal cannot trap on any
        // host (no zero, no INT_MIN / -1), so moving it is as pure as `*`
        if ((o == ph_tok("/", 1) || o == ph_tok("%", 1)) && nd_kind(nd_b(a)) == N_INT && nd_val(nd_b(a)) > 0) {
            phi_pure_div = 1;
            return phi_pure1(nd_a(a));
        }
        if (o != ph_tok("+", 1) && o != ph_tok("-", 1) && o != ph_tok("*", 1) && o != ph_tok("&", 1)
            && o != ph_tok("|", 1) && o != ph_tok("^", 1) && o != ph_tok("<<", 2) && o != ph_tok(">>", 2)) return 0;
        return phi_pure1(nd_a(a)) && phi_pure1(nd_b(a));
    }
    return 0;
}
i64 phi_pure(i64 a) { phi_pure_n = 0; phi_pure_div = 0; return phi_pure1(a); }

// the reads of `name` outside any call's arguments: a runtime fast path's
// (`if (i < len) { st8(...); return s; } return slow(s, i, c);`) -- the
// reads the slow call's arguments make run only when the fast one did not
i64 phi_uses_hot(i64 s, uptr name) {
    i64 u = 0;
    loop {
        if (!s) break;
        i64 k = nd_kind(s);
        if (k == N_IDENT && str_eq(nd_name(s), name)) u = u + 1;
        if (!(k == N_CALL && !phi_intrinsic(nd_name(s))))
            u = u + phi_uses_hot(nd_a(s), name) + phi_uses_hot(nd_b(s), name) + phi_uses_hot(nd_c(s), name) + phi_uses_hot(nd_d(s), name);
        s = nd_next(s);
    }
    return u;
}

// does the expression read no variable at all (a constant mc may fold)?
i64 phi_noid(i64 n) {
    loop {
        if (!n) break;
        if (nd_kind(n) == N_IDENT || nd_kind(n) == N_CALL) return 0;
        if (!phi_noid(nd_a(n)) || !phi_noid(nd_b(n))) return 0;
        n = nd_next(n);
    }
    return 1;
}
// is `name` read as the operand of a cast anywhere in s?
i64 phi_cast_use(i64 s, uptr name) {
    loop {
        if (!s) break;
        if (nd_kind(s) == N_CAST && nd_a(s) && nd_kind(nd_a(s)) == N_IDENT && str_eq(nd_name(nd_a(s)), name)) return 1;
        if (phi_cast_use(nd_a(s), name) || phi_cast_use(nd_b(s), name) || phi_cast_use(nd_c(s), name) || phi_cast_use(nd_d(s), name)) return 1;
        s = nd_next(s);
    }
    return 0;
}

// may an argument be substituted for every read of its parameter? Read once
// (the rule above), or, when it is small, read at most twice where it is hot
// -- `n - 1 - k`, a string offset's index the copied fast path both tests and
// uses -- plus reads in a slow call's arguments: computing it again is
// cheaper than a local of its own that the frame holds. A division is
// computed again only where it is cold.
i64 phi_reads_ok(i64 a, uptr pn, i64 body) {
    // A constant put under a cast is folded by mc into a plain literal, which
    // is an i64 again (mc's rule for a literal), so `(u64) i < (u64) n` with
    // i := -1 would compare SIGNED and take a fast path meant for 0 <= i < n:
    // a constant keeps its local wherever the parameter is cast.
    if (phi_noid(a) && phi_cast_use(body, pn)) return 0;
    i64 uses = phi_uses(body, pn);
    if (uses == 1) return 1;
    if (uses > 4 || nd_kind(a) == N_INT || nd_kind(a) == N_IDENT) return 0;
    if (!phi_pure(a) || phi_pure_n > 6) return 0;
    i64 hot = phi_uses_hot(body, pn);
    if (phi_pure_div) return hot <= 1;
    return hot <= 2;
}

// A LOAD of a pure address is pure too when the body it is copied into can
// write no memory: it calls nothing but mc's loads. A handler's argument read,
// `ld64(ex + 80)`, then goes where the parameter is read and needs no local
// of its own (examples/two-extensions: `a_add` is `return $a + $b;`).
i64 phi_loads_only(i64 n) {
    loop {
        if (!n) break;
        if (nd_kind(n) == N_CALL) {
            uptr c = nd_name(n);
            if (ld8(c) != 'l' || !phi_intrinsic(c)) return 0;
        }
        if (!phi_loads_only(nd_a(n)) || !phi_loads_only(nd_b(n)) || !phi_loads_only(nd_c(n)) || !phi_loads_only(nd_d(n))) return 0;
        n = nd_next(n);
    }
    return 1;
}
i64 phi_pure_load(i64 a, i64 body) {
    if (nd_next(a) || nd_kind(a) != N_CALL || ld8(nd_name(a)) != 'l' || !phi_intrinsic(nd_name(a))) return 0;
    if (!nd_a(a) || nd_next(nd_a(a)) || !phi_pure(nd_a(a))) return 0;
    // An extension handler's own argument, `ld64(ex + K)`: nothing the body
    // calls writes the engine frame of THIS call (a nested call is a frame of
    // its own, and no parameter here is by reference), so the load may go
    // where the parameter is read whatever the body does.
    i64 ad = nd_a(a);
    if (phi_cf && ld8(nd_name(phi_cf)) == 'x' && ld8(nd_name(phi_cf) + 1) == '_' && nd_kind(ad) == N_BINARY
        && nd_kind(nd_a(ad)) == N_IDENT && str_eq(nd_name(nd_a(ad)), "ex") && nd_kind(nd_b(ad)) == N_INT)
        return 1;
    // what follows a return at the top of the body never runs (a declared
    // return's `none returned` is there for the fall-through)
    loop {
        if (!body) break;
        i64 nx = nd_next(body);
        set_nd_next(body, 0);
        i64 ok = phi_loads_only(body);
        set_nd_next(body, nx);
        if (!ok) return 0;
        if (nd_kind(body) == N_RETURN) break;
        body = nx;
    }
    return 1;
}

i64 phi_uses(i64 s, uptr name) {
    i64 u = 0;
    loop {
        if (!s) break;
        if (nd_kind(s) == N_IDENT && str_eq(nd_name(s), name)) u = u + 1;
        u = u + phi_uses(nd_a(s), name) + phi_uses(nd_b(s), name) + phi_uses(nd_c(s), name) + phi_uses(nd_d(s), name);
        s = nd_next(s);
    }
    return u;
}

// the list with every read of `name` replaced by a copy of `a`
i64 phi_subl(i64 s, uptr name, i64 a) {
    i64 h = s;
    i64 pv = 0;
    loop {
        if (!s) break;
        i64 nx = nd_next(s);
        if (nd_kind(s) == N_IDENT && str_eq(nd_name(s), name)) {
            i64 c = phi_copy1(a);
            set_nd_next(c, nx);
            if (pv) set_nd_next(pv, c);
            if (!pv) h = c;
            s = c;
        } else {
            set_nd_a(s, phi_subl(nd_a(s), name, a));
            set_nd_b(s, phi_subl(nd_b(s), name, a));
            set_nd_c(s, phi_subl(nd_c(s), name, a));
            set_nd_d(s, phi_subl(nd_d(s), name, a));
        }
        pv = s;
        s = nx;
    }
    return h;
}

// does the expression call anything but mc's loads and stores?
i64 phi_calls_any(i64 n) {
    loop {
        if (!n) break;
        if (nd_kind(n) == N_CALL && !phi_intrinsic(nd_name(n))) return 1;
        if (phi_calls_any(nd_a(n)) || phi_calls_any(nd_b(n)) || phi_calls_any(nd_c(n)) || phi_calls_any(nd_d(n))) return 1;
        n = nd_next(n);
    }
    return 0;
}

// the statements that replace the call: arguments, then the body. The call
// itself becomes the local its returns store into.
i64 phi_expand(i64 c) {
    i64 fc = ld64(phi_fn + phi_find(nd_name(c)) * 8);
    i64 line = nd_line(c);
    uptr fl = nd_file(c);
    phi_k = phi_k + 1;
    uptr kd = php_dec(phi_k);
    phi_pfx = p_cat("pi", kd, 0, cstrlen(kd));
    phi_pfx = p_cat(phi_pfx, "_", 0, 1);
    phi_rn_n = 0;
    i64 body = phi_copy(nd_a(nd_b(fc)));
    i64 ph = 0;
    i64 pt = 0;
    uptr sn = xalloc(512);            // the substituted parameters: names, then arguments
    uptr sa = sn + 256;
    i64 ns = 0;
    i64 p = nd_a(fc);
    i64 a = nd_a(c);
    loop {
        if (!p) break;
        i64 an = nd_next(a);
        set_nd_next(a, 0);
        uptr pn = nd_name(p);
        if (nd_kind(a) == N_IDENT && phi_same_ty(nd_type(a), nd_type(p)) && phi_local_of_caller(nd_name(a))
            && !ph_rc_assigned(body, pn)) {
            phi_rn_add(pn, nd_name(a));
        } else if (nd_kind(a) != N_IDENT && phi_same_ty(nd_type(a), nd_type(p)) && (phi_pure(a) || phi_pure_load(a, body))
            && !ph_rc_assigned(body, pn) && phi_reads_ok(a, pn, body)) {
            // renamed to a name of this copy's own, then replaced by the argument
            uptr ln = phi_local(pn);
            phi_rn_add(pn, ln);
            st64(sn + ns * 8, ln);
            st64(sa + ns * 8, a);
            ns = ns + 1;
        } else {
            uptr ln = phi_local(pn);
            phi_rn_add(pn, ln);
            phi_declare(ln, nd_type(p), line, fl);
            i64 st = node_new(N_ASSIGN, line, fl);
            set_nd_name(st, ln);
            set_nd_a(st, a);
            if (pt) set_nd_next(pt, st);
            if (!pt) ph = st;
            pt = st;
        }
        p = nd_next(p);
        a = an;
    }
    phi_vars(body);
    phi_rename(body);
    // the substituted parameters: their reads become the arguments
    i64 si = 0;
    loop {
        if (si >= ns) break;
        body = phi_subl(body, ld64(sn + si * 8), ld64(sa + si * 8));
        si = si + 1;
    }
    body = phi_hoist(body);
    // a copy that is one `return E`, E reading and computing but calling
    // nothing: E itself takes the call's place, and no local holds the answer
    // (what follows a return at the top never runs: a declared return's
    // `none returned` is there for the fall-through)
    if (nd_kind(body) == N_RETURN && nd_a(body) && !phi_calls_any(nd_a(body))
        && nd_type(fc) != TY_VOID && !(nd_kind(phi_hold) == N_EXPRSTMT && nd_a(phi_hold) == c)) {
        i64 cv = node_new(N_CAST, line, fl);
        set_nd_type(cv, nd_type(fc));
        set_nd_a(cv, nd_a(body));
        phi_put(phi_hold, phi_field, c, cv);
        phi_drop = 0;
        return phi_list(ph);
    }
    uptr rv = 0;
    // a runtime routine whose answer is the whole value of `x = call(...)`,
    // x a local of the caller: its returns store into x itself, and the
    // statement goes (phi_drop)
    i64 drop = 0;
    if (phi_rtpass && nd_type(fc) != TY_VOID && phi_field == 0 && nd_kind(phi_hold) == N_ASSIGN
        && nd_a(phi_hold) == c && phi_local_of_caller(nd_name(phi_hold))
        && phi_same_ty(phi_decl_ty(nd_name(phi_hold)), nd_type(fc))) {
        rv = nd_name(phi_hold);
        drop = 1;
    }
    if (!rv && nd_type(fc) != TY_VOID) {
        rv = phi_local("ph_ret");
        phi_declare(rv, nd_type(fc), line, fl);
        i64 id = node_new(N_IDENT, line, fl);
        set_nd_name(id, rv);
        set_nd_type(id, nd_type(fc));
        phi_put(phi_hold, phi_field, c, id);
    }
    // a return nested where its if's other branch goes on needs the flag:
    // found on a throwaway copy, since the lift rewrites what it reads
    phi_useflag = 0;
    phi_needflag = 0;
    phi_flag = 0;
    phi_lift(phi_copy(body), rv);
    if (phi_needflag) {
        phi_useflag = 1;
        phi_flag = phi_local("ph_done");
        phi_declare(phi_flag, TY_I64, line, fl);
        body = phi_cat(phi_st(phi_flag, phi_i(0, line, fl), line, fl), body);
    }
    body = phi_lift(body, rv);
    phi_useflag = 0;
    // the arguments may call candidates of their own
    ph = phi_list(ph);
    phi_drop = drop;
    return phi_cat(ph, body);
}

// does the copy move the position? (then what follows it in the caller has to
// be told its own again: a statement further down that raises relies on it)
i64 phi_announces(i64 n) {
    loop {
        if (!n) break;
        if (nd_kind(n) == N_ASSIGN && str_eq(nd_name(n), "ph_dline")) return 1;
        if (phi_announces(nd_a(n))) return 1;
        if (phi_announces(nd_b(n))) return 1;
        if (phi_announces(nd_c(n))) return 1;
        n = nd_next(n);
    }
    return 0;
}

// exactly ph_posstmt's block: the two stores and nothing else. A block that
// merely BEGINS with them -- a loop body whose first statement's announcement
// a copy flattened into it -- is not one: taking it for one skipped the
// inlining inside that loop, and re-announcing "it" after a copy repeated the
// whole block.
i64 phi_is_ann(i64 s) {
    if (nd_kind(s) != N_BLOCK) return 0;
    i64 a = nd_a(s);
    if (!a || nd_kind(a) != N_ASSIGN || !str_eq(nd_name(a), "ph_dfile")) return 0;
    i64 b = nd_next(a);
    if (!b || nd_kind(b) != N_ASSIGN || !str_eq(nd_name(b), "ph_dline")) return 0;
    return nd_next(b) == 0;
}

i64 phi_list(i64 s) {
    i64 h = 0;
    i64 t = 0;
    i64 ann = 0;
    loop {
        if (!s) break;
        i64 nx = nd_next(s);
        set_nd_next(s, 0);
        i64 k = nd_kind(s);
        if (phi_is_ann(s)) ann = s;
        if (k == N_BLOCK && !phi_is_ann(s)) set_nd_a(s, phi_list(nd_a(s)));
        if (k == N_LOOP) set_nd_a(s, phi_list(nd_a(s)));
        if (k == N_ASSIGN || k == N_EXPRSTMT || k == N_RETURN || k == N_IF || (k == N_VAR && nd_a(s))) {
            loop {
                phi_hit = 0;
                phi_dirty = 0;
                phi_seek(s, 0, nd_a(s), 1);
                if (!phi_hit) break;
                i64 c = phi_hit;
                i64 whole = k == N_EXPRSTMT && nd_a(s) == c;
                i64 ins = phi_expand(c);
                if (phi_drop) whole = 1;
                if (ann && phi_announces(ins)) ins = phi_cat(ins, phi_copy1(ann));
                if (ins) {
                    if (t) set_nd_next(t, ins);
                    if (!t) h = ins;
                    t = phi_last(ins);
                }
                if (whole) { s = 0; break; }
            }
            if (s && k == N_IF) {
                set_nd_b(s, phi_list(nd_b(s)));
                set_nd_c(s, phi_list(nd_c(s)));
            }
        }
        if (s) {
            if (t) set_nd_next(t, s);
            if (!t) h = s;
            t = s;
        }
        s = nx;
    }
    return h;
}

// `f` is a finished function (a plain php function, before src/rc.mc):
// calls to candidates are copied in, then `f` becomes a candidate itself when
// `ok` (no by-reference, default or variadic parameter, no func_num_args) and
// it is small and loop-free.
void ph_rope_fn(i64 f);
void ph_inl_fn(i64 f, i64 ok) {
    if (phi_off) return;
    i64 body = nd_b(f);
    if (!body) return;
    phi_cf = f;
    phi_vh = 0;
    phi_vt = 0;
    set_nd_a(body, phi_list(nd_a(body)));
    if (phi_vh) { set_nd_next(phi_vt, nd_a(body)); set_nd_a(body, phi_vh); }
    phi_cf = 0;
    if (!ok) return;
    // The copy kept is roped (below) before it is kept, so a function that
    // builds its answer by appends is copied into its callers as ONE
    // allocation: once copied, its return is the caller's `ret = ...; break`
    // and the caller may loop, and the rope could no longer be found there.
    // The function's own body is roped later (src/decl.mc), after its
    // windows (ph_view_fn), which a copy never carries.
    i64 tf = phi_copy1(f);
    ph_rope_fn(tf);
    phi_size = 0;
    phi_bad = 0;
    phi_scan(tf, nd_b(tf));
    if (phi_bad || phi_size > PHI_MAXN) return;
    if (phi_n == phi_cap) {
        i64 cap = phi_cap * 2 + 32;
        uptr a = xalloc(cap * 8);
        uptr b = xalloc(cap * 8);
        i64 i = 0;
        loop { if (i >= phi_n) break; st64(a + i * 8, ld64(phi_name + i * 8)); st64(b + i * 8, ld64(phi_fn + i * 8)); i = i + 1; }
        phi_name = a;
        phi_fn = b;
        phi_cap = cap;
    }
    st64(phi_name + phi_n * 8, nd_name(f));
    st64(phi_fn + phi_n * 8, tf);
    phi_n = phi_n + 1;
}

// ---- a string built by appends is built once ---------------------------------
// `$o = X; ... $o .= A; ... $o .= B; ... return $o;` in a function that does
// not loop (examples/decimal's _dec_fmt) made a new string at every `.=`:
// three allocations and three copies of a growing prefix for one answer. When
// the local's first occurrence is that store, at the top of the body, and its
// every other occurrence is an append to itself or a `return $o;`, it is not
// a string until the return: each piece is a (string, start, length) window
// kept in a small array -- a substr() piece is its window, so that substring
// is never built either -- and the return makes ONE string of the final
// length (php_str_rope). The pieces stay alive for it: a function that does
// not loop drains nothing before it returns (src/rc.mc), and one with no zval
// can have no string written in place under it. Code with no loop runs its
// appends in the order they are written, so the pieces are in that order; an
// append that did not run is a piece with no string.
#define RP_MAX 16
i64 rp_bad;
i64 rp_first;
i64 rp_npc;
i64 rp_fn;

// is `name` a string parameter or local of rp_fn?
i64 rp_isstr(uptr name) {
    i64 p = nd_a(rp_fn);
    loop { if (!p) break; if (str_eq(nd_name(p), name)) return nd_type(p) == ty_pstr; p = nd_next(p); }
    p = nd_a(nd_b(rp_fn));
    loop {
        if (!p || nd_kind(p) != N_VAR) break;
        if (str_eq(nd_name(p), name)) return nd_type(p) == ty_pstr;
        p = nd_next(p);
    }
    return 0;
}

i64 rp_ment(i64 n, uptr name) {
    loop {
        if (!n) break;
        if (nd_kind(n) == N_IDENT && str_eq(nd_name(n), name)) return 1;
        if (rp_ment(nd_a(n), name) || rp_ment(nd_b(n), name) || rp_ment(nd_c(n), name) || rp_ment(nd_d(n), name)) return 1;
        n = nd_next(n);
    }
    return 0;
}
i64 rp_ment1(i64 n, uptr name) {
    if (nd_kind(n) == N_IDENT && str_eq(nd_name(n), name)) return 1;
    return rp_ment(nd_a(n), name) || rp_ment(nd_b(n), name) || rp_ment(nd_c(n), name) || rp_ment(nd_d(n), name);
}

// the pieces of `name = name . a [. b [. c]]`, 0 when s is not one
i64 rp_app(i64 s, uptr name) {
    if (nd_kind(s) != N_ASSIGN || !str_eq(nd_name(s), name)) return 0;
    i64 v = nd_a(s);
    if (nd_kind(v) != N_CALL) return 0;
    uptr f = nd_name(v);
    if (!str_eq(f, "php_str_concat") && !str_eq(f, "php_str_cat3") && !str_eq(f, "php_str_cat4")) return 0;
    i64 a = nd_a(v);
    if (nd_kind(a) != N_IDENT || !str_eq(nd_name(a), name)) return 0;
    if (rp_ment(nd_next(a), name)) return 0;
    return phi_len(nd_a(v)) - 1;
}

void rp_check(i64 s, uptr name, i64 top) {
    loop {
        if (!s || rp_bad) break;
        i64 k = nd_kind(s);
        // A piece is a window of a string that has to stay as it was until the
        // return builds the answer. In this function nothing is counted, but
        // once it is copied into a caller that loops (ph_inl_fn) its locals
        // are that caller's counted slots, and a string reassigned after it
        // became a piece would be released under the window. So after the
        // first store no other string is stored to at all.
        if (k == N_ASSIGN && rp_first && !str_eq(nd_name(s), name) && rp_isstr(nd_name(s))) { rp_bad = 1; return; }
        if (k == N_ASSIGN && str_eq(nd_name(s), name)) {
            if (!rp_first) {
                if (!top || rp_ment(nd_a(s), name)) { rp_bad = 1; return; }
                rp_first = 1;
                rp_npc = rp_npc + 1;
            } else {
                i64 p = rp_app(s, name);
                if (!p) { rp_bad = 1; return; }
                rp_npc = rp_npc + p;
            }
        } else if (k == N_RETURN && nd_a(s) && nd_kind(nd_a(s)) == N_IDENT && str_eq(nd_name(nd_a(s)), name)) {
            if (!rp_first) { rp_bad = 1; return; }
        } else if (k == N_IF) {
            if (rp_ment(nd_a(s), name)) { rp_bad = 1; return; }
            rp_check(nd_b(s), name, 0);
            rp_check(nd_c(s), name, 0);
        } else if (k == N_BLOCK) {
            rp_check(nd_a(s), name, 0);
        } else if (rp_ment1(s, name)) { rp_bad = 1; return; }
        s = nd_next(s);
    }
}

uptr rp_arr;
uptr rp_ptr;                        // where the next piece goes
i64  rp_j;

i64 rp_id(uptr name, i64 ty, i64 line, uptr fl) {
    i64 v = node_new(N_IDENT, line, fl);
    set_nd_name(v, name);
    set_nd_type(v, ty);
    return v;
}
i64 rp_int(i64 v, i64 line, uptr fl) {
    i64 n = node_new(N_INT, line, fl);
    set_nd_val(n, v);
    set_nd_type(n, TY_I64);
    return n;
}
// st64(base + off, v);
i64 rp_stb(uptr base, i64 off, i64 v, i64 line, uptr fl) {
    i64 ad = node_new(N_BINARY, line, fl);
    set_nd_op(ad, ph_tok("+", 1));
    set_nd_type(ad, TY_UPTR);
    set_nd_a(ad, rp_id(base, TY_UPTR, line, fl));
    set_nd_b(ad, rp_int(off, line, fl));
    set_nd_next(ad, v);
    i64 c = node_new(N_CALL, line, fl);
    set_nd_name(c, "st64");
    set_nd_type(c, TY_VOID);
    set_nd_a(c, ad);
    i64 st = node_new(N_EXPRSTMT, line, fl);
    set_nd_a(st, c);
    return st;
}
// `name = name + k;` / `name = from + k;`
i64 rp_bump(uptr name, uptr from, i64 k, i64 line, uptr fl) {
    i64 ad = node_new(N_BINARY, line, fl);
    set_nd_op(ad, ph_tok("+", 1));
    set_nd_type(ad, TY_UPTR);
    set_nd_a(ad, rp_id(from, TY_UPTR, line, fl));
    set_nd_b(ad, rp_int(k, line, fl));
    i64 as = node_new(N_ASSIGN, line, fl);
    set_nd_name(as, name);
    set_nd_a(as, ad);
    return as;
}
i64 vw_callx(uptr name, i64 args, i64 line, uptr fl) {
    i64 c = node_new(N_CALL, line, fl);
    set_nd_name(c, name);
    set_nd_type(c, TY_I64);
    set_nd_a(c, args);
    return c;
}
// The three stores of a piece: a substr() is its own window, anything else
// whole. The first store's piece is the array's first; every later one goes
// where rp_ptr points and moves it on, so the rope holds only the pieces
// whose append ran and costs nothing for one that did not.
i64 rp_piece(i64 y, i64 line, uptr fl) {
    uptr base = rp_ptr;
    if (rp_j == 0) base = rp_arr;
    rp_j = rp_j + 1;
    i64 s = y;
    i64 st = rp_int(0, line, fl);
    i64 ln = rp_int(9223372036854775807, line, fl);
    if (nd_kind(y) == N_CALL && str_eq(nd_name(y), "php_substr")) {
        s = nd_a(y);
        st = nd_next(s);
        i64 l2 = nd_next(st);
        i64 has = nd_next(l2);
        set_nd_next(s, 0);
        set_nd_next(st, 0);
        set_nd_next(l2, 0);
        if (!(nd_kind(has) == N_INT && nd_val(has) == 0)) ln = l2;
    }
    // a window local made a string (ph_view_fn): its window as it is
    if (nd_kind(y) == N_CALL && str_eq(nd_name(y), "php_vstr")) {
        s = nd_a(y);
        st = nd_next(s);
        ln = nd_next(st);
        set_nd_next(s, 0);
        set_nd_next(st, 0);
        set_nd_next(ln, 0);
    }
    // substr() of a window local (ph_view_fn): the window's string, the
    // start and length stored as given, then made the window's own --
    // php_substr_v's bounds -- with the entry's two words as the temporaries
    i64 fx = 0;
    if (nd_kind(y) == N_CALL && str_eq(nd_name(y), "php_substr_v")) {
        s = nd_a(y);
        i64 vs = nd_next(s);
        i64 vl = nd_next(vs);
        st = nd_next(vl);
        i64 l2 = nd_next(st);
        i64 has = nd_next(l2);
        set_nd_next(s, 0);
        set_nd_next(vs, 0);
        set_nd_next(vl, 0);
        set_nd_next(st, 0);
        set_nd_next(l2, 0);
        if (!(nd_kind(has) == N_INT && nd_val(has) == 0)) ln = l2;
        // php_rope_v(entry, vs, vl): the entry made the window's own
        i64 ad = node_new(N_BINARY, line, fl);
        set_nd_op(ad, ph_tok("+", 1));
        set_nd_type(ad, TY_UPTR);
        set_nd_a(ad, rp_id(base, TY_UPTR, line, fl));
        set_nd_b(ad, rp_int(0, line, fl));
        set_nd_next(ad, vs);
        set_nd_next(vs, vl);
        i64 cv = vw_callx("php_rope_v", ad, line, fl);
        set_nd_type(cv, TY_VOID);
        fx = node_new(N_EXPRSTMT, line, fl);
        set_nd_a(fx, cv);
    }
    set_nd_next(s, 0);
    i64 a = rp_stb(base, 0, s, line, fl);
    i64 b = rp_stb(base, 8, st, line, fl);
    i64 c = rp_stb(base, 16, ln, line, fl);
    set_nd_next(a, b);
    set_nd_next(b, c);
    if (fx) { set_nd_next(c, fx); c = phi_last(fx); }
    if (base == rp_arr) set_nd_next(c, rp_bump(rp_ptr, rp_arr, 24, line, fl));
    else set_nd_next(c, rp_bump(rp_ptr, rp_ptr, 24, line, fl));
    return a;
}

i64 rp_xform(i64 s, uptr name) {
    i64 h = 0;
    i64 t = 0;
    loop {
        if (!s) break;
        i64 nx = nd_next(s);
        set_nd_next(s, 0);
        i64 k = nd_kind(s);
        i64 line = nd_line(s);
        uptr fl = nd_file(s);
        i64 r = s;
        if (k == N_ASSIGN && str_eq(nd_name(s), name)) {
            if (rp_j == 0) {
                // the first store: the first piece, and the pointer past it
                r = rp_piece(nd_a(s), line, fl);
            } else {
                i64 y = nd_next(nd_a(nd_a(s)));
                r = 0;
                i64 rt = 0;
                loop {
                    if (!y) break;
                    i64 yn = nd_next(y);
                    set_nd_next(y, 0);
                    i64 p = rp_piece(y, line, fl);
                    if (rt) set_nd_next(rt, p);
                    if (!rt) r = p;
                    rt = phi_last(p);
                    y = yn;
                }
            }
        } else if (k == N_RETURN && nd_a(s) && nd_kind(nd_a(s)) == N_IDENT && str_eq(nd_name(nd_a(s)), name)) {
            i64 a0 = rp_id(rp_arr, TY_UPTR, line, fl);
            // the pieces that ran: (rp_ptr - rope) / 24
            set_nd_next(a0, ph_bin(ph_tok("/", 1), ph_bin(ph_tok("-", 1), rp_id(rp_ptr, TY_UPTR, line, fl),
                                   rp_id(rp_arr, TY_UPTR, line, fl), TY_I64), rp_int(24, line, fl), TY_I64));
            i64 c = node_new(N_CALL, line, fl);
            set_nd_name(c, "php_str_rope");
            set_nd_type(c, ty_pstr);
            set_nd_a(c, a0);
            set_nd_a(s, c);
        } else if (k == N_IF) {
            set_nd_b(s, rp_xform(nd_b(s), name));
            set_nd_c(s, rp_xform(nd_c(s), name));
        } else if (k == N_BLOCK) {
            set_nd_a(s, rp_xform(nd_a(s), name));
        }
        if (r) {
            if (t) set_nd_next(t, r);
            if (!t) h = r;
            t = phi_last(r);
        }
        s = nx;
    }
    return h;
}

i64 rp_nzv(i64 s) {
    loop {
        if (!s) break;
        i64 k = nd_kind(s);
        if ((k == N_VAR || k == N_PARAM) && nd_type(s) == ty_pzv) return 1;
        if (rp_nzv(nd_a(s)) || rp_nzv(nd_b(s)) || rp_nzv(nd_c(s))) return 1;
        s = nd_next(s);
    }
    return 0;
}

void ph_rope_fn(i64 f) {
    i64 body = nd_b(f);
    if (!body) return;
    if (ph_rc_has_loop(nd_a(body)) || rp_nzv(nd_a(f)) || rp_nzv(nd_a(body))) return;
    i64 v = nd_a(body);
    loop {
        if (!v) break;
        if (nd_kind(v) == N_VAR && nd_type(v) == ty_pstr && !nd_val(v)) {
            uptr name = nd_name(v);
            rp_fn = f;
            rp_bad = 0;
            rp_first = 0;
            rp_npc = 0;
            rp_check(nd_a(body), name, 1);
            if (!rp_bad && rp_first && rp_npc > 1 && rp_npc <= RP_MAX) {
                ph_nonce = ph_nonce + 1;
                rp_arr = p_cat("ph_rope_", php_dec(ph_nonce), 0, cstrlen(php_dec(ph_nonce)));
                rp_ptr = p_cat("ph_ropep_", php_dec(ph_nonce), 0, cstrlen(php_dec(ph_nonce)));
                i64 dp = node_new(N_VAR, nd_line(v), nd_file(v));
                set_nd_name(dp, rp_ptr);
                set_nd_type(dp, TY_UPTR);
                i64 d = node_new(N_VAR, nd_line(v), nd_file(v));
                set_nd_name(d, rp_arr);
                set_nd_type(d, TY_I64);
                set_nd_val(d, rp_npc * 3);
                set_nd_next(dp, d);
                rp_j = 0;
                set_nd_a(body, rp_xform(nd_a(body), name));
                set_nd_next(d, nd_a(body));
                set_nd_a(body, dp);
            }
        }
        v = nd_next(v);
    }
}

// ---- a substr() local is a window, not a string -------------------------------
// `$ip = substr($xd, 0, $n); $z = strspn($ip, '0'); $ip = substr($ip, $z);
// $v = $ip . substr($xd, $n);` built two strings that were only read through:
// a C programmer moves a pointer. In a function that does not loop nothing is
// counted, drained or written in place before it returns (src/rc.mc), so a
// string local may be held as a WINDOW of the string it was cut from -- three
// locals, base, start and length -- and stay alive exactly as long as the
// borrowing local it replaces. A read a window can serve takes none: strlen,
// a strspn scan, a byte, a substr() of it, a piece of a concatenation or of a
// rope; any other read is the window made a string there (php_vstr), and a
// local is taken only where that builds fewer strings than it saves. A
// function's inline copy (ph_inl_fn) is kept before this runs, so no window
// is ever copied into a caller that loops.
uptr vw_v;                          // the local, and its three
uptr vw_b;
uptr vw_s;
uptr vw_l;
i64  vw_nsub;                       // substr() stores it saves
i64  vw_noth;                       // reads it would make a string for
i64  vw_nst;                        // other stores: the whole of a string
i64  vw_nvc;                        // a window made a string, copied
i64  vw_bad;
i64  vw_ln;
uptr vw_fl;

i64 vw_is(i64 n) { return n && nd_kind(n) == N_IDENT && str_eq(nd_name(n), vw_v); }
i64 vw_id(uptr name, i64 ty) { return rp_id(name, ty, vw_ln, vw_fl); }
i64 vw_int(i64 v) { return rp_int(v, vw_ln, vw_fl); }
i64 vw_call(uptr name, i64 ty, i64 args) {
    i64 c = node_new(N_CALL, vw_ln, vw_fl);
    set_nd_name(c, name);
    set_nd_type(c, ty);
    set_nd_a(c, args);
    return c;
}
// a list of nodes, in order
i64 vw_args(i64 a, i64 b, i64 c, i64 d, i64 e, i64 f) {
    if (b) set_nd_next(a, b);
    if (c) set_nd_next(b, c);
    if (d) set_nd_next(c, d);
    if (e) set_nd_next(d, e);
    if (f) set_nd_next(e, f);
    return a;
}
i64 vw_win3() { return vw_args(vw_id(vw_b, TY_UPTR), vw_id(vw_s, TY_I64), vw_id(vw_l, TY_I64), 0, 0, 0); }

// `ld64(v + 16)`: the length
i64 vw_is_len(i64 n) {
    if (!ph_opt_is(n, "ld64")) return 0;
    i64 a = nd_a(n);
    return a && nd_kind(a) == N_BINARY && nd_op(a) == ph_tok("+", 1) && vw_is(nd_a(a))
        && nd_kind(nd_b(a)) == N_INT && nd_val(nd_b(a)) == 16;
}
// a call whose first argument is the local, read through as a window
i64 vw_is_winread(i64 n) {
    if (nd_kind(n) != N_CALL || !vw_is(nd_a(n))) return 0;
    uptr c = nd_name(n);
    return str_eq(c, "php_substr") || str_eq(c, "php_spn_r") || str_eq(c, "php_spn_o")
        || str_eq(c, "php_str_byte_c") || str_eq(c, "php_str_off_c");
}
// `v = substr(X, st, ln, has)` with has a literal: the store a window replaces
i64 vw_is_cut(i64 s) {
    if (nd_kind(s) != N_ASSIGN || !str_eq(nd_name(s), vw_v)) return 0;
    i64 v = nd_a(s);
    if (!ph_opt_is(v, "php_substr")) return 0;
    i64 b = nd_a(v);
    if (!b || nd_kind(b) != N_IDENT) return 0;
    i64 has = nd_next(nd_next(nd_next(b)));
    return has && nd_kind(has) == N_INT;
}

// ---- the count: what the window saves and what it would build
void vw_cnt1(i64 n);
void vw_cnt(i64 s) {
    loop {
        if (!s || vw_bad) break;
        i64 k = nd_kind(s);
        if (k == N_IDENT && vw_is(s)) vw_noth = vw_noth + 1;
        else if (k == N_ASSIGN && str_eq(nd_name(s), vw_v)) {
            if (vw_is_cut(s)) {
                vw_nsub = vw_nsub + 1;
                i64 b = nd_a(nd_a(s));
                vw_cnt(nd_next(b));               // st, ln: may read the local
            } else {
                // a window made a string keeps its window; anything else
                // makes the local the whole of a string
                if (ph_opt_is(nd_a(s), "php_vstr")) vw_nvc = vw_nvc + 1;
                else vw_nst = vw_nst + 1;
                vw_cnt(nd_a(s));
            }
        } else if (k == N_CALL && (vw_is_len(s) || vw_is_winread(s))) {
            if (vw_is_winread(s)) vw_cnt(nd_next(nd_a(s)));
        } else if (k == N_CALL && (str_eq(nd_name(s), "php_str_concat") || str_eq(nd_name(s), "php_str_cat3")
                                   || str_eq(nd_name(s), "php_str_cat4"))) {
            // a piece of a concatenation becomes a window (src/opt.mc's catw)
            i64 a = nd_a(s);
            loop { if (!a) break; if (!vw_is(a)) vw_cnt1(a); a = nd_next(a); }
        } else {
            vw_cnt(nd_a(s));
            vw_cnt(nd_b(s));
            vw_cnt(nd_c(s));
            vw_cnt(nd_d(s));
        }
        s = nd_next(s);
    }
}
void vw_cnt1(i64 n) {
    i64 nx = nd_next(n);
    set_nd_next(n, 0);
    vw_cnt(n);
    set_nd_next(n, nx);
}

// ---- the count along every path
// A read a window cannot serve builds a string only when the window is a part
// of its string: php_vstr of a whole string is that string. So what matters
// is not how many cuts and reads the function has, but, along each path, how
// many reads follow a cut against how many cuts there are. The walk keeps,
// for the paths that reach the current statement, the most and the least of
// (strings built - strings saved), separately for the paths where the local
// may now be a part (a cut, or a window copied) and where it is a whole
// string. A function has no loop here, so a path is a choice at each `if`;
// a `return` ends one, and a raise's unwinding is not counted. The local is
// taken when no path builds more than it saves and some path that runs to
// the function's own end saves: a saving only on an early `return` from
// inside an `if` -- a special case -- does not pay for the window's own
// bookkeeping on the path that is taken.
#define VW_NEG (0 - 1000000)
#define VW_POS 1000000
i64 vw_xw;                          // the most, whole / part
i64 vw_xc;
i64 vw_mw;                          // the least, whole / part
i64 vw_mc;
i64 vw_xr;                          // over the paths a return ended
i64 vw_mr;
i64 vw_ifd;                         // inside how many `if`s

i64 vw_max(i64 a, i64 b) { if (a > b) return a; return b; }
i64 vw_min(i64 a, i64 b) { if (a < b) return a; return b; }

// one statement: its reads, then its store
void vw_step(i64 s) {
    i64 n0 = vw_nsub;
    i64 r0 = vw_noth;
    i64 o0 = vw_nst;
    i64 c0 = vw_nvc;
    vw_cnt1(s);
    i64 cut = vw_nsub - n0;
    i64 oth = vw_nst - o0;
    i64 vc = vw_nvc - c0;
    vw_xc = vw_xc + vw_noth - r0;
    vw_mc = vw_mc + vw_noth - r0;
    if (cut + oth + vc > 1) { vw_bad = 1; return; }
    i64 x = vw_max(vw_xw, vw_xc);
    i64 m = vw_min(vw_mw, vw_mc);
    if (cut) { vw_xc = x - 1; vw_mc = m - 1; vw_xw = VW_NEG; vw_mw = VW_POS; }
    if (vc) { vw_xc = x; vw_mc = m; vw_xw = VW_NEG; vw_mw = VW_POS; }
    if (oth) { vw_xw = x; vw_mw = m; vw_xc = VW_NEG; vw_mc = VW_POS; }
}

i64 phr_is_check(i64 s);
i64 vw_is_exc(i64 c) {
    if (nd_kind(c) != N_UNARY) return 0;
    c = nd_a(c);
    if (nd_kind(c) != N_UNARY) return 0;
    c = nd_a(c);
    return nd_kind(c) == N_IDENT && str_eq(nd_name(c), "ph_exc");
}
void vw_flow(i64 s) {
    loop {
        if (!s || vw_bad) break;
        i64 k = nd_kind(s);
        // a raise's unwinding is not a path the count is about
        if (phr_is_check(s)) { s = nd_next(s); continue; }
        // an inline copy's check: `if (!!ph_exc) <set its answer> else <rest>`
        if (k == N_IF && vw_is_exc(nd_a(s))) { vw_flow(nd_c(s)); s = nd_next(s); continue; }
        if (k == N_BLOCK) vw_flow(nd_a(s));
        else if (k == N_IF) {
            vw_step(nd_a(s));
            i64 xw = vw_xw;
            i64 xc = vw_xc;
            i64 mw = vw_mw;
            i64 mc = vw_mc;
            vw_ifd = vw_ifd + 1;
            vw_flow(nd_b(s));
            i64 bxw = vw_xw;
            i64 bxc = vw_xc;
            i64 bmw = vw_mw;
            i64 bmc = vw_mc;
            vw_xw = xw;
            vw_xc = xc;
            vw_mw = mw;
            vw_mc = mc;
            vw_flow(nd_c(s));
            vw_ifd = vw_ifd - 1;
            vw_xw = vw_max(vw_xw, bxw);
            vw_xc = vw_max(vw_xc, bxc);
            vw_mw = vw_min(vw_mw, bmw);
            vw_mc = vw_min(vw_mc, bmc);
        } else if (k == N_RETURN) {
            if (nd_a(s)) vw_step(nd_a(s));
            vw_xr = vw_max(vw_xr, vw_max(vw_xw, vw_xc));
            if (!vw_ifd) vw_mr = vw_min(vw_mr, vw_min(vw_mw, vw_mc));
            vw_xw = VW_NEG;
            vw_xc = VW_NEG;
            vw_mw = VW_POS;
            vw_mc = VW_POS;
        } else vw_step(s);
        s = nd_next(s);
    }
}

// ---- `$v = c ? A : B` stores the local in each branch
// expr.mc makes a conditional a temporary set in each branch, then copies it:
// `if (c) phq = A; else phq = B; $v = phq;`. Where the copy is the
// temporary's only read and the two are strings, each branch stores the
// local itself -- a cut in a branch is then the local's own.
i64 vw_nread(i64 n, uptr name) {
    i64 c = 0;
    loop {
        if (!n) break;
        if (nd_kind(n) == N_IDENT && str_eq(nd_name(n), name)) c = c + 1;
        c = c + vw_nread(nd_a(n), name) + vw_nread(nd_b(n), name) + vw_nread(nd_c(n), name) + vw_nread(nd_d(n), name);
        n = nd_next(n);
    }
    return c;
}
void vw_rename(i64 n, uptr from, uptr to) {
    loop {
        if (!n) break;
        if (nd_kind(n) == N_ASSIGN && str_eq(nd_name(n), from)) set_nd_name(n, to);
        vw_rename(nd_a(n), from, to);
        vw_rename(nd_b(n), from, to);
        vw_rename(nd_c(n), from, to);
        vw_rename(nd_d(n), from, to);
        n = nd_next(n);
    }
}
// does a branch cut the temporary (`t = substr(...)`)? Only then is the fold
// worth it: a conditional the local does not cut stays one store, which is
// what src/opt.mc's rope wants of its first.
i64 vw_hascut(i64 n, uptr t) {
    loop {
        if (!n) break;
        if (nd_kind(n) == N_ASSIGN && str_eq(nd_name(n), t) && ph_opt_is(nd_a(n), "php_substr")) return 1;
        if (vw_hascut(nd_a(n), t) || vw_hascut(nd_b(n), t) || vw_hascut(nd_c(n), t) || vw_hascut(nd_d(n), t)) return 1;
        n = nd_next(n);
    }
    return 0;
}
i64 vw_strvar(i64 body, uptr name) {
    i64 v = nd_a(body);
    loop {
        if (!v || nd_kind(v) != N_VAR) break;
        if (str_eq(nd_name(v), name)) return nd_type(v) == ty_pstr;
        v = nd_next(v);
    }
    return 0;
}
void vw_fold(i64 body, i64 s) {
    loop {
        if (!s) break;
        i64 k = nd_kind(s);
        i64 a = nd_next(s);
        if (k == N_IF && a && nd_kind(a) == N_ASSIGN && nd_kind(nd_a(a)) == N_IDENT) {
            uptr t = nd_name(nd_a(a));
            uptr v = nd_name(a);
            if (ph_ext_pfx(t, "phq_") && vw_strvar(body, t) && vw_strvar(body, v)
                && vw_nread(nd_a(body), t) == 1 && (vw_hascut(nd_b(s), t) || vw_hascut(nd_c(s), t))) {
                vw_rename(nd_b(s), t, v);
                vw_rename(nd_c(s), t, v);
                set_nd_next(s, nd_next(a));
                a = nd_next(s);
            }
        }
        if (k == N_BLOCK) vw_fold(body, nd_a(s));
        if (k == N_IF) { vw_fold(body, nd_b(s)); vw_fold(body, nd_c(s)); }
        s = a;
    }
}

// ---- the rewrite
i64 vw_list(i64 s);
// one node (its nd_next is the caller's); answers its replacement, which may
// be a list of statements for a store
i64 vw_one(i64 n) {
    i64 k = nd_kind(n);
    if (k == N_IDENT && vw_is(n))
        return vw_call("php_vstr", ty_pstr, vw_win3());
    if (k == N_ASSIGN && str_eq(nd_name(n), vw_v)) {
        if (vw_is_cut(n)) {
            i64 c = nd_a(n);
            i64 b = nd_a(c);
            i64 st = nd_next(b);
            i64 ln = nd_next(st);
            i64 has = nd_next(ln);
            set_nd_next(b, 0);
            set_nd_next(st, 0);
            set_nd_next(ln, 0);
            st = vw_list(st);
            ln = vw_list(ln);
            if (!nd_val(has)) ln = ph_opt_imax(vw_ln, vw_fl);
            // the start and the length once, then the window: of itself, or
            // of the string X names
            ph_nonce = ph_nonce + 1;
            uptr ts = p_cat("phvw_t", php_dec(ph_nonce), 0, cstrlen(php_dec(ph_nonce)));
            uptr tl = p_cat("phvw_u", php_dec(ph_nonce), 0, cstrlen(php_dec(ph_nonce)));
            uptr ts2 = p_cat("phvw_o", php_dec(ph_nonce), 0, cstrlen(php_dec(ph_nonce)));
            phi_declare(ts, TY_I64, vw_ln, vw_fl);
            phi_declare(tl, TY_I64, vw_ln, vw_fl);
            phi_declare(ts2, TY_I64, vw_ln, vw_fl);
            i64 a1 = ph_set(ts, st);
            i64 a2 = ph_set(tl, ln);
            i64 n0 = 0;                                // the length cut from
            i64 hd = a1;
            set_nd_next(a1, a2);
            i64 tl2 = a2;
            if (vw_is(b)) {
                n0 = vw_id(vw_l, TY_I64);
            } else {
                i64 sb = ph_set(vw_b, b);
                set_nd_next(tl2, sb);
                tl2 = sb;
                i64 z = ph_set(vw_s, vw_int(0));
                set_nd_next(tl2, z);
                tl2 = z;
                i64 ad = ph_bin(ph_tok("+", 1), vw_id(vw_b, TY_UPTR), vw_int(16), TY_UPTR);
                n0 = vw_call("ld64", TY_I64, ad);
            }
            i64 o = ph_set(ts2, vw_call("php_win_st", TY_I64, vw_args(n0, vw_id(ts, TY_I64), 0, 0, 0, 0)));
            set_nd_next(tl2, o);
            i64 n1 = 0;
            if (vw_is(b)) n1 = vw_id(vw_l, TY_I64);
            else n1 = vw_call("ld64", TY_I64, ph_bin(ph_tok("+", 1), vw_id(vw_b, TY_UPTR), vw_int(16), TY_UPTR));
            i64 l = ph_set(vw_l, vw_call("php_win_ln", TY_I64, vw_args(n1, vw_id(ts, TY_I64), vw_id(tl, TY_I64), 0, 0, 0)));
            set_nd_next(o, l);
            i64 sv = ph_set(vw_s, ph_bin(ph_tok("+", 1), vw_id(vw_s, TY_I64), vw_id(ts2, TY_I64), TY_I64));
            set_nd_next(l, sv);
            return hd;
        }
        // any other value: the window is all of it -- or, when the value is
        // itself a window made a string, that window
        i64 v = vw_list(nd_a(n));
        if (ph_opt_is(v, "php_vstr")) {
            i64 vb = nd_a(v);
            i64 vs = nd_next(vb);
            i64 vl = nd_next(vs);
            set_nd_next(vb, 0);
            set_nd_next(vs, 0);
            i64 a1 = ph_set(vw_b, vb);
            i64 a2 = ph_set(vw_s, vs);
            i64 a3 = ph_set(vw_l, vl);
            set_nd_next(a1, a2);
            set_nd_next(a2, a3);
            return a1;
        }
        i64 a1 = ph_set(vw_b, v);
        i64 a2 = ph_set(vw_s, vw_int(0));
        i64 a3 = ph_set(vw_l, vw_call("ld64", TY_I64, ph_bin(ph_tok("+", 1), vw_id(vw_b, TY_UPTR), vw_int(16), TY_UPTR)));
        set_nd_next(a1, a2);
        set_nd_next(a2, a3);
        return a1;
    }
    if (k == N_CALL && vw_is_len(n)) return vw_id(vw_l, TY_I64);
    if (k == N_CALL && vw_is_winread(n)) {
        uptr c = nd_name(n);
        i64 rest = vw_list(nd_next(nd_a(n)));
        if (str_eq(c, "php_str_byte_c") || str_eq(c, "php_str_off_c")) {
            i64 ix = ph_bin(ph_tok("+", 1), vw_id(vw_s, TY_I64), rest, TY_I64);
            return vw_call(c, nd_type(n), vw_args(vw_id(vw_b, TY_UPTR), ix, 0, 0, 0, 0));
        }
        uptr nm = "php_substr_v";
        if (str_eq(c, "php_spn_r")) nm = "php_spn_rv";
        if (str_eq(c, "php_spn_o")) nm = "php_spn_ov";
        i64 w = vw_win3();
        set_nd_next(phi_last(w), rest);
        return vw_call(nm, nd_type(n), w);
    }
    set_nd_a(n, vw_list(nd_a(n)));
    set_nd_b(n, vw_list(nd_b(n)));
    set_nd_c(n, vw_list(nd_c(n)));
    set_nd_d(n, vw_list(nd_d(n)));
    return n;
}
i64 vw_list(i64 s) {
    i64 h = 0;
    i64 t = 0;
    loop {
        if (!s) break;
        i64 nx = nd_next(s);
        set_nd_next(s, 0);
        i64 r = vw_one(s);
        if (t) set_nd_next(t, r);
        if (!t) h = r;
        t = phi_last(r);
        s = nx;
    }
    return h;
}

i64 vw_isparam(i64 f, uptr name) {
    i64 p = nd_a(f);
    loop { if (!p) break; if (str_eq(nd_name(p), name)) return 1; p = nd_next(p); }
    return 0;
}

void ph_view_fn(i64 f) {
    if (phi_off) return;
    i64 body = nd_b(f);
    if (!body) return;
    if (ph_rc_has_loop(nd_a(body))) return;
    vw_fold(body, nd_a(body));
    i64 v = nd_a(body);
    loop {
        if (!v || nd_kind(v) != N_VAR) break;
        i64 nv = nd_next(v);
        if (nd_type(v) == ty_pstr && !nd_val(v) && !nd_a(v) && !vw_isparam(f, nd_name(v))) {
            vw_v = nd_name(v);
            vw_nsub = 0;
            vw_noth = 0;
            vw_nst = 0;
            vw_nvc = 0;
            vw_bad = 0;
            vw_xw = 0;
            vw_xc = VW_NEG;
            vw_mw = 0;
            vw_mc = VW_POS;
            vw_xr = VW_NEG;
            vw_mr = VW_POS;
            vw_ifd = 0;
            vw_flow(nd_a(body));
            i64 most = vw_max(vw_xr, vw_max(vw_xw, vw_xc));
            i64 least = vw_min(vw_mr, vw_min(vw_mw, vw_mc));
            if (!vw_bad && vw_nsub > 0 && most <= 0 && least < 0) {
                vw_ln = nd_line(v);
                vw_fl = nd_file(v);
                vw_b = p_cat("phvw_b_", vw_v, 0, cstrlen(vw_v));
                vw_s = p_cat("phvw_s_", vw_v, 0, cstrlen(vw_v));
                vw_l = p_cat("phvw_l_", vw_v, 0, cstrlen(vw_v));
                phi_vh = 0;
                phi_vt = 0;
                phi_declare(vw_b, TY_UPTR, vw_ln, vw_fl);
                phi_declare(vw_s, TY_I64, vw_ln, vw_fl);
                phi_declare(vw_l, TY_I64, vw_ln, vw_fl);
                // the whole list, declarations' initialisers included (a
                // declaration is its own node again, so the walk continues)
                set_nd_a(body, vw_list(nd_a(body)));
                // the new declarations ahead of the rest
                set_nd_next(phi_vt, nd_a(body));
                set_nd_a(body, phi_vh);
                phi_vh = 0;
                phi_vt = 0;
            }
        }
        v = nv;
    }
}

// ---- the runtime's small leaf routines are inlined too -------------------------
// After src/rc.mc, a compiled function still calls lib/php_rt.mc for the
// smallest operations -- a string offset's byte, a packed array element, an
// overflow-checked add -- and each call costs a prologue, an epilogue and the
// caller's live registers saved around it, several times what the operation
// does. These routines are written as a FAST PATH that calls nothing plus a
// call to the general routine for the rest, and the same copy the php
// inliner makes (phi_expand) puts them into the caller. It runs here, after
// the counting pass, because two of them (php_str_sets_own, php_str_setb_own)
// only exist after it; none of them returns a string the caller counts.
//
// The runtime is parsed before the php source (src/program.mc pushes it
// first), so decl_find reaches each finished function. A routine the scan
// refuses, or one this runtime does not have, is simply left a call.
uptr phr_name;
uptr phr_fn_;
i64  phr_n;
i64  phr_done;

void phr_add(uptr name) {
    i64 d = decl_find(name);
    if (d < 0) return;
    if (nd_kind(d) != N_FUNC || !nd_b(d)) return;
    phi_size = 0;
    phi_bad = 0;
    phi_rt = 1;
    phi_scan(d, nd_b(d));
    phi_rt = 0;
    if (phi_bad || phi_size > PHI_MAXN) return;
    st64(phr_name + phr_n * 8, name);
    st64(phr_fn_ + phr_n * 8, phi_copy1(d));
    phr_n = phr_n + 1;
}

void phr_init() {
    phr_done = 1;
    phr_name = xalloc(32 * 8);
    phr_fn_ = xalloc(32 * 8);
    phr_add("php_str_byte");
    phr_add("php_str_sets_own");
    phr_add("php_str_setb_own");
    phr_add("php_str_setb_f");
    phr_add("php_str_setb_n");
    phr_add("php_arr_mv");
    phr_add("php_str_byte_c");
    phr_add("php_str_byte_d");
    phr_add("php_pk_get_c");
    phr_add("php_pk_get_d");
    phr_add("php_pk_set");
    phr_add("php_pk_get_f");
    phr_add("php_pk_set_f");
    phr_add("php_pk_ea");
    phr_add("php_intdiv");
    phr_add("php_mod");
    phr_add("php_rc_ret");
    phr_add("phx_enter");
    phr_add("phx_leave");
    phr_add("phx_zarg_rov");
    phr_add("php_rope_v");
}

// ---- the position and the unwinding check go where a call can raise ---------
// A php statement that can raise is announced (ph_dfile/ph_dline, stored
// before it) and checked (`if (ph_exc) unwind`, after each part of it). Once
// the runtime's fast paths are copied in, the only calls such a statement may
// still make are often the slow halves of those copies -- the out-of-range
// read, the overflow -- each inside an `if`. Two rewrites, in order:
//
//  1. the announcement moves INTO those branches, before the slow call, and
//     a copy of the statement's check follows the call there -- when every
//     call the statement makes is in such a branch (no nested php statement,
//     no loop, no call outside an if). An announcement nothing after it can
//     raise under is dropped.
//  2. a check is dropped where nothing since the last check can have raised:
//     `pend`, carried through the function in the order it runs, says
//     whether a call that can raise ran since the last check did.
//
// The path that raises is announced and checked as before; the path that
// cannot pays for neither. Checking right after the call is also closer to
// php: an exception stops the expression there.

// `if (!!ph_exc) <unwind>`, and the unwind really leaves: a return, a break
// to a catch, php_uncaught at the top level. An inlined copy's own check only
// sets its answer and its done-flag, and is not one.
i64 phr_leaves(i64 b) {
    i64 l = phi_last(phi_blist(b));
    if (!l) return 0;
    i64 k = nd_kind(l);
    if (k == N_RETURN || k == N_BREAK) return 1;
    if (k == N_BLOCK) return phr_leaves(l);
    if (k == N_EXPRSTMT && nd_kind(nd_a(l)) == N_CALL && str_eq(nd_name(nd_a(l)), "php_uncaught")) return 1;
    return 0;
}

i64 phr_is_check(i64 s) {
    if (nd_kind(s) != N_IF || nd_c(s)) return 0;
    i64 c = nd_a(s);
    if (nd_kind(c) != N_UNARY) return 0;
    c = nd_a(c);
    if (nd_kind(c) != N_UNARY) return 0;
    c = nd_a(c);
    if (nd_kind(c) != N_IDENT || !str_eq(nd_name(c), "ph_exc")) return 0;
    return phr_leaves(nd_b(s));
}

// a call that cannot raise: the counting's own, and mc's loads and stores
i64 phr_quiet_call(uptr nm) {
    if (phi_intrinsic(nm) || str_eq(nm, "ph_addm64")) return 1;
    return str_eq(nm, "php_str_free") || str_eq(nm, "php_pool_push") || str_eq(nm, "php_rc_drain");
}

// anything that stops the move: an announcement or a loop anywhere inside
i64 phr_nested(i64 n) {
    loop {
        if (!n) break;
        if (nd_kind(n) == N_LOOP) return 1;
        if (nd_kind(n) == N_ASSIGN && (str_eq(nd_name(n), "ph_dfile") || str_eq(nd_name(n), "ph_dline"))) return 1;
        if (phr_nested(nd_a(n)) || phr_nested(nd_b(n)) || phr_nested(nd_c(n)) || phr_nested(nd_d(n))) return 1;
        n = nd_next(n);
    }
    return 0;
}

// a raising call anywhere in n (the list from n on); a check's own unwinding
// is not looked into
i64 phr_calls(i64 n) {
    loop {
        if (!n) break;
        if (nd_kind(n) == N_CALL && !phr_quiet_call(nd_name(n))) return 1;
        if (!phr_is_check(n)) {
            if (phr_calls(nd_a(n)) || phr_calls(nd_b(n)) || phr_calls(nd_c(n)) || phr_calls(nd_d(n))) return 1;
        }
        n = nd_next(n);
    }
    return 0;
}
i64 phr_calls1(i64 n) {
    if (!n) return 0;
    i64 nx = nd_next(n);
    set_nd_next(n, 0);
    i64 r = phr_calls(n);
    set_nd_next(n, nx);
    return r;
}

// a raising call reached whether or not any if is taken (one node and what
// hangs under it, not its successors)
i64 phr_uncond1(i64 n);
i64 phr_uncond(i64 n) {
    loop {
        if (!n) break;
        if (phr_uncond1(n)) return 1;
        n = nd_next(n);
    }
    return 0;
}
i64 phr_uncond1(i64 n) {
    if (!n) return 0;
    i64 k = nd_kind(n);
    if (k == N_IF) return phr_uncond(nd_a(n));
    if (k == N_CALL && !phr_quiet_call(nd_name(n))) return 1;
    return phr_uncond(nd_a(n)) || phr_uncond(nd_b(n)) || phr_uncond(nd_c(n)) || phr_uncond(nd_d(n));
}

i64 phr_wrap(i64 br, i64 ann, i64 chk, i64 line, uptr fl) {
    i64 l = phi_blist(br);
    if (chk) l = phi_cat(l, phi_copy1(chk));
    if (ann) l = phi_cat(phi_copy1(ann), l);
    return phi_block(l, line, fl);
}

// the announcement and the check into every branch that makes a call
// whichever way its own ifs go -- the innermost such branch, so a path with
// no call is never checked
i64 phr_branch(i64 br, i64 ann, i64 chk, i64 line, uptr fl);
void phr_move(i64 s, i64 ann, i64 chk) {
    loop {
        if (!s) break;
        i64 k = nd_kind(s);
        if (k == N_BLOCK) phr_move(nd_a(s), ann, chk);
        if (k == N_IF && !phr_is_check(s)) {
            if (nd_b(s)) set_nd_b(s, phr_branch(nd_b(s), ann, chk, nd_line(s), nd_file(s)));
            if (nd_c(s)) set_nd_c(s, phr_branch(nd_c(s), ann, chk, nd_line(s), nd_file(s)));
        }
        s = nd_next(s);
    }
}
i64 phr_branch(i64 br, i64 ann, i64 chk, i64 line, uptr fl) {
    if (!phr_calls(br)) return br;
    if (phr_uncond(phi_blist(br))) return phr_wrap(br, ann, chk, line, fl);
    phr_move(phi_blist(br), ann, chk);
    return br;
}

// rewrite 1 for one php statement: `ann` and its parts up to the next
// announcement. Answers the new list for it.
i64 phr_group(i64 ann, i64 h) {
    i64 chk = 0;
    i64 ok = 1;
    i64 any = 0;
    i64 p = h;
    loop {
        if (!p) break;
        if (phr_is_check(p)) { if (!chk) chk = p; }
        if (!phr_is_check(p)) {
            if (phr_nested(p) || phr_uncond1(p)) ok = 0;
            if (phr_calls1(p)) any = 1;
        }
        p = nd_next(p);
    }
    if (!any) return h;                           // nothing raises under it
    if (!ok) {
        if (!ann) return h;
        set_nd_next(ann, h);
        return ann;
    }
    phr_move(h, ann, chk);
    return h;
}

i64 phr_ann(i64 s) {
    i64 p = s;
    loop {
        if (!p) break;
        i64 k = nd_kind(p);
        if (k == N_BLOCK && !phi_is_ann(p)) set_nd_a(p, phr_ann(nd_a(p)));
        if (k == N_LOOP) set_nd_a(p, phr_ann(nd_a(p)));
        if (k == N_IF && !phr_is_check(p)) {
            if (nd_b(p)) set_nd_b(p, phi_block(phr_ann(phi_blist(nd_b(p))), nd_line(p), nd_file(p)));
            if (nd_c(p)) set_nd_c(p, phi_block(phr_ann(phi_blist(nd_c(p))), nd_line(p), nd_file(p)));
        }
        p = nd_next(p);
    }
    i64 h = 0;
    i64 t = 0;
    i64 ann = 0;
    i64 gh = 0;
    i64 gt = 0;
    p = s;
    loop {
        i64 nx = 0;
        if (p) { nx = nd_next(p); set_nd_next(p, 0); }
        if (!p || phi_is_ann(p)) {
            i64 g = phr_group(ann, gh);
            if (g) {
                if (t) set_nd_next(t, g);
                if (!t) h = g;
                t = phi_last(g);
            }
            if (!p) break;
            ann = p;
            gh = 0;
            gt = 0;
        } else {
            if (gt) set_nd_next(gt, p);
            if (!gt) gh = p;
            gt = p;
        }
        p = nx;
    }
    return h;
}

// rewrite 2: the list, run with `pend` on entry; answers the list and leaves
// the pend on exit in phr_pend. `dry` computes without rewriting.
i64 phr_pend;

i64 phr_has_cont(i64 n) {
    loop {
        if (!n) break;
        if (nd_kind(n) == N_CONTINUE) return 1;
        if (phr_has_cont(nd_a(n)) || phr_has_cont(nd_b(n)) || phr_has_cont(nd_c(n))) return 1;
        n = nd_next(n);
    }
    return 0;
}

i64 phr_chk(i64 s, i64 pend, i64 dry) {
    i64 h = 0;
    i64 t = 0;
    loop {
        if (!s) break;
        i64 nx = nd_next(s);
        i64 keep = 1;
        i64 k = nd_kind(s);
        if (phr_is_check(s)) {
            if (!pend) keep = 0;
            pend = 0;
        } else if (k == N_IF) {
            if (phr_uncond(nd_a(s))) pend = 1;
            i64 pb = pend;
            i64 po = pend;
            if (nd_b(s)) {
                i64 b = phr_chk(phi_blist(nd_b(s)), pb, dry);
                if (!dry) set_nd_b(s, phi_block(b, nd_line(s), nd_file(s)));
                po = phr_pend;
            }
            i64 pc = pb;
            if (nd_c(s)) {
                i64 c = phr_chk(phi_blist(nd_c(s)), pb, dry);
                if (!dry) set_nd_c(s, phi_block(c, nd_line(s), nd_file(s)));
                pc = phr_pend;
            }
            pend = po | pc;
        } else if (k == N_LOOP) {
            i64 pin = pend;
            if (phr_has_cont(nd_a(s))) { if (phr_calls(nd_a(s))) pin = 1; }
            else { phr_chk(nd_a(s), pend, 1); pin = pend | phr_pend; }
            i64 b = phr_chk(nd_a(s), pin, dry);
            if (!dry) set_nd_a(s, b);
            if (phr_calls(nd_a(s))) pend = 1;
        } else if (k == N_BLOCK) {
            i64 b = phr_chk(nd_a(s), pend, dry);
            if (!dry) set_nd_a(s, b);
            pend = phr_pend;
        } else {
            if (phr_calls1(s)) pend = 1;
        }
        if (dry || keep) {
            if (!dry) {
                if (t) set_nd_next(t, s);
                if (!t) h = s;
                t = s;
            }
        }
        s = nx;
    }
    if (!dry && t) set_nd_next(t, 0);
    phr_pend = pend;
    return h;
}

i64 phr_lazy(i64 s) {
    s = phr_ann(s);
    return phr_chk(s, 0, 0);
}

// ---- one unwinding tail per function ---------------------------------------
// Every check a function keeps (`if (ph_exc) <unwind>`) carries the whole
// unwind: every counted slot released, the pool drained, the default answer
// returned -- forty-odd instructions, the same ones each time. They are never
// run on the path that does not raise, but mc lays them out beside it and its
// register allocator counts the locals they name like any others, so the
// function's hot variables lose registers to code that almost never runs.
// The body goes into a `loop { ... }` that the normal path always leaves by
// its own return, each check becomes `break` out of it (as many levels as
// the loops around the check, plus that one), and ONE copy of the unwind
// follows the loop.
// does the unwind end in a return (and not a break to a catch)?
i64 phr_rets(i64 b) {
    i64 l = phi_last(phi_blist(b));
    if (!l) return 0;
    if (nd_kind(l) == N_BLOCK) return phr_rets(l);
    return nd_kind(l) == N_RETURN;
}
i64 phr_brk(i64 s, i64 depth, i64 line, uptr fl) {
    loop {
        if (!s) break;
        i64 k = nd_kind(s);
        if (phr_is_check(s)) {
            if (phr_rets(nd_b(s))) {
                i64 b = node_new(N_BREAK, line, fl);
                set_nd_val(b, depth + 1);
                set_nd_b(s, b);
            }
        } else {
            i64 d = depth;
            if (k == N_LOOP) d = depth + 1;
            phr_brk(nd_a(s), d, line, fl);
            phr_brk(nd_b(s), d, line, fl);
            phr_brk(nd_c(s), d, line, fl);
            phr_brk(nd_d(s), d, line, fl);
        }
        s = nd_next(s);
    }
    return 0;
}

// the checks that unwind by returning, counted; the first one's unwind kept
i64 phr_tailb;
i64 phr_count_ret(i64 s) {
    i64 n = 0;
    loop {
        if (!s) break;
        if (phr_is_check(s)) {
            if (phr_rets(nd_b(s))) {
                if (!phr_tailb) phr_tailb = nd_b(s);
                n = n + 1;
            }
        } else {
            n = n + phr_count_ret(nd_a(s)) + phr_count_ret(nd_b(s)) + phr_count_ret(nd_c(s)) + phr_count_ret(nd_d(s));
        }
        s = nd_next(s);
    }
    return n;
}

void phr_tail(i64 f) {
    i64 body = nd_b(f);
    i64 line = nd_line(f);
    uptr fl = nd_file(f);
    phr_tailb = 0;
    if (phr_count_ret(nd_a(body)) < 2) return;
    // the declarations stay ahead of the loop (the unwind names them); one
    // that comes after a statement is split into its declaration and a store
    i64 vh = 0;
    i64 vt = 0;
    i64 rh = 0;
    i64 rt = 0;
    i64 s = nd_a(body);
    loop {
        if (!s) break;
        i64 nx = nd_next(s);
        set_nd_next(s, 0);
        i64 put = s;
        if (nd_kind(s) == N_VAR) {
            if (rh && nd_a(s)) {
                i64 d = node_new(N_VAR, nd_line(s), nd_file(s));
                set_nd_name(d, nd_name(s));
                set_nd_type(d, nd_type(s));
                put = phi_st(nd_name(s), nd_a(s), nd_line(s), nd_file(s));
                s = d;
            } else put = 0;
            if (vt) set_nd_next(vt, s);
            if (!vt) vh = s;
            vt = s;
        }
        if (put) {
            if (rt) set_nd_next(rt, put);
            if (!rt) rh = put;
            rt = put;
        }
        s = nx;
    }
    // the path that does not raise must never reach the unwind
    // (A function that falls off its end has raised php's `none returned`
    // there and unwound at the check after it, so the return added for a
    // valued one is never run; it only keeps the unwind out of reach.)
    if (!rt || !phr_rets(phi_block(rt, line, fl))) {
        i64 r = node_new(N_RETURN, line, fl);
        if (nd_type(f) != TY_VOID) set_nd_a(r, ph_cast(nd_type(f), phi_i(0, line, fl)));
        if (rt) set_nd_next(rt, r);
        if (!rt) rh = r;
        rt = r;
    }
    i64 tail = phi_copy1(phr_tailb);
    phr_brk(rh, 0, line, fl);
    i64 lp = node_new(N_LOOP, line, fl);
    set_nd_a(lp, phi_block(rh, line, fl));
    set_nd_next(lp, phi_blist(tail));
    if (vt) { set_nd_next(vt, lp); set_nd_a(body, vh); }
    if (!vt) set_nd_a(body, lp);
}

// ---- a loop that builds nothing does not drain -------------------------------
// src/rc.mc drains the pool at the top of every iteration: `if (ph_pn >
// ph_pm) php_rc_drain(ph_pm)`, a load and a compare each time round. A loop
// whose every call is PROVEN to add nothing to the pool has nothing to drain,
// so the test is dropped there. Proven means: mc's loads and stores, the
// counting's own releases, and a slow half that can only THROW -- the throw
// leaves the loop through the unwinding, which drains. A slow half that can
// raise a diagnostic is not one: the diagnostic's text is built (php_mi ->
// php_itos) in the pool, so an out-of-range read repeated in a loop grew the
// pool by one string an iteration (tests/ext.sh step 12b), and
// neither is anything that copies a string or calls the counting's push.
i64 phr_throws_only(uptr nm) {
    return str_eq(nm, "php_intdiv_slow") || str_eq(nm, "php_str_setb_f_slow");
}

i64 phr_builds(i64 n) {
    loop {
        if (!n) break;
        if (nd_kind(n) == N_CALL && (str_eq(nd_name(n), "php_pool_push")
            || (!phr_quiet_call(nd_name(n)) && !phr_throws_only(nd_name(n))))) return 1;
        if (!phr_is_check(n)) {
            if (phr_builds(nd_a(n)) || phr_builds(nd_b(n)) || phr_builds(nd_c(n)) || phr_builds(nd_d(n))) return 1;
        }
        n = nd_next(n);
    }
    return 0;
}

i64 phr_is_drain(i64 s) {
    if (nd_kind(s) != N_IF || nd_c(s)) return 0;
    i64 c = nd_a(s);
    if (nd_kind(c) != N_BINARY || nd_kind(nd_a(c)) != N_IDENT || !str_eq(nd_name(nd_a(c)), "ph_pn")) return 0;
    i64 b = phi_blist(nd_b(s));
    if (!b || nd_next(b)) return 0;
    if (nd_kind(b) == N_EXPRSTMT) b = nd_a(b);
    return nd_kind(b) == N_CALL && str_eq(nd_name(b), "php_rc_drain");
}

void phr_nodrain(i64 s) {
    loop {
        if (!s) break;
        if (nd_kind(s) == N_LOOP && nd_kind(nd_a(s)) == N_BLOCK) {
            i64 b = nd_a(s);
            i64 first = nd_a(b);
            if (first && phr_is_drain(first) && !phr_builds(nd_next(first))) set_nd_a(b, nd_next(first));
        }
        if (!phr_is_check(s)) {
            phr_nodrain(nd_a(s));
            phr_nodrain(nd_b(s));
            phr_nodrain(nd_c(s));
        }
        s = nd_next(s);
    }
}

void phr_fn(i64 f) {
    if (phi_off) return;
    if (!phr_done) phr_init();
    if (!phr_n) return;
    i64 body = nd_b(f);
    if (!body) return;
    // the runtime's list in place of the php one, for this pass only
    uptr sn = phi_name;
    uptr sf = phi_fn;
    i64 sk = phi_n;
    phi_name = phr_name;
    phi_fn = phr_fn_;
    phi_n = phr_n;
    phi_cf = f;
    phi_vh = 0;
    phi_vt = 0;
    phi_rtpass = 1;
    set_nd_a(body, phi_list(nd_a(body)));
    phi_rtpass = 0;
    phi_drop = 0;
    set_nd_a(body, phr_lazy(nd_a(body)));
    phr_nodrain(nd_a(body));
    phr_tail(f);
    if (phi_vh) { set_nd_next(phi_vt, nd_a(body)); set_nd_a(body, phi_vh); }
    phi_cf = 0;
    phi_name = sn;
    phi_fn = sf;
    phi_n = sk;
}

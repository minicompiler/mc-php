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

void phi_env() {
    uptr e = host_environ();
    if (!e) return;
    i64 i = 0;
    loop {
        uptr s = ld64(e + i * 8);
        if (!s) return;
        if (str_eq(s, "MCPHP_INLINE=0")) { phi_off = 1; return; }
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

void phi_scan(i64 f, i64 s) {
    loop {
        if (!s) break;
        phi_size = phi_size + 1;
        i64 k = nd_kind(s);
        if (k == N_LOOP || k == N_BREAK || k == N_CONTINUE || k == N_ADDR || k == N_HOLE
            || k == N_FUNC || k == N_GLOBAL || k == N_BLOB || k == N_INDEX) phi_bad = 1;
        if (k == N_VAR && nd_val(s)) phi_bad = 1;
        if (k == N_ASSIGN && !str_eq(nd_name(s), "ph_dfile") && !str_eq(nd_name(s), "ph_dline")
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
    i64 p = nd_a(fc);
    i64 a = nd_a(c);
    loop {
        if (!p) break;
        i64 an = nd_next(a);
        set_nd_next(a, 0);
        uptr pn = nd_name(p);
        if (nd_kind(a) == N_IDENT && nd_type(a) == nd_type(p) && phi_local_of_caller(nd_name(a))
            && !ph_rc_assigned(body, pn)) {
            phi_rn_add(pn, nd_name(a));
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
    body = phi_hoist(body);
    uptr rv = 0;
    if (nd_type(fc) != TY_VOID) {
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

i64 phi_is_ann(i64 s) {
    if (nd_kind(s) != N_BLOCK) return 0;
    i64 a = nd_a(s);
    if (!a) return 0;
    return nd_kind(a) == N_ASSIGN && str_eq(nd_name(a), "ph_dfile");
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
    phi_size = 0;
    phi_bad = 0;
    phi_scan(f, body);
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
    st64(phi_fn + phi_n * 8, phi_copy1(f));
    phi_n = phi_n + 1;
}

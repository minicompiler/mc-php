// tls.mc -- the compiled code's half of the thread block (lib/php_rt.mc
// § the thread block, lib/php_tls.mc its layout).
//
// The code this compiler writes names a few of the runtime's per-thread
// words the way it always did -- `ph_exc` after a call that can throw,
// `ph_dfile`/`ph_dline` for the position, `ph_pn`/`ph_pool`/`ph_pcap` for the
// string pool, `phx_lz` in an extension's handler -- because src/opt.mc and
// src/rc.mc recognise those shapes by name. They are lowered HERE, once the
// unit is parsed and optimised, into loads and stores off the function's
// thread block: every name becomes `ld64(phT + PHT_name)`, every store
// `st64(phT + PHT_name, v)`, and a function that now names phT without
// declaring it opens with the runtime's own two lines,
//
//     uptr phT = ph_tcur; if (!phT) phT = ph_tslow();
//
// A runtime function copied in by src/opt.mc carries its own copy of those
// two lines under a renamed phT; every such copy is folded into the
// function's one phT here, so a handler that copies phx_enter and phx_leave
// asks for its block once and holds it in one register.
#include "../lib/php_tls.mc"

// the per-thread word a compiled name stands for, and its type; -1 for a
// name that is not one
i64 ph_tls_off(uptr n) {
    if (str_eq(n, "ph_exc")) return PHT_ph_exc;
    if (str_eq(n, "ph_dfile")) return PHT_ph_dfile;
    if (str_eq(n, "ph_dline")) return PHT_ph_dline;
    if (str_eq(n, "ph_pn")) return PHT_ph_pn;
    if (str_eq(n, "ph_pool")) return PHT_ph_pool;
    if (str_eq(n, "ph_pcap")) return PHT_ph_pcap;
    if (str_eq(n, "phx_lz")) return PHT_phx_lz;
    return 0 - 1;
}

i64 ph_tls_used;

i64 ph_tls_addr(i64 at, i64 off) {
    i64 t = node_new(N_IDENT, nd_line(at), nd_file(at));
    set_nd_name(t, "phT");
    set_nd_type(t, TY_UPTR);
    i64 o = node_new(N_INT, nd_line(at), nd_file(at));
    set_nd_val(o, off);
    set_nd_type(o, TY_I64);
    i64 b = node_new(N_BINARY, nd_line(at), nd_file(at));
    set_nd_op(b, ph_tok("+", 1));
    set_nd_a(b, t);
    set_nd_b(b, o);
    set_nd_type(b, TY_UPTR);
    ph_tls_used = 1;
    return b;
}

void ph_tls_walk(i64 n) {
    loop {
        if (!n) break;
        i64 k = nd_kind(n);
        i64 off = 0 - 1;
        if (k == N_IDENT || k == N_ASSIGN) off = ph_tls_off(nd_name(n));
        if (off >= 0 && k == N_IDENT) {
            i64 keep = nd_next(n);
            i64 ty = nd_type(n);
            i64 c = node_new(N_CALL, nd_line(n), nd_file(n));
            set_nd_name(c, "ld64");
            set_nd_a(c, ph_tls_addr(n, off));
            set_nd_type(c, TY_I64);
            i64 x = c;
            if (ty != TY_I64 && ty != 0) {
                x = node_new(N_CAST, nd_line(n), nd_file(n));
                set_nd_type(x, ty);
                set_nd_a(x, c);
            }
            node_assign(n, x);
            set_nd_next(n, keep);
        }
        if (off >= 0 && k == N_ASSIGN) {
            i64 keep = nd_next(n);
            ph_tls_walk(nd_a(n));
            i64 v = nd_a(n);
            i64 a = ph_tls_addr(n, off);
            set_nd_next(a, v);
            set_nd_next(v, 0);
            i64 c = node_new(N_CALL, nd_line(n), nd_file(n));
            set_nd_name(c, "st64");
            set_nd_a(c, a);
            set_nd_type(c, TY_VOID);
            i64 s = node_new(N_EXPRSTMT, nd_line(n), nd_file(n));
            set_nd_a(s, c);
            node_assign(n, s);
            set_nd_next(n, keep);
            n = keep;
            continue;
        }
        ph_tls_walk(nd_a(n));
        ph_tls_walk(nd_b(n));
        ph_tls_walk(nd_c(n));
        ph_tls_walk(nd_d(n));
        n = nd_next(n);
    }
}

// is phT declared among the function's own statements (a runtime function,
// already rewritten)?
i64 ph_tls_declared(i64 s) {
    loop {
        if (!s) break;
        if (nd_kind(s) == N_VAR && str_eq(nd_name(s), "phT")) return 1;
        s = nd_next(s);
    }
    return 0;
}

// the renamed phT of a copied runtime body (src/opt.mc): a local whose value
// is ph_tcur
uptr ph_tls_al;
i64  ph_tls_nal;
i64  ph_tls_alcap;
i64 ph_tls_is_alias(uptr n) {
    i64 i = 0;
    loop { if (i >= ph_tls_nal) break; if (str_eq(ld64(ph_tls_al + i * 8), n)) return 1; i = i + 1; }
    return 0;
}
i64 ph_tls_is_tmain(i64 v) { return v && nd_kind(v) == N_IDENT && str_eq(nd_name(v), "ph_tcur"); }
void ph_tls_alias_scan(i64 n) {
    loop {
        if (!n) break;
        i64 k = nd_kind(n);
        if ((k == N_ASSIGN || k == N_VAR) && ph_tls_is_tmain(nd_a(n)) && !str_eq(nd_name(n), "phT")
            && !ph_tls_is_alias(nd_name(n))) {
            if (ph_tls_nal == ph_tls_alcap) {
                i64 cap = ph_tls_alcap * 2 + 8;
                uptr a = xalloc(cap * 8);
                i64 i = 0;
                loop { if (i >= ph_tls_nal) break; st64(a + i * 8, ld64(ph_tls_al + i * 8)); i = i + 1; }
                ph_tls_al = a;
                ph_tls_alcap = cap;
            }
            st64(ph_tls_al + ph_tls_nal * 8, nd_name(n));
            ph_tls_nal = ph_tls_nal + 1;
        }
        ph_tls_alias_scan(nd_a(n));
        ph_tls_alias_scan(nd_b(n));
        ph_tls_alias_scan(nd_c(n));
        ph_tls_alias_scan(nd_d(n));
        n = nd_next(n);
    }
}
// a statement that only computed an alias's value goes (an empty block in
// its place), and every other use of the alias is phT
void ph_tls_empty(i64 n) {
    i64 keep = nd_next(n);
    i64 b = node_new(N_BLOCK, nd_line(n), nd_file(n));
    node_assign(n, b);
    set_nd_next(n, keep);
}
void ph_tls_alias_fix(i64 n) {
    loop {
        if (!n) break;
        i64 k = nd_kind(n);
        if ((k == N_ASSIGN || k == N_VAR) && ph_tls_is_alias(nd_name(n))) {
            if (k == N_VAR || ph_tls_is_tmain(nd_a(n))) { ph_tls_empty(n); n = nd_next(n); continue; }
        }
        // the `then` of a copied `if (ph_mt)` is its store, or a block of it
        i64 th = 0;
        if (k == N_IF) th = nd_b(n);
        if (th && nd_kind(th) == N_BLOCK && nd_a(th) && !nd_next(nd_a(th))) th = nd_a(th);
        if (k == N_IF && th && nd_kind(th) == N_ASSIGN && ph_tls_is_alias(nd_name(th))
            && nd_kind(nd_a(th)) == N_CALL && str_eq(nd_name(nd_a(th)), "ph_tslow")) {
            ph_tls_empty(n);
            n = nd_next(n);
            continue;
        }
        if ((k == N_IDENT || k == N_ASSIGN) && ph_tls_is_alias(nd_name(n))) {
            set_nd_name(n, "phT");
            ph_tls_used = 1;
        }
        ph_tls_alias_fix(nd_a(n));
        ph_tls_alias_fix(nd_b(n));
        ph_tls_alias_fix(nd_c(n));
        ph_tls_alias_fix(nd_d(n));
        n = nd_next(n);
    }
}

// `!x` for a pointer: mc's own 64-bit test
i64 ph_truthy_not(i64 x) {
    i64 u = node_new(N_UNARY, nd_line(x), nd_file(x));
    set_nd_op(u, ph_tok("!", 1));
    set_nd_a(u, x);
    set_nd_type(u, TY_U8);
    return u;
}

i64 ph_tls_pass(i64 root) {
    i64 f = root;
    loop {
        if (!f) break;
        if (nd_kind(f) == N_FUNC && nd_b(f)) {
            ph_tls_used = 0;
            ph_tls_nal = 0;
            ph_tls_alias_scan(nd_a(nd_b(f)));
            if (ph_tls_nal) ph_tls_alias_fix(nd_a(nd_b(f)));
            ph_tls_walk(nd_a(nd_b(f)));
            if (ph_tls_used && !ph_tls_declared(nd_a(nd_b(f)))) {
                i64 line = nd_line(f);
                uptr fl = nd_file(f);
                i64 m = node_new(N_IDENT, line, fl);
                set_nd_name(m, "ph_tcur");
                set_nd_type(m, TY_UPTR);
                i64 v = node_new(N_VAR, line, fl);
                set_nd_name(v, "phT");
                set_nd_type(v, TY_UPTR);
                set_nd_a(v, m);
                i64 t0 = node_new(N_IDENT, line, fl);
                set_nd_name(t0, "phT");
                set_nd_type(t0, TY_UPTR);
                i64 g = node_new(N_CALL, line, fl);
                set_nd_name(g, "ph_tslow");
                set_nd_type(g, TY_UPTR);
                i64 a = node_new(N_ASSIGN, line, fl);
                set_nd_name(a, "phT");
                set_nd_a(a, g);
                i64 iff = node_new(N_IF, line, fl);
                set_nd_a(iff, ph_truthy_not(t0));
                set_nd_b(iff, a);
                set_nd_next(v, iff);
                set_nd_next(iff, nd_a(nd_b(f)));
                set_nd_a(nd_b(f), v);
            }
        }
        f = nd_next(f);
    }
    return root;
}

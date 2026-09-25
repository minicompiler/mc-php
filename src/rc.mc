// rc.mc -- who owns a string: the pass that makes a php function count.
//
// On the EXTENSION road a string is a zend_string of its own with php's
// refcount (lib/php_rt.mc § who owns a string). The runtime counts what its
// containers hold; what a php FUNCTION holds is this file's. It runs over a
// function's mc tree once the lowering has built it, and rewrites:
//
//   * the TEMPORARIES a runtime call answered live on the runtime's pool, from
//     this function's entry mark (ph_pm) up. The top of every loop body drains
//     them, which is what bounds a loop: a temporary is dead once the
//     statement that used it is over, and anything a later statement still
//     reads is in a counted slot or in a container that took its own reference;
//   * in a function that LOOPS, every local of the string type (a php
//     variable, a string parameter the body assigns, the lowering's own string
//     temporaries) is a COUNTED SLOT: declared 0, and a store takes the new
//     value's reference -- the pool's own when it is the temporary on top --
//     and releases the old value's. `$s .= x`, `$s = $s . a . b` and
//     `$s[$i] = c` become php_str_append/appendv/setoff_own: php's in-place
//     write when nobody else holds the string. A parameter the body assigns
//     takes a reference at entry; one it never assigns is borrowed from the
//     caller, which keeps it alive for the call as php keeps an argument;
//   * a function with NO loop never drains before it returns, so its locals
//     BORROW from the pool and nothing is counted (ph_rc_counting);
//   * every return releases the slots and drains the pool first, the answer
//     kept: a string answer comes out on the CALLER's side of the pool, the
//     caller's temporary exactly like a runtime call's -- unless it is a
//     parameter the body never assigned, which the caller holds already.
//
// The take, the release and the pool push are WRITTEN IN PLACE, not called:
// calling them was 42% of examples/decimal's time when it was first measured.
//
// It is a pass over the finished tree and not a rule in each lowering because
// a store to a string local is built in a dozen places (an assignment, a
// foreach, list(), a catch, a static's copy, a try's saved return value, a
// pending statement a builtin asked for) and one missed store is a string
// freed under a live name. Here a store is an N_ASSIGN to a slot, wherever it
// was built.
//
// The PROGRAM road does not run it: every string there is the arena's and
// immutable, so the counting would be work that frees nothing. MCPHP_RC=check
// in the compiler's environment runs it there too, on `main` as well, the
// counting functions draining after EVERY statement rather than per loop
// iteration, and the runtime counts arena strings and POISONS one that
// reaches zero (ph_rcchk). That is the grading: the phpt grid and the
// fixtures, compiled that way, must answer exactly what they answer without
// it -- a string released under a live name reads back as a length no string
// has, or dies naming itself.

i64 ph_rcchk_mode;                  // MCPHP_RC=check, read once by user_init
uptr ph_rc_fl;                      // the function being rewritten: its file, line,
i64  ph_rc_ln;                      // and string slots
uptr ph_rc_slots;
i64  ph_rc_nslot;
i64  ph_rc_slotcap;
i64  ph_rc_fty;                     // its mc return type
uptr ph_rc_bor;                     // and its string parameters the body never
i64  ph_rc_nbor;                    // assigns: borrowed for the whole call

void ph_rc_env() {
    uptr e = host_environ();
    if (!e) return;
    i64 i = 0;
    loop {
        uptr s = ld64(e + i * 8);
        if (!s) return;
        if (str_eq(s, "MCPHP_RC=check")) { ph_rcchk_mode = 1; return; }
        i = i + 1;
    }
}

i64 ph_rc_on() { return ph_ext || ph_rcchk_mode; }

// ---- the nodes it builds ---------------------------------------------------
i64 ph_rc_id(uptr name, i64 ty) {
    i64 v = node_new(N_IDENT, ph_rc_ln, ph_rc_fl);
    set_nd_name(v, name);
    set_nd_type(v, ty);
    return v;
}

i64 ph_rc_int(i64 v) {
    i64 n = node_new(N_INT, ph_rc_ln, ph_rc_fl);
    set_nd_val(n, v);
    set_nd_type(n, TY_I64);
    return n;
}

i64 ph_rc_call(uptr name, i64 args, i64 ty) {
    i64 c = node_new(N_CALL, ph_rc_ln, ph_rc_fl);
    set_nd_name(c, name);
    set_nd_a(c, args);
    set_nd_type(c, ty);
    return c;
}

i64 ph_rc_stmt(i64 e) {
    i64 s = node_new(N_EXPRSTMT, ph_rc_ln, ph_rc_fl);
    set_nd_a(s, e);
    return s;
}

i64 ph_rc_set(uptr name, i64 v) {
    i64 a = node_new(N_ASSIGN, ph_rc_ln, ph_rc_fl);
    set_nd_name(a, name);
    set_nd_a(a, v);
    return a;
}

i64 ph_rc_block(i64 head) {
    i64 b = node_new(N_BLOCK, ph_rc_ln, ph_rc_fl);
    set_nd_a(b, head);
    return b;
}

// `if (ph_pn > ph_pm) php_rc_drain(ph_pm);` -- the load and the compare in
// place, the call only when this function has temporaries to drop
i64 ph_rc_drain() {
    i64 cond = node_new(N_BINARY, ph_rc_ln, ph_rc_fl);
    set_nd_op(cond, ph_tok(">", 1));
    set_nd_a(cond, ph_rc_id("ph_pn", TY_I64));
    set_nd_b(cond, ph_rc_id("ph_pm", TY_I64));
    set_nd_type(cond, TY_U8);
    i64 iff = node_new(N_IF, ph_rc_ln, ph_rc_fl);
    set_nd_a(iff, cond);
    set_nd_b(iff, ph_rc_stmt(ph_rc_call("php_rc_drain", ph_rc_id("ph_pm", TY_I64), TY_VOID)));
    return iff;
}

// ---- the counting, written in place ----------------------------------------
// A call per store and per release was 42% of examples/decimal's time the
// first time this was measured (sample, 6153 samples: php_str_release alone
// 11.6%, most of it mc's prologue and epilogue around a two-line test). The
// three sequences below are the runtime's php_rc_take, php_str_release and
// php_pool_push written into the function itself; the only call left is to
// php_str_free, when a count reaches zero, and to php_pool_push when the pool
// is full.
i64 ph_rc_bin(uptr op, i64 a, i64 b, i64 ty) {
    i64 n = node_new(N_BINARY, ph_rc_ln, ph_rc_fl);
    set_nd_op(n, ph_tok(op, cstrlen(op)));
    set_nd_a(n, a);
    set_nd_b(n, b);
    set_nd_type(n, ty);
    return n;
}

i64 ph_rc_if(i64 cond, i64 then, i64 els) {
    i64 f = node_new(N_IF, ph_rc_ln, ph_rc_fl);
    set_nd_a(f, cond);
    set_nd_b(f, then);
    set_nd_c(f, els);
    return f;
}

// ld32(name + off) / ld64(...)
i64 ph_rc_ld(uptr fn, i64 addr) { return ph_rc_call(fn, addr, TY_I64); }
i64 ph_rc_at(uptr name, i64 off) {
    return ph_rc_bin("+", ph_rc_id(name, TY_UPTR), ph_rc_int(off), TY_UPTR);
}

// a pointer test, `!!x` (node.mc's ph_truthy: never `(u8) x`)
i64 ph_rc_nz(uptr name) {
    i64 a = node_new(N_UNARY, ph_rc_ln, ph_rc_fl);
    set_nd_op(a, ph_tok("!", 1));
    set_nd_a(a, ph_rc_id(name, TY_UPTR));
    set_nd_type(a, TY_U8);
    i64 b = node_new(N_UNARY, ph_rc_ln, ph_rc_fl);
    set_nd_op(b, ph_tok("!", 1));
    set_nd_a(b, a);
    set_nd_type(b, TY_U8);
    return b;
}

// the string is counted: not IS_STR_INTERNED (64) in its type_info
i64 ph_rc_counted(uptr name) {
    i64 n = node_new(N_UNARY, ph_rc_ln, ph_rc_fl);
    set_nd_op(n, ph_tok("!", 1));
    set_nd_a(n, ph_rc_bin("&", ph_rc_ld("ld32", ph_rc_at(name, 4)), ph_rc_int(64), TY_I64));
    set_nd_type(n, TY_U8);
    return n;
}

// st32(name, ld32(name) + d)
i64 ph_rc_bump(uptr name, i64 d) {
    uptr op = "+";
    if (d < 0) { op = "-"; d = 0 - d; }
    i64 a0 = ph_rc_id(name, TY_UPTR);
    set_nd_next(a0, ph_rc_bin(op, ph_rc_ld("ld32", ph_rc_id(name, TY_UPTR)), ph_rc_int(d), TY_I64));
    return ph_rc_stmt(ph_rc_call("st32", a0, TY_VOID));
}

// if (name && counted(name)) { body }
i64 ph_rc_ifstr(uptr name, i64 body) {
    return ph_rc_if(ph_rc_nz(name), ph_rc_if(ph_rc_counted(name), body, 0), 0);
}

// release: if (ld32(v) > 1) st32(v, ld32(v) - 1); else php_str_free(v);
i64 ph_rc_release(uptr name) {
    i64 gt = ph_rc_bin(">", ph_rc_ld("ld32", ph_rc_id(name, TY_UPTR)), ph_rc_int(1), TY_U8);
    i64 fr = ph_rc_stmt(ph_rc_call("php_str_free", ph_rc_id(name, ty_pstr), TY_VOID));
    return ph_rc_ifstr(name, ph_rc_if(gt, ph_rc_bump(name, 0 - 1), fr));
}

// take: the temporary on top of the pool IS this string -- its reference
// moves over; else one more
//   if (ph_pn > 0) { if (ld64(ph_pool + ph_pn * 8 - 8) == v) ph_pn = ph_pn - 1; else INC }
//   else INC
i64 ph_rc_take(uptr name) {
    i64 slot = ph_rc_bin("-", ph_rc_bin("+", ph_rc_id("ph_pool", TY_UPTR),
                                        ph_rc_bin("*", ph_rc_id("ph_pn", TY_I64), ph_rc_int(8), TY_I64), TY_UPTR),
                         ph_rc_int(8), TY_UPTR);
    i64 top = ph_rc_bin("==", ph_rc_ld("ld64", slot), ph_rc_id(name, TY_UPTR), TY_U8);
    i64 pop = ph_rc_set("ph_pn", ph_rc_bin("-", ph_rc_id("ph_pn", TY_I64), ph_rc_int(1), TY_I64));
    i64 inner = ph_rc_if(top, pop, ph_rc_bump(name, 1));
    i64 has = ph_rc_bin(">", ph_rc_id("ph_pn", TY_I64), ph_rc_int(0), TY_U8);
    return ph_rc_ifstr(name, ph_rc_if(has, inner, ph_rc_bump(name, 1)));
}

// push: if (ph_pn < ph_pcap) { st64(ph_pool + ph_pn * 8, v); ph_pn = ph_pn + 1; } else php_pool_push(v);
i64 ph_rc_push(uptr name) {
    i64 room = ph_rc_bin("<", ph_rc_id("ph_pn", TY_I64), ph_rc_id("ph_pcap", TY_I64), TY_U8);
    i64 a0 = ph_rc_bin("+", ph_rc_id("ph_pool", TY_UPTR),
                       ph_rc_bin("*", ph_rc_id("ph_pn", TY_I64), ph_rc_int(8), TY_I64), TY_UPTR);
    set_nd_next(a0, ph_rc_id(name, TY_UPTR));
    i64 st = ph_rc_stmt(ph_rc_call("st64", a0, TY_VOID));
    set_nd_next(st, ph_rc_set("ph_pn", ph_rc_bin("+", ph_rc_id("ph_pn", TY_I64), ph_rc_int(1), TY_I64)));
    i64 slow = ph_rc_stmt(ph_rc_call("php_pool_push", ph_rc_id(name, ty_pstr), TY_VOID));
    return ph_rc_ifstr(name, ph_rc_if(room, ph_rc_block(st), slow));
}

// ---- the slots -------------------------------------------------------------
i64 ph_rc_is_slot(uptr name) {
    i64 i = 0;
    loop {
        if (i >= ph_rc_nslot) break;
        if (str_eq(ld64(ph_rc_slots + i * 8), name)) return 1;
        i = i + 1;
    }
    return 0;
}

void ph_rc_add_slot(uptr name) {
    if (ph_rc_is_slot(name)) return;
    if (ph_rc_nslot == ph_rc_slotcap) {
        i64 cap = ph_rc_slotcap * 2 + 32;
        uptr nb = xalloc(cap * 8);
        i64 i = 0;
        loop { if (i >= ph_rc_nslot) break; st64(nb + i * 8, ld64(ph_rc_slots + i * 8)); i = i + 1; }
        ph_rc_slots = nb;
        ph_rc_slotcap = cap;
    }
    st64(ph_rc_slots + ph_rc_nslot * 8, name);
    ph_rc_nslot = ph_rc_nslot + 1;
}

// every N_VAR of the string type, anywhere in the statement tree
void ph_rc_scan_vars(i64 s) {
    loop {
        if (!s) break;
        i64 k = nd_kind(s);
        if (k == N_VAR && nd_type(s) == ty_pstr) ph_rc_add_slot(nd_name(s));
        if (k == N_BLOCK) ph_rc_scan_vars(nd_a(s));
        if (k == N_LOOP) ph_rc_scan_vars(nd_a(s));
        if (k == N_IF) { ph_rc_scan_vars(nd_b(s)); ph_rc_scan_vars(nd_c(s)); }
        s = nd_next(s);
    }
}

// is `name` ever the target of an N_ASSIGN?
i64 ph_rc_assigned(i64 s, uptr name) {
    loop {
        if (!s) break;
        i64 k = nd_kind(s);
        if (k == N_ASSIGN && str_eq(nd_name(s), name)) return 1;
        if (k == N_BLOCK) { if (ph_rc_assigned(nd_a(s), name)) return 1; }
        if (k == N_LOOP) { if (ph_rc_assigned(nd_a(s), name)) return 1; }
        if (k == N_IF) {
            if (ph_rc_assigned(nd_b(s), name)) return 1;
            if (ph_rc_assigned(nd_c(s), name)) return 1;
        }
        s = nd_next(s);
    }
    return 0;
}

// every slot released: the statements, chained, and their tail through *tl
i64 ph_rc_releases(uptr tl) {
    i64 h = 0;
    i64 t = 0;
    i64 i = 0;
    loop {
        if (i >= ph_rc_nslot) break;
        i64 r = ph_rc_release(ld64(ph_rc_slots + i * 8));
        if (t) set_nd_next(t, r);
        if (!t) h = r;
        t = r;
        i = i + 1;
    }
    st64(tl, t);
    return h;
}

// ---- the rewrite -----------------------------------------------------------
i64 ph_rc_list(i64 s);
i64 ph_rc_is_param(uptr name);

i64 ph_rc_is_call(i64 v, uptr fname, uptr slot) {
    if (nd_kind(v) != N_CALL) return 0;
    if (!str_eq(nd_name(v), fname)) return 0;
    i64 a = nd_a(v);
    if (!a) return 0;
    if (nd_kind(a) != N_IDENT) return 0;
    return str_eq(nd_name(a), slot);
}

// `return E;` -> the slots released, the pool drained to the entry mark, the
// answer kept across both
i64 ph_rc_return(i64 r) {
    ph_rc_ln = nd_line(r);
    ph_rc_fl = nd_file(r);
    i64 e = nd_a(r);
    u8 tb[8];
    i64 h = 0;
    i64 t = 0;
    i64 str = e && ph_rc_fty == ty_pstr;
    // A string PARAMETER the body never assigns, handed straight back: the
    // caller holds that string for as long as it holds anything from this
    // call, so the answer is its own pointer with no reference taken -- what
    // the caller does with it (store it, return it, hand it to php) takes one
    // then, like any borrowed string. examples/decimal's _dec_valid answers
    // its argument on every valid call.
    if (str && nd_kind(e) == N_IDENT && ph_rc_is_param(nd_name(e))) str = 0;
    // a `return EXPR;` in a VOID function (php refuses it; the lowering
    // reports that at run time): the value is still evaluated, and dropped
    if (e && ph_rc_fty == TY_VOID) {
        h = ph_rc_stmt(e);
        t = h;
        e = 0;
    }
    if (e) {
        h = ph_rc_set("ph_rv", e);
        t = h;
        if (str) {
            // a counted slot hands its own reference over; anything else is
            // taken like a store
            if (nd_kind(e) == N_IDENT && ph_rc_is_slot(nd_name(e))) {
                set_nd_next(t, ph_rc_set(nd_name(e), ph_rc_int(0)));
            }
            if (!(nd_kind(e) == N_IDENT && ph_rc_is_slot(nd_name(e)))) set_nd_next(t, ph_rc_take("ph_rv"));
            t = nd_next(t);
        }
    }
    i64 rel = ph_rc_releases(tb);
    if (rel) {
        if (t) set_nd_next(t, rel);
        if (!t) h = rel;
        t = ld64(tb);
    }
    i64 d = ph_rc_drain();
    if (t) set_nd_next(t, d);
    if (!t) h = d;
    t = d;
    // a string answer comes out as the caller's temporary
    if (str) { set_nd_next(t, ph_rc_push("ph_rv")); t = nd_next(t); }
    i64 ret = node_new(N_RETURN, ph_rc_ln, ph_rc_fl);
    if (e) set_nd_a(ret, ph_rc_id("ph_rv", ph_rc_fty));
    set_nd_next(t, ret);
    return ph_rc_block(h);
}

i64 ph_rc_is_param(uptr name) {
    i64 i = 0;
    loop {
        if (i >= ph_rc_nbor) break;
        if (str_eq(ld64(ph_rc_bor + i * 8), name)) return 1;
        i = i + 1;
    }
    return 0;
}

// one statement, rewritten; its successor is the caller's to link
i64 ph_rc_one(i64 s) {
    i64 k = nd_kind(s);
    ph_rc_ln = nd_line(s);
    ph_rc_fl = nd_file(s);
    if (k == N_VAR && nd_type(s) == ty_pstr && ph_rc_is_slot(nd_name(s))) {
        if (!nd_a(s)) set_nd_a(s, ph_rc_int(0));
        if (nd_a(s) && nd_kind(nd_a(s)) != N_INT) {
            i64 z = ph_rc_int(0);
            set_nd_next(z, nd_a(s));
            set_nd_a(s, ph_rc_call("php_sset", z, ty_pstr));
        }
        return s;
    }
    if (k == N_ASSIGN && ph_rc_is_slot(nd_name(s))) {
        uptr nm = nd_name(s);
        i64 v = nd_a(s);
        if (ph_rc_is_call(v, "php_str_concat", nm)) { set_nd_name(v, "php_str_append"); return s; }
        // `$s = $s . a . b [. c]`: the chain php_str_cat3/cat4 folded
        if (ph_rc_is_call(v, "php_str_cat3", nm)) {
            set_nd_name(v, "php_str_appendv");
            i64 z = ph_rc_int(0);
            i64 last = nd_a(v);
            loop { if (!nd_next(last)) break; last = nd_next(last); }
            set_nd_next(last, z);
            return s;
        }
        if (ph_rc_is_call(v, "php_str_cat4", nm)) { set_nd_name(v, "php_str_appendv"); return s; }
        if (ph_rc_is_call(v, "php_str_setoff", nm)) { set_nd_name(v, "php_str_setoff_own"); return s; }
        // ph_sn = value; take(ph_sn); release(slot); slot = ph_sn -- the new
        // reference first, so `$s = $s` and a call that answers its argument
        // change nothing
        i64 st = ph_rc_set("ph_sn", v);
        i64 tk = ph_rc_take("ph_sn");
        set_nd_next(st, tk);
        i64 rl = ph_rc_release(nm);
        set_nd_next(tk, rl);
        set_nd_a(s, ph_rc_id("ph_sn", ty_pstr));
        set_nd_next(rl, s);
        return ph_rc_block(st);
    }
    if (k == N_RETURN) return ph_rc_return(s);
    if (k == N_BLOCK) { set_nd_a(s, ph_rc_list(nd_a(s))); return s; }
    if (k == N_IF) {
        if (nd_b(s)) set_nd_b(s, ph_rc_list(nd_b(s)));
        if (nd_c(s)) set_nd_c(s, ph_rc_list(nd_c(s)));
        return s;
    }
    if (k == N_LOOP) {
        // the top of every iteration drops the last one's temporaries
        i64 d = ph_rc_drain();
        set_nd_next(d, ph_rc_list(nd_a(s)));
        set_nd_a(s, ph_rc_block(d));
        return s;
    }
    return s;
}

// a statement list; in check mode a drain after every statement that does not
// leave it (the most drains the discipline allows, so the most chances for a
// string freed under a live name to be caught)
i64 ph_rc_list(i64 s) {
    i64 h = 0;
    i64 t = 0;
    loop {
        if (!s) break;
        i64 nx = nd_next(s);
        set_nd_next(s, 0);
        i64 k = nd_kind(s);
        i64 r = ph_rc_one(s);
        if (t) set_nd_next(t, r);
        if (!t) h = r;
        t = r;
        if (ph_rcchk_mode && ph_rc_counting && k != N_RETURN && k != N_BREAK && k != N_CONTINUE && k != N_VAR) {
            i64 d = ph_rc_drain();
            set_nd_next(t, d);
            t = d;
        }
        s = nx;
    }
    return h;
}

// The whole function. `f` is an N_FUNC: nd_a the parameters, nd_b the body
// block, nd_type the mc return type.
// does the body loop anywhere? (a try is a loop here: the lowering's
// `loop { ...; break; }` -- counted too, which is only ever the safe side)
i64 ph_rc_has_loop(i64 s) {
    loop {
        if (!s) break;
        i64 k = nd_kind(s);
        if (k == N_LOOP) return 1;
        if (k == N_BLOCK) { if (ph_rc_has_loop(nd_a(s))) return 1; }
        if (k == N_IF) {
            if (ph_rc_has_loop(nd_b(s))) return 1;
            if (ph_rc_has_loop(nd_c(s))) return 1;
        }
        s = nd_next(s);
    }
    return 0;
}

// A function with NO loop never drains before it returns, so every string it
// or its callees built this call stays on the pool until then: a string local
// may BORROW from the pool and needs no count at all. Only a function that
// loops -- and so drains at the top of every iteration -- counts its string
// locals. That is most of the stores and returns examples/decimal makes (its
// helpers are straight-line code), and all of their counting. The one thing a
// borrowing local gives up is writing in place: `$s .= x` there is a new
// string, because nothing says the pool's reference is the only one (a
// straight-line function appends a bounded number of times).
i64 ph_rc_counting;

void ph_rc_fn(i64 f) {
    if (!ph_rc_on()) return;
    ph_rc_nslot = 0;
    ph_rc_fty = nd_type(f);
    ph_rc_fl = nd_file(f);
    ph_rc_ln = nd_line(f);
    i64 body = nd_b(f);
    if (!body) return;
    ph_rc_counting = ph_rc_has_loop(nd_a(body));
    // the borrowed ones, decided before the rewrite cuts and relinks the list
    ph_rc_nbor = 0;
    ph_rc_bor = xalloc(12 * 8 + 8);
    i64 q = nd_a(f);
    loop {
        if (!q) break;
        if (nd_type(q) == ty_pstr && !ph_rc_assigned(nd_a(body), nd_name(q)) && ph_rc_nbor < 12) {
            st64(ph_rc_bor + ph_rc_nbor * 8, nd_name(q));
            ph_rc_nbor = ph_rc_nbor + 1;
        }
        q = nd_next(q);
    }
    if (ph_rc_counting) ph_rc_scan_vars(nd_a(body));
    // the string parameters the body assigns are slots too; the ones it never
    // assigns stay borrowed
    i64 entry = 0;
    i64 etail = 0;
    i64 p = nd_a(f);
    loop {
        if (!p) break;
        if (ph_rc_counting && nd_type(p) == ty_pstr && ph_rc_assigned(nd_a(body), nd_name(p))) {
            ph_rc_add_slot(nd_name(p));
            i64 rs = ph_rc_ifstr(nd_name(p), ph_rc_bump(nd_name(p), 1));
            if (etail) set_nd_next(etail, rs);
            if (!etail) entry = rs;
            etail = rs;
        }
        p = nd_next(p);
    }
    i64 nb = ph_rc_list(nd_a(body));
    // falling off the end is a return too
    i64 tl = nb;
    if (tl) { loop { if (!nd_next(tl)) break; tl = nd_next(tl); } }
    if (!tl || nd_kind(tl) != N_RETURN) {
        u8 tb[8];
        i64 rel = ph_rc_releases(tb);
        i64 d = ph_rc_drain();
        if (rel) { set_nd_next(ld64(tb), d); }
        if (!rel) rel = d;
        if (tl) set_nd_next(tl, rel);
        if (!tl) nb = rel;
    }
    // the entry mark and the answer's temporary, declared ahead of everything
    i64 pm = node_new(N_VAR, ph_rc_ln, ph_rc_fl);
    set_nd_name(pm, "ph_pm");
    set_nd_type(pm, TY_I64);
    set_nd_a(pm, ph_rc_id("ph_pn", TY_I64));
    i64 head = pm;
    i64 tail = pm;
    // the value a store is taking, held while the old one is released
    i64 sn = node_new(N_VAR, ph_rc_ln, ph_rc_fl);
    set_nd_name(sn, "ph_sn");
    set_nd_type(sn, ty_pstr);
    set_nd_a(sn, 0);
    set_nd_next(tail, sn);
    tail = sn;
    if (ph_rc_fty != TY_VOID) {
        i64 rv = node_new(N_VAR, ph_rc_ln, ph_rc_fl);
        set_nd_name(rv, "ph_rv");
        set_nd_type(rv, ph_rc_fty);
        set_nd_a(rv, 0);
        set_nd_next(tail, rv);
        tail = rv;
    }
    if (entry) { set_nd_next(tail, entry); tail = etail; }
    set_nd_next(tail, nb);
    set_nd_a(body, head);
}

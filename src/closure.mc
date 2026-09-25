// closure.mc -- closures, arrow functions and use().
// 
// use (&$x) captures the enclosing zval's ADDRESS, carried through the use
// array as an integer: the array slot is a different cell and could not alias.

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
    // `use (&$x)`: the capture is the enclosing variable's OWN zval, carried
    // through the use array as its address (php_zlong / php_zv_long) rather
    // than as a copy -- the array slot php_arr_set writes is a different cell
    // and could not alias. The enclosing $x is already a zval: the source
    // scan's `&$` rule put it in the ref set.
    u8 urefs[128];
    i64 ur0 = 0;
    loop { if (ur0 >= 16) break; st64(urefs + ur0 * 8, 0); ur0 = ur0 + 1; }
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
                i64 uref = 0;
                if (ph_at("&", 1)) { ph_next(); uref = 1; }
                if (!ph_at("$", 1)) err_at(fl, line, "mc-php: a php variable was expected in use");
                ph_next();
                uptr un = p_cat("$", ph_tname, 0, cstrlen(ph_tname));
                ph_next();
                if (ph_var_find(un) < 0) ph_refuse2(fl, line, "an undefined php variable in use", un, "D4");
                if (nu >= 16) ph_todo(fl, line, "more than sixteen captured variables");
                st64(unames + nu * 8, un);
                st64(urefs + nu * 8, uref);
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
        if (ld64(urefs + ui * 8)) {
            if (!ph_is_ref(un2)) ph_todo2(fl, line, "a by-reference use of a php variable of type", ph_tyname(vt));
            set_nd_type(vr, ty_pzv);
            vr = ph_c1("php_zlong", ph_cast(TY_I64, vr), ty_pzv);
            vt = PT_MIXED;
        }
        i64 ar = node_new(N_IDENT, line, fl);
        set_nd_name(ar, an);
        set_nd_type(ar, ty_parr);
        // BY VALUE means by value: `php_arr_set` copies the zval header
        // and an ARRAY's header holds the hash, so the closure and the
        // outer variable shared it -- `$a = [1,2]; $f = function() use
        // ($a) { $a[] = 3; ...}` left the OUTER array with three elements
        // where php leaves it with two. `php_zv_val` is the same deep copy
        // a by-value parameter already takes (ph_byval), and a
        // by-reference `use (&$x)` must NOT take it.
        i64 cap = ph_to_mixed(vr, vt);
        if (!ld64(urefs + ui * 8)) cap = ph_c1("php_zv_val", cap, ty_pzv);
        i64 st2 = ph_stmt_of(ph_c3("php_arr_set", ar, ph_to_mixed(ph_strlit(un2 + 1, cstrlen(un2 + 1)), PT_STRING),
                                   cap, TY_VOID));
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
    i64 srrc = ph_fn_retref;
    ph_pend_head = 0;
    ph_pend_tail = 0;
    ph_hoist_head = 0;
    ph_hoist_tail = 0;
    ph_fn_ret = PT_MIXED;
    ph_fn_retref = 0;
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
        if (ld64(urefs + ui2 * 8)) {
            get = ph_cast(ty_pzv, ph_c1("php_zv_long", get, TY_I64));
            ph_set_ref(un3);
        }
        // and a copy PER CALL, not just per capture: the use array holds
        // ONE zval and the body would otherwise append to it every time --
        // `$f()` twice on a captured `[1,2]` answered 4 then 5 where php
        // answers 3 both times, because php binds the value once and each
        // CALL starts from it. A by-reference use must alias, so it is
        // exempt.
        if (!ld64(urefs + ui2 * 8)) get = ph_c1("php_zv_val", get, ty_pzv);
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
    ph_rc_fn(f);
    ph_opt_fn(f);
    top_add(f);

    ph_scope_restore(savenv);
    ph_hoist_head = hh;
    ph_hoist_tail = ht;
    ph_fn_ret = sret;
    ph_fn_retref = srrc;
    ph_in_method = sm;
    ph_in_static = sst;
    ph_toplevel = stl;
    ph_nls = sls;
    ph_pend_head = sph;
    ph_pend_tail = spt;
    ph_ety = PT_MIXED;
    return made;
}


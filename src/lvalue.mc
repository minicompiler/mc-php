// lvalue.mc -- everything that can be assigned to.
// 
// The lvalue chain walks [k] and ->p in any order and to any depth and
// answers a container plus a key or a property name; isset/empty read the
// same chain QUIETLY. list() and [$a, $b] = are php's destructuring, the
// pattern collected first as a flat list of paths.

// ---- lvalues ---------------------------------------------------------------
// A php variable holds a native value of its static type; the assignment of a
// value that OWNS memory (an array, a zval) makes an independent copy, because
// a php array is a value (see php_rt.txt "array value semantics").
i64 ph_own(i64 v, i64 t) {
    if (t == PT_ARR && !ph_efresh)   return ph_c1("php_arr_copy", v, ty_parr);
    if (t == PT_MIXED || t == PT_NULL) {
        if (ph_zv_fresh(v)) return v;
        return ph_c1("php_zv_val", v, ty_pzv);
    }
    return v;
}

// a zval nothing else can reach: what a constructor or an operator returns is
// a box the runtime has just allocated (an array it holds is a copy made for
// it), so the value copy ph_own makes for a variable would copy it again
i64 ph_zv_fresh(i64 v) {
    if (nd_kind(v) != N_CALL) return 0;
    uptr n = nd_name(v);
    return str_eq(n, "php_zlong") || str_eq(n, "php_zdouble") || str_eq(n, "php_zbool")
        || str_eq(n, "php_znull") || str_eq(n, "php_zstr") || str_eq(n, "php_zv_val")
        || str_eq(n, "php_zv_add") || str_eq(n, "php_zv_sub") || str_eq(n, "php_zv_mul")
        || str_eq(n, "php_zv_div") || str_eq(n, "php_zv_mod") || str_eq(n, "php_zv_pow")
        || str_eq(n, "php_zv_neg") || str_eq(n, "php_zv_concat");
}

// An INT key on the last subscript of an assignment's lvalue (the one caller
// that sets ph_lv_ikok): kept native, and ph_lv_ikey says so, so the element
// is written and read through php_arr_iset/iget_w without a key zval.
i64 ph_lv_ikok;
i64 ph_lv_ikey;

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
// The lvalue chain `$v[...][...]->p[...]`, walked to its LAST accessor: what
// comes back is the container plus either a key (an array element) or a
// property name, and ph_store writes whichever it is. T8: it walked `[` only,
// so `$a[0]->p = 1`, `$t->x[0][0]` and `$c = &$t->list` -- 71 of the 734 that
// did not compile -- had nowhere to go.
//
// `ph_lv_prop` is the property name of the last accessor, 0 for an element;
// `cur` is then the RECEIVER (a zval) instead of an array handle.
i64 ph_lv_walk(uptr d, uptr fl, i64 line, uptr pkey, i64 hoist) {
    i64 vt = ph_var_type(d);
    i64 base = node_new(N_IDENT, line, fl);
    set_nd_name(base, ph_mangle(d, "v_"));
    set_nd_type(base, ph_mcty(vt));
    ph_lv_prop = 0;
    i64 cur = base;
    i64 isarr = 1;                       // cur is an array handle, not a zval
    if (vt == PT_MIXED) { cur = base; isarr = 0; }
    if (vt == PT_OBJ)   { cur = ph_to_mixed(base, PT_OBJ); isarr = 0; }
    if (vt != PT_MIXED && vt != PT_ARR && vt != PT_OBJ)
        ph_refuse2(fl, line, "indexing a value that is not an array", ph_tyname(vt), "D4");
    loop {
        if (ph_at("->", 2) || ph_at("?->", 3)) {
            ph_next();
            if (ph_at("$", 1) || ph_at("{", 1))
                ph_refuse(fl, line, "a property name that is not a literal", "D6");
            if (!ph_wordish()) err_at2(fl, line, "mc-php: a php property needs a name", ph_tname);
            uptr pn = ph_tname;
            ph_next();
            if (isarr) { cur = ph_c1("php_zarr", cur, ty_pzv); isarr = 0; }
            if (!ph_at("[", 1) && !ph_at("->", 2) && !ph_at("?->", 3)) {
                if (hoist) cur = ph_temp(cur, ty_pzv, "phc_");
                ph_lv_prop = pn;
                st64(pkey, 0);
                return cur;
            }
            cur = ph_c3("php_zv_pget", cur, ph_strlit(pn, cstrlen(pn)), ph_scope(), ty_pzv);
            continue;
        }
        ph_want("[", 1, "expected [ in a php array assignment");
        if (!isarr) { cur = ph_c1("php_zv_arr_w", cur, ty_parr); isarr = 1; }
        i64 k = 0;
        i64 kx = 0;
        i64 kt = -1;
        if (!ph_at("]", 1)) { kx = ph_expr(0); kt = ph_ety; k = ph_zkey(kx, kt); }
        ph_want("]", 1, "expected ] in a php array assignment");
        if (!ph_at("[", 1) && !ph_at("->", 2) && !ph_at("?->", 3)) {
            ph_lv_ikey = 0;
            if (ph_lv_ikok && kt == PT_INT) { k = kx; ph_lv_ikey = 1; }
            if (hoist) {
                cur = ph_temp(cur, ty_parr, "phc_");
                if (k && ph_lv_ikey) k = ph_temp(k, TY_I64, "phk_");
                if (k && !ph_lv_ikey) k = ph_temp(k, ty_pzv, "phk_");
            }
            st64(pkey, k);
            return cur;
        }
        if (ph_at("->", 2) || ph_at("?->", 3)) {
            // the element itself is the receiver of the property access
            if (k)  cur = ph_c2("php_arr_zget_w", cur, k, ty_pzv);
            if (!k) cur = ph_c1("php_zarr", ph_c1("php_arr_dimn", cur, ty_parr), ty_pzv);
            isarr = 0;
            continue;
        }
        if (k)  cur = ph_c2("php_arr_dim", cur, k, ty_parr);
        if (!k) cur = ph_c1("php_arr_dimn", cur, ty_parr);
    }
    return cur;
}

// The write ph_lv_walk's answer asks for. `prop` is ph_lv_walk's own
// ph_lv_prop and is passed rather than read from the global: the OTHER
// caller (ph_obj_stmt's `$o->p[k] =`) would otherwise see a stale one, which
// is how `$t->x[0] = "q"` wrote a property named after an earlier statement's.
i64 ph_store(i64 cur, i64 k, i64 zv, uptr prop) {
    if (prop) return ph_c4("php_zv_pset", cur, ph_strlit(prop, cstrlen(prop)), zv, ph_scope(), TY_VOID);
    if (k) return ph_c3("php_arr_set", cur, k, zv, TY_VOID);
    return ph_c2("php_arr_push", cur, zv, TY_VOID);
}

// ph_store with the key native when `ik` says it is an int
i64 ph_store_ik(i64 cur, i64 k, i64 zv, uptr prop, i64 ik) {
    if (!prop && k && ik) return ph_c3("php_arr_iset", cur, k, zv, TY_VOID);
    return ph_store(cur, k, zv, prop);
}

// the CELL the same path ends on, which is what a reference needs
i64 ph_slot(i64 cur, i64 k, uptr prop) {
    if (prop) return ph_c3("php_zv_pref", cur, ph_strlit(prop, cstrlen(prop)), ph_scope(), ty_pzv);
    if (k) return ph_c2("php_arr_zslot", cur, k, ty_pzv);
    return ph_c1("php_arr_nextslot", cur, ty_pzv);
}

// `<container> = &$v`: bind the variable to the container's own cell, after
// the cell receives the variable's current value. Reads the `&` and the
// `$name` after it; returns the statement.
i64 ph_ref_into(i64 cell, uptr fl, i64 line, i64 semi) {
    ph_next();                                                   // &
    if (!ph_at("$", 1)) ph_todo(fl, line, "a reference to something that is not a $variable");
    ph_next();
    if (!ph_wordish()) err_at2(fl, line, "mc-php: a php variable needs a name", ph_tname);
    uptr sv = p_cat("$", ph_tname, 0, cstrlen(ph_tname));
    ph_next();
    if (semi) ph_semi("expected ; after a php assignment");
    if (ph_var_find(sv) < 0) ph_bind_undef(sv, fl, line, 1);
    if (ph_var_type(sv) != PT_MIXED)
        ph_todo2(fl, line, "a reference to a php variable of type", ph_tyname(ph_var_type(sv)));
    if (!ph_is_ref(sv)) ph_set_ref(sv);
    i64 cv = node_new(N_IDENT, line, fl);
    set_nd_name(cv, ph_mangle(sv, "v_"));
    set_nd_type(cv, ty_pzv);
    return ph_wrap(ph_set(ph_mangle(sv, "v_"), ph_c2("php_ref_bind", cell, cv, ty_pzv)));
}

// $v = expr / $v[i] = expr / $v[] = expr, and the compound forms
i64 ph_assign_stmt(uptr fl, i64 line, i64 semi) {
    u8 kbr[8];
    ph_next();                                       // $
    if (ph_at("$", 1)) ph_refuse(fl, line, "a variable variable $$name", "D6");
    if (!ph_wordish()) err_at2(fl, line, "mc-php: a php variable needs a name", ph_tname);
    uptr d = p_cat("$", ph_tname, 0, cstrlen(ph_tname));
    ph_next();

    if (ph_at("->", 2) || ph_at("?->", 3)) {
        if (ph_var_find(d) < 0) ph_bind_undef(d, fl, line, 0);
        return ph_obj_stmt(d, fl, line, semi);
    }
    if (ph_at("[", 1)) {
        // a php array springs into existence on its first [] write
        if (ph_var_find(d) < 0) {
            ph_var_bind(d, PT_ARR);
            ph_pending_stmt(ph_set(ph_mangle(d, "v_"), ph_c1("php_arr_new", ph_int(8), ty_parr)));
        }
        // `$s[9] = "x"` on a STRING is php's byte write. A string is
        // immutable here (D10), so the answer is a new one bound to the
        // same name -- which is the same value semantics php has.
        if (ph_var_type(d) == PT_STRING) {
            ph_next();
            i64 ix = ph_to_int(ph_expr(0), ph_ety);
            ph_want("]", 1, "expected ] after a php string offset");
            ph_want("=", 1, "expected = after a php string offset");
            i64 cv = ph_expr(0);
            i64 cvt = ph_ety;
            if (semi) ph_semi("expected ; after a php assignment");
            i64 sb = node_new(N_IDENT, line, fl);
            set_nd_name(sb, ph_mangle(d, "v_"));
            set_nd_type(sb, ty_pstr);
            ph_can_throw = 1;
            return ph_wrap(ph_set(ph_mangle(d, "v_"),
                ph_c3("php_str_setoff", sb, ix, ph_to_mixed(cv, cvt), ty_pstr)));
        }
        u8 kb[8];
        // The container and the key are hoisted into temporaries whatever
        // follows: a compound form has to READ the element as well as write
        // it, and there is no way to walk the same tokens twice. T8: that is
        // what `a compound assignment to an array element` was waiting for.
        ph_lv_ikok = 1;
        ph_lv_ikey = 0;
        i64 cur = ph_lv_walk(d, fl, line, kb, 1);
        ph_lv_ikok = 0;
        i64 ik = ph_lv_ikey;
        ph_lv_ikey = 0;
        uptr lprop = ph_lv_prop;
        i64 k = ld64(kb);
        if (lprop) ik = 0;
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
        if (ph_at("--", 2)) incdec = 0 - 1;
        // The element, read where php reads it. A node may appear in a tree
        // ONCE -- the arguments of a call are its sibling chain -- so the
        // read and the write each get their own reference to the hoisted
        // container and key. Sharing them makes the chain a CYCLE, which is
        // a stack overflow in the walker and not a diagnostic.
        if (op || incdec || ph_at("??=", 3)) {
            i64 cur2 = ph_tref(cur);
            i64 k2 = 0;
            if (k) k2 = ph_tref(k);
            i64 rd = 0;
            if (lprop) rd = ph_c3("php_zv_pget", cur2, ph_strlit(lprop, cstrlen(lprop)), ph_scope(), ty_pzv);
            if (!lprop && k && ik) rd = ph_c2("php_arr_iget_w", cur2, k2, ty_pzv);
            if (!lprop && k && !ik) rd = ph_c2("php_arr_zget_w", cur2, k2, ty_pzv);
            if (!lprop && !k) ph_todo(fl, line, "a compound assignment to $a[]");
            if (ph_at("??=", 3)) {
                // the hoisted container and key are initialised BEFORE the
                // test that reads them; the right-hand side's own pendings
                // stay inside the branch, because php does not evaluate it
                // when the element is already set
                i64 hpre = ph_take_pend();
                ph_next();
                i64 rv = ph_expr(0);
                i64 rvt = ph_ety;
                if (semi) ph_semi("expected ; after ??=");
                i64 quiet = 0;
                if (lprop) quiet = ph_c3("php_zv_pget_q", ph_tref(cur), ph_strlit(lprop, cstrlen(lprop)), ph_scope(), ty_pzv);
                if (!lprop && ik) quiet = ph_c2("php_arr_iget", ph_tref(cur), ph_tref(k), ty_pzv);
                if (!lprop && !ik) quiet = ph_c2("php_arr_zget", ph_tref(cur), ph_tref(k), ty_pzv);
                i64 nn = node_new(N_UNARY, line, fl);
                set_nd_op(nn, ph_tok("!", 1));
                set_nd_a(nn, ph_cast(TY_U8, ph_c1("php_zv_isset", quiet, TY_I64)));
                set_nd_type(nn, TY_U8);
                i64 iff = node_new(N_IF, line, fl);
                set_nd_a(iff, nn);
                set_nd_b(iff, ph_expr_stmt_of(ph_store_ik(cur, k, ph_to_mixed(ph_own(rv, rvt), rvt), lprop, ik)));
                return ph_prefix_stmts(hpre, ph_wrap(iff));
            }
            i64 nv = 0;
            if (incdec) {
                ph_next();
                if (semi) ph_semi("expected ; after ++/--");
                if (incdec > 0) nv = ph_c1("php_zv_inc", rd, ty_pzv);
                if (incdec < 0) nv = ph_c1("php_zv_dec", rd, ty_pzv);
            }
            if (!incdec) {
                ph_next();
                i64 rv = ph_expr(0);
                i64 rvt = ph_ety;
                if (semi) ph_semi("expected ; after a php assignment");
                if (op == ph_tok(".", 1)) nv = ph_c2("php_zv_concat", rd, ph_to_mixed(rv, rvt), ty_pzv);
                if (op != ph_tok(".", 1)) { nv = ph_arith(op, rd, PT_MIXED, rv, rvt, fl, line); nv = ph_to_mixed(nv, ph_ety); }
            }
            return ph_expr_stmt_of(ph_store_ik(cur, k, nv, lprop, ik));
        }
        ph_want("=", 1, "expected = after a php array index");
        if (ph_at("&", 1)) {
            if (ik) k = ph_to_mixed(k, PT_INT);
            return ph_ref_into(ph_slot(cur, k, lprop), fl, line, semi);
        }
        i64 v = ph_expr(0);
        i64 vt = ph_ety;
        if (semi) ph_semi("expected ; after a php assignment");
        return ph_expr_stmt_of(ph_store_ik(cur, k, ph_to_mixed(ph_own(v, vt), vt), lprop, ik));
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
        if (ph_var_find(d) < 0) ph_bind_undef(d, fl, line, 0);
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
        if (ph_var_find(d) < 0) ph_bind_undef(d, fl, line, 0);
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
        // not an assignment after all: `$f();`, `$x or die();`, `$a ?: b;`.
        // php allows any expression as a statement, and the $variable and its
        // name are the only tokens read so far, so the ordinary expression
        // road picks it up from here.
        ph_efresh = 0;
        i64 ev = ph_postfix(ph_var_ref(d), ph_ety);
        ev = ph_expr_tail(ev, ph_ety, 0);
        if (semi) ph_semi("expected ; after a php expression");
        return ph_expr_stmt_of(ev);
    }
    ph_next();
    if (ph_at("&", 1)) {
        // $a = &$b: the two names share one zval from here on
        ph_next();
        if (!ph_at("$", 1)) {
            // `$a = &f()`, `$a = &C::m()`, `$a = &new C`. A mixed value IS a
            // zval cell here, so binding the name to it is the alias php
            // gives when the callee returns by reference; when it does not,
            // php keeps the value and says so, which is what the notice is.
            ph_ref_call = 0;
            i64 rex = ph_expr(0);
            i64 rxt = ph_ety;
            if (semi) ph_semi("expected ; after a php assignment");
            if (ph_var_find(d) < 0) ph_var_bind(d, PT_MIXED);
            if (ph_var_type(d) != PT_MIXED)
                ph_todo2(fl, line, "a reference bound to a php variable of type", ph_tyname(ph_var_type(d)));
            ph_set_ref(d);
            i64 pre = 0;
            if (!ph_ref_call) pre = ph_stmt_of(ph_call("php_ref_notice", 0, 0, 0, 0, 0, TY_VOID));
            i64 bnd = ph_set(ph_mangle(d, "v_"), ph_to_mixed(rex, rxt));
            if (pre) { set_nd_next(pre, bnd); return ph_wrap(pre); }
            return ph_wrap(bnd);
        }
        ph_next();
        uptr src = p_cat("$", ph_tname, 0, cstrlen(ph_tname));
        ph_next();
        // `$r = &$o->p` / `$r = &$a[k]`: the CELL the chain ends on, which is
        // exactly what ph_lv_walk finds. The slot is created when it is not
        // there, as php's reference-taking does.
        if (ph_at("->", 2) || ph_at("?->", 3) || ph_at("[", 1)) {
            if (ph_var_find(src) < 0) ph_bind_undef(src, fl, line, 1);
            i64 sc = ph_lv_walk(src, fl, line, kbr, 0);
            uptr sprop = ph_lv_prop;
            i64 sk = ld64(kbr);
            if (semi) ph_semi("expected ; after a php assignment");
            i64 cell = 0;
            if (sprop) cell = ph_c3("php_zv_pref", sc, ph_strlit(sprop, cstrlen(sprop)), ph_scope(), ty_pzv);
            if (!sprop && sk) cell = ph_c2("php_arr_zslot", sc, sk, ty_pzv);
            if (!sprop && !sk) cell = ph_c1("php_arr_nextslot", sc, ty_pzv);
            if (ph_var_find(d) < 0) ph_var_bind(d, PT_MIXED);
            if (ph_var_type(d) != PT_MIXED)
                ph_todo2(fl, line, "a reference bound to a php variable of type", ph_tyname(ph_var_type(d)));
            ph_set_ref(d);
            return ph_wrap(ph_set(ph_mangle(d, "v_"), cell));
        }
        if (semi) ph_semi("expected ; after a php assignment");
        // `$a = &$b` where $b does not exist: php creates it as null, silently
        if (ph_var_find(src) < 0) ph_bind_undef(src, fl, line, 1);
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

// The literal bytes of the CURRENT string token, or 0 when it is not one or
// when it interpolates. A double-quoted literal is already a NODE by the time
// it gets here, so the bytes come out of it -- the shape define() reads for
// the same reason.
uptr ph_str_lit_bytes() {
    if (ph_tid == PHT_DSTR) {
        i64 dn = ph_tnode;
        if (nd_kind(dn) != N_CALL) return 0;
        if (!str_eq(nd_name(dn), "php_str_lit")) return 0;
        i64 raw = nd_next(nd_a(dn));
        if (!raw) return 0;
        return xstrdup(nd_name(raw), nd_val(raw));
    }
    if (ph_tid == T_STR) return ph_tname;
    if (ph_tid == PHT_PSTR) return ph_tname;
    return 0;
}

void ph_require(i64 once, uptr fl, i64 line) {
    ph_next();
    if (ph_at("(", 1)) ph_next();
    // `require __DIR__ . "/x.php"` is php-src's own spelling and the path is
    // known at COMPILE time, so D1's "computed" does not describe it:
    // __DIR__ is a compile-time constant and the concatenation of two
    // literals is a literal. Nothing else is folded -- a variable, a call or
    // an interpolation is still refused by name.
    //
    // It was refused, and that is why D8's mc-php half never ran: every
    // probe's bench/run.php and bench/main.php opens with one of these, so
    // "6 ok / 0 failed in BOTH worlds" and the two bench ratios T9 published
    // were php's side alone. run.sh's step 10 wrote the mc-php half to a
    // `| tail -1` with no `|| fail=1` behind it, so the refusal went to
    // stderr and nothing graded it.
    uptr dir = 0;
    if (ph_tid == T_IDENT) {
        if (str_eq(ph_tname, "__DIR__")) {
            dir = path_norm(path_join(ph_absfile(fl), "."));
            ph_next();
            if (!ph_at(".", 1)) ph_refuse(fl, line, "an include of a computed path", "D1");
            ph_next();
        }
    }
    uptr rel = ph_str_lit_bytes();
    if (!rel) ph_refuse(fl, line, "an include of a computed path", "D1");
    ph_next();
    if (ph_at(")", 1)) ph_next();
    if (!ph_at(";", 1)) err_at(fl, line, "mc-php: expected ; after require");
    uptr full = path_norm(path_join(fl, rel));
    if (dir) {
        uptr r2 = rel;
        if (ld8(r2) == 47) r2 = r2 + 1;
        full = path_norm(path_join(p_cat(dir, "/x", 0, 2), r2));
    }
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

// A statement announces its position only when something in it can raise a
// diagnostic or throw; a declaration and an empty statement lower to nothing
// and get none either way.
//
// The position exists so a diagnostic can name a line and a throw can carry
// one, and the check after the statement exists so a throw can unwind. A
// statement that contains no call can do neither: under
// declare(strict_types=1) with declared scalar types `$s = $s + $i` is two
// loads, an add and a store, and everything that can raise in this compiler
// is a runtime call. So ph_call's mark is the test -- it is conservative in
// the safe direction, since a call that cannot raise still asks for both --
// and php_pos itself is the one call exempt from it, for the reason
// ph_posstmt gives.
i64 ph_stmt() {
    i64 line = ph_tline;
    uptr fl = ph_tfile;
    i64 save = ph_can_throw;
    ph_can_throw = 0;
    i64 s = ph_stmt_1();
    i64 raises = ph_can_throw;
    ph_can_throw = raises | save;
    if (nd_kind(s) == N_BLOCK && !nd_a(s) && !nd_next(s)) return s;
    if (!raises) return s;
    if (ph_is_pos_at(s, fl, line)) return s;
    i64 p = ph_posstmt(fl, line);
    set_nd_next(p, s);
    return p;
}


// ---- list() / [$a, $b] = : php's destructuring -----------------------------
// The pattern is collected FIRST (the source expression comes after the `=`),
// as a flat list of paths: each target is a variable name plus the chain of
// keys that reaches its value. `[$a, [$b, $c]]` is three targets with the
// chains 0, 1/0 and 1/1. A skipped element (`[, $b]`) advances the index and
// records nothing.
#define PH_MAXDT 32
#define PH_DTDEP 4

uptr ph_dtname[PH_MAXDT];
i64  ph_dtnk[PH_MAXDT];
i64  ph_dtkey[PH_MAXDT * PH_DTDEP];
i64  ph_ndt;

// one level of the pattern; `pre` is the key chain that reaches it
void ph_dt_pattern(uptr fl, i64 line, uptr pre, i64 npre) {
    i64 idx = 0;
    loop {
        if (ph_at("]", 1) || ph_at(")", 1)) break;
        if (ph_tid == T_EOF) err_at(fl, line, "mc-php: unterminated destructuring pattern");
        if (ph_accept(",", 1)) { idx = idx + 1; continue; }        // a hole
        i64 key = ph_int(idx);
        i64 keyt = PT_INT;
        // `'k' => $v`: the key is written out
        if (!ph_at("$", 1) && !ph_at("[", 1) && !ph_is("list")) {
            key = ph_expr(0);
            keyt = ph_ety;
            ph_want("=>", 2, "expected => in a destructuring key");
        }
        // a `$name` here is either the target or the KEY of `$k => $v`, and
        // the token after the name is what says which
        uptr dv = 0;
        if (ph_at("$", 1)) {
            ph_next();
            if (ph_tid != T_IDENT) err_at2(fl, line, "mc-php: a destructuring target needs a name", ph_tname);
            dv = p_cat("$", ph_tname, 0, cstrlen(ph_tname));
            ph_next();
            if (ph_at("=>", 2)) {
                ph_next();
                key = ph_var_ref(dv);
                keyt = ph_ety;
                dv = 0;
            }
        }
        if (!dv && (ph_at("[", 1) || ph_is("list"))) {
            i64 br = ph_at("[", 1);
            ph_next();
            if (!br) ph_want("(", 1, "expected ( after list");
            u8 sub[64];
            i64 k = 0;
            loop { if (k >= npre) break; st64(sub + k * 8, ld64(pre + k * 8)); k = k + 1; }
            st64(sub + npre * 8, ph_to_mixed(key, keyt));
            ph_dt_pattern(fl, line, sub, npre + 1);
            if (br) ph_want("]", 1, "expected ] in a destructuring pattern");
            if (!br) ph_want(")", 1, "expected ) in list");
            idx = idx + 1;
            if (!ph_accept(",", 1)) break;
            continue;
        }
        if (!dv) {
            if (!ph_at("$", 1)) ph_todo2(fl, line, "a destructuring target", ph_tname);
            ph_next();
            if (ph_tid != T_IDENT) err_at2(fl, line, "mc-php: a destructuring target needs a name", ph_tname);
            dv = p_cat("$", ph_tname, 0, cstrlen(ph_tname));
            ph_next();
        }
        uptr d = dv;
        if (ph_ndt >= PH_MAXDT) ph_todo(fl, line, "more than 32 destructuring targets");
        if (npre >= PH_DTDEP) ph_todo(fl, line, "a destructuring pattern nested more than four deep");
        st64(ph_dtname + ph_ndt * 8, d);
        st64(ph_dtnk + ph_ndt * 8, npre + 1);
        i64 k2 = 0;
        loop { if (k2 >= npre) break; st64(ph_dtkey + (ph_ndt * PH_DTDEP + k2) * 8, ld64(pre + k2 * 8)); k2 = k2 + 1; }
        st64(ph_dtkey + (ph_ndt * PH_DTDEP + npre) * 8, ph_to_mixed(key, keyt));
        ph_ndt = ph_ndt + 1;
        idx = idx + 1;
        if (!ph_accept(",", 1)) break;
    }
}

// `list(...) = EXPR;` and `[...] = EXPR;`
i64 ph_destructure(uptr fl, i64 line, i64 br, i64 semi) {
    i64 save = ph_ndt;
    ph_ndt = 0;
    ph_next();                                       // list / [
    if (!br) ph_want("(", 1, "expected ( after list");
    u8 pre[64];
    ph_dt_pattern(fl, line, pre, 0);
    if (br) ph_want("]", 1, "expected ] in a destructuring pattern");
    if (!br) ph_want(")", 1, "expected ) in list");
    ph_want("=", 1, "expected = after a destructuring pattern");
    i64 src = ph_expr(0);
    i64 srct = ph_ety;
    if (semi) ph_semi("expected ; after a destructuring assignment");
    ph_nonce = ph_nonce + 1;
    uptr tn = p_cat("phd_", php_dec(ph_nonce), 0, cstrlen(php_dec(ph_nonce)));
    ph_local(tn, ty_pzv);
    i64 head = ph_set(tn, ph_to_mixed(src, srct));
    i64 tail = head;
    i64 i = 0;
    loop {
        if (i >= ph_ndt) break;
        uptr d = ld64(ph_dtname + i * 8);
        i64 nk = ld64(ph_dtnk + i * 8);
        i64 v = node_new(N_IDENT, line, fl);
        set_nd_name(v, tn);
        set_nd_type(v, ty_pzv);
        i64 k = 0;
        loop {
            if (k >= nk) break;
            v = ph_c2("php_zv_dim_rd", v, ld64(ph_dtkey + (i * PH_DTDEP + k) * 8), ty_pzv);
            k = k + 1;
        }
        i64 st2 = 0;
        if (ph_var_find(d) < 0 && ph_refset_has(d)) {
            ph_var_bind(d, PT_MIXED);
            ph_set_ref(d);
            st2 = ph_set(ph_mangle(d, "v_"), ph_c1("php_zv_val", v, ty_pzv));
        }
        if (!st2) {
            if (ph_is_ref(d)) {
                i64 lvr = node_new(N_IDENT, line, fl);
                set_nd_name(lvr, ph_mangle(d, "v_"));
                set_nd_type(lvr, ty_pzv);
                st2 = ph_expr_stmt_of(ph_c2("php_zv_store", lvr, v, ty_pzv));
            }
        }
        if (!st2) {
            if (ph_var_find(d) >= 0 && ph_var_type(d) != PT_MIXED)
                ph_todo2(fl, line, "a destructuring target of type", ph_tyname(ph_var_type(d)));
            ph_var_bind(d, PT_MIXED);
            st2 = ph_set(ph_mangle(d, "v_"), ph_c1("php_zv_val", v, ty_pzv));
        }
        set_nd_next(tail, st2);
        tail = st2;
        loop { if (!nd_next(tail)) break; tail = nd_next(tail); }
        i = i + 1;
    }
    ph_ndt = save;
    i64 b = node_new(N_BLOCK, line, fl);
    set_nd_a(b, head);
    return ph_wrap(b);
}

// php reads an undefined variable as null with a warning (T7's channel), and
// every operation that WRITES one -- `$u++`, `$u .= "x"`, `$u->p = 1` -- does
// the read first. So a name that is not bound yet is bound `mixed` here,
// holding what php's read of it answers, instead of being refused: `mixed` is
// a zval (D4 (c)) and null is one of its values.
void ph_bind_undef(uptr d, uptr fl, i64 line, i64 quiet) {
    ph_var_bind(d, PT_MIXED);
    if (ph_refset_has(d)) ph_set_ref(d);
    i64 v = ph_call("php_znull", 0, 0, 0, 0, 0, ty_pzv);
    if (!quiet) v = ph_c1("php_undef_var", ph_raw(d + 1, cstrlen(d) - 1), ty_pzv);
    ph_pending_stmt(ph_set(ph_mangle(d, "v_"), ph_c1("php_zv_val", v, ty_pzv)));
}

// `phna = 0; if (v_p0) phna = 1; if (v_p1) phna = 2; ...`, emitted BEFORE
// the defaults are filled in -- after them every parameter is non-zero and
// the count is lost. php counts the arguments that were PASSED.
i64 ph_nargs_prologue(uptr fl, i64 line) {
    ph_nargs_local = 0;
    if (!ph_uses_nargs) return 0;
    if (!ph_cpzv) return 0;
    ph_nonce = ph_nonce + 1;
    uptr nn = p_cat("phna_", php_dec(ph_nonce), 0, cstrlen(php_dec(ph_nonce)));
    ph_local(nn, TY_I64);
    ph_nargs_local = nn;
    i64 head = ph_set(nn, ph_int(0));
    i64 tail = head;
    i64 i = 0;
    loop {
        if (i >= ph_ncp) break;
        i64 pr = node_new(N_IDENT, line, fl);
        set_nd_name(pr, ph_mangle(ld64(ph_cpn + i * 8), "v_"));
        set_nd_type(pr, ty_pzv);
        i64 iff = node_new(N_IF, line, fl);
        set_nd_a(iff, ph_truthy(pr));                // NOT (u8): see ph_truthy
        set_nd_b(iff, ph_set(nn, ph_int(i + 1)));
        set_nd_next(tail, iff);
        tail = iff;
        i = i + 1;
    }
    return head;
}

i64 ph_stmt_1() {
    i64 line = ph_tline;
    uptr fl = ph_tfile;

    if (ph_at(";", 1)) { ph_next(); return ph_empty(); }
    if (ph_at("{", 1)) return ph_block();
    // `@$a[0] = 1;`: the suppression is the statement's, not an expression's
    // -- an assignment is a STATEMENT here, so the expression form (T7's @)
    // never saw it.
    if (ph_at("@", 1)) {
        ph_next();
        i64 on = ph_stmt_of(ph_call("php_quiet_on", 0, 0, 0, 0, 0, TY_VOID));
        i64 inner = ph_stmt_1();
        i64 off = ph_stmt_of(ph_call("php_quiet_off", 0, 0, 0, 0, 0, TY_VOID));
        i64 t = on;
        set_nd_next(t, inner);
        loop { if (!nd_next(t)) break; t = nd_next(t); }
        set_nd_next(t, off);
        i64 b = node_new(N_BLOCK, line, fl);
        set_nd_a(b, on);
        return b;
    }
    if (ph_is("list")) return ph_destructure(fl, line, 0, 1);
    if (ph_at("[", 1)) return ph_destructure(fl, line, 1, 1);
    if (ph_at("<?php", 5)) { ph_next(); return ph_empty(); }
    // `<?= EXPR ?>` IS an echo -- it was consumed and emitted nothing
    // (docs/review-backlog.md section 2). It falls into the echo branch
    // below, which already ends at `?>` (ph_semi).
    if (ph_at("?>", 2)) return ph_inline_html(fl, line);   // the cursor is just after ?>
    if (ph_tid == PHT_HTML) { ph_next(); return ph_empty(); }

    if (ph_is("echo") || ph_is("print") || ph_at("<?=", 3)) {
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
        // php's `return` at the TOP LEVEL ends the script; the ordinary
        // N_RETURN returns from the generated `main` and so jumps over
        // php_shutdown, php_flush and the exit code. The program printed
        // NOTHING and exited with a junk status -- 54, 82, 94, 142 and 178
        // on five runs of the same source, because the output buffer was
        // never written. Measured on probes/t10/bench/shim.php, and it is
        // the reason D8's mc-php half had never run under any probe.
        //
        // In the ENTRY file the answer is php's exactly: end the script,
        // run the shutdown functions and the destructors, flush, exit 0 (a
        // value returned there does not set the status). In an INCLUDED
        // file php ends the include and the CALLER CONTINUES, which an
        // inlined include cannot express, so it is refused by name rather
        // than answered wrongly.
        if (ph_toplevel) {
            i64 tlline = ph_tline;
            uptr tlfile = ph_tfile;
            ph_next();
            // php EVALUATES the expression and then ends the script, so
            // `return f();` at the top level still calls f(), and one that
            // throws still throws. Parsing it and dropping the node lost
            // every side effect it had. The VALUE is discarded -- php
            // ignores what a top-level return returns -- so it becomes an
            // expression statement in front of the exit.
            i64 tlv = 0;
            i64 tlthrow = 0;
            if (!ph_at(";", 1)) {
                i64 tsave = ph_can_throw;
                ph_can_throw = 0;
                tlv = ph_expr_stmt_of(ph_expr(0));
                tlthrow = ph_can_throw;
                ph_can_throw = ph_can_throw | tsave;
            }
            ph_semi("expected ; after return");
            // T6's rule: the check goes BETWEEN computing the value and
            // using it. Without it `try { return t(); } catch ...` with a
            // throwing t() caught the exception and STILL ended the script,
            // where php carries on after the try -- the return never
            // happened.
            // ph_tail and NOT set_nd_next: `ph_expr_stmt_of` returns the
            // PENDING CHAIN with the expression statement at its end (it
            // calls ph_wrap), so writing the head's `next` threw away
            // everything after the first pending statement. `return f() &&
            // g();` at the top level ran f() and not g(), and
            // `try { return f() && boom(); } catch` lost the check with the
            // rest of the chain and never reached the catch.
            if (tlthrow) ph_tail(tlv, ph_check(tlline, tlfile));
            if (!str_eq(ph_absfile(tlfile), ph_entry))
                ph_todo(tlfile, tlline, "a top-level return in an included file");
            // Inside a try that has a `finally`, php runs the finally FIRST.
            // Taking the exit here would jump over it, so this goes down the
            // same deferred road a `return` inside a function takes: raise
            // the flag and break out to the try's own label. The epilogue at
            // the bottom of ph_try is what turns the flag into the exit --
            // and it is the top level, so the value is not kept: php ignores
            // what a top-level return returns.
            if (ph_in_try && ph_frf) {
                i64 tsf = ph_set(ph_frf, ph_int(1));
                i64 tbo = node_new(N_BREAK, tlline, tlfile);
                set_nd_val(tbo, ph_ls_try());
                set_nd_next(tsf, tbo);
                if (tlv) { ph_tail(tlv, tsf); return ph_wrap(tlv); }
                return ph_wrap(tsf);
            }
            i64 tlx = ph_expr_stmt_of(ph_c1("php_exit", ph_int(0), TY_VOID));
            if (tlv) { ph_tail(tlv, tlx); return ph_wrap(tlv); }
            return ph_wrap(tlx);
        }
        ph_next();
        i64 e = 0;
        i64 rthrow = 0;
        if (!ph_at(";", 1)) {
            i64 sctr = ph_can_throw;
            ph_can_throw = 0;
            e = ph_expr(0);
            if (ph_fn_ret == PT_MIXED && ph_fn_retref) e = ph_to_mixed(e, ph_ety);
            if (ph_fn_ret == PT_MIXED && !ph_fn_retref) e = ph_to_mixed(ph_own(e, ph_ety), ph_ety);
            // A declared scalar return is CHECKED: php's own rule and php's
            // own TypeError, the same php_param_coerce every declared
            // parameter goes through (argno 0 is its return-value sentence).
            // It used to be a conversion and nothing else, so
            // `function f(): int { return "x"; }` answered int(0). The one
            // mismatch that is never an error, int where float is declared,
            // stays a plain widening.
            i64 rw = 0;
            if (ph_fn_ret == PT_INT)    rw = 1;
            if (ph_fn_ret == PT_FLOAT)  rw = 2;
            if (ph_fn_ret == PT_STRING) rw = 3;
            if (ph_fn_ret == PT_BOOL)   rw = 4;
            if (rw && ph_ety != ph_fn_ret) {
                if (rw == 2 && ph_ety == PT_INT) e = ph_to_float(e, ph_ety);
                if (!(rw == 2 && ph_ety == PT_INT)) {
                    u8 rca[48];
                    st64(rca, ph_to_mixed(e, ph_ety));
                    st64(rca + 8, ph_int(rw));
                    st64(rca + 16, ph_strlit("", 0));
                    st64(rca + 24, ph_strlit(ph_cur_fn, cstrlen(ph_cur_fn)));
                    st64(rca + 32, ph_int(0));
                    st64(rca + 40, ph_strlit("", 0));
                    e = ph_calln("php_param_coerce", rca, 6, ty_pzv);
                    if (rw == 1) e = ph_to_int(e, PT_MIXED);
                    if (rw == 2) e = ph_to_float(e, PT_MIXED);
                    if (rw == 3) e = ph_to_str(e, PT_MIXED);
                    if (rw == 4) e = ph_to_bool(e, PT_MIXED);
                }
            }
            rthrow = ph_can_throw;
            ph_can_throw = ph_can_throw | sctr;
        }
        // `return;` in a function with a declared return type is php's
        // COMPILE-TIME fatal, not a value: the native return had nothing to
        // carry and answered whatever the register held (the review of #19)
        if (!e && ph_fn_ret != PT_MIXED && ph_fn_ret != PT_VOID && ph_fn_ret != PT_NULL)
            ph_phpfatal_x(fl, line, "A function with return type must return a value", 1);
        if (!e && ph_fn_ret == PT_MIXED) e = ph_call("php_znull", 0, 0, 0, 0, 0, ty_pzv);
        ph_semi("expected ; after return");
        // T8: the unwinding check has to go BETWEEN computing the value and
        // returning it -- T6's own rule, which the return statement did not
        // follow. After the return nothing runs, so `return f();` inside a
        // try left the exception pending and the catch beside it never saw
        // it (measured with a ValueError a library row raises).
        i64 rck = 0;
        if (rthrow) {
            // the value FIRST, then the check, then whatever leaving this
            // function means here -- which is not always a `return`: inside a
            // try with a finally beside it, it is the flag and the break
            // below, and a direct return there would jump over the finally
            i64 tmp = ph_temp(e, ph_mcty(ph_fn_ret), "phrt_");
            rck = ph_check(line, fl);
            e = ph_tref(tmp);
        }
        if (ph_in_try && ph_frf) {
            // the value and the flag, then out to the try's own loop: the
            // finally beside it is the next statement and runs as it should
            i64 sv = ph_set(ph_frv, e);
            i64 sf = ph_set(ph_frf, ph_int(1));
            i64 bo = node_new(N_BREAK, line, fl);
            set_nd_val(bo, ph_ls_try());
            set_nd_next(sv, sf);
            set_nd_next(sf, bo);
            return ph_wrap(ph_prefix_stmts(rck, sv));
        }
        i64 r = node_new(N_RETURN, line, fl);
        set_nd_a(r, e);
        return ph_wrap(ph_prefix_stmts(rck, r));
    }
    if (ph_is("if")) return ph_if(fl, line);
    if (ph_is("while")) {
        ph_next();
        ph_want("(", 1, "expected ( after while");
        i64 c = ph_cond_checked(ph_to_bool(ph_expr(0), ph_ety), line, fl);
        i64 cpre = ph_take_pend();
        ph_want(")", 1, "expected ) after while");
        i64 alt = ph_accept(":", 1);
        ph_ls_push(0);
        i64 body = 0;
        if (alt) { body = ph_alt_body("endwhile", 0); ph_alt_end("endwhile"); }
        if (!alt) body = ph_block_or_stmt();
        ph_ls_pop();
        ph_cpre = cpre;
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
        i64 c = ph_cond_checked(ph_to_bool(ph_expr(0), ph_ety), line, fl);
        // The condition's own statements -- the unwinding check
        // ph_cond_checked pends, an array literal, a `($n = f())` -- belong
        // INSIDE the loop, between the body and the test, and run on every
        // iteration. `while` and `for` take them with ph_take_pend; `do` did
        // not, so the statement parser drained them and they landed BEFORE
        // the loop: the check then ran once and `do { } while (t());` with a
        // throwing t() spun for ever (probes/t10/g/64-exception-stops.php,
        // measured: the fixture had to be killed).
        i64 cpre = ph_take_pend();
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
        // The test goes at the TOP of the loop behind a first-iteration
        // gate, and NOT after the body. mc's `continue` jumps to the top of
        // the N_LOOP, so a test placed after the body is skipped by it:
        // `do { $i++; continue; } while ($i < 1);` spun for ever where php
        // terminates. This is ph_loop_of's own gate, for the condition
        // rather than for the step -- every edge into the next iteration,
        // the fall-through and every `continue`, passes through it.
        ph_nonce = ph_nonce + 1;
        uptr dfn = p_cat("phd_f", php_dec(ph_nonce), 0, cstrlen(php_dec(ph_nonce)));
        ph_local(dfn, TY_I64);
        i64 dpre = ph_set(dfn, ph_int(1));
        i64 dref = node_new(N_IDENT, line, fl);
        set_nd_name(dref, dfn);
        set_nd_type(dref, TY_I64);
        i64 dclr = ph_set(dfn, ph_int(0));
        i64 dtest = iff;
        if (cpre) {
            i64 ct = cpre;
            loop { if (!nd_next(ct)) break; ct = nd_next(ct); }
            set_nd_next(ct, iff);
            dtest = cpre;
        }
        i64 dgate = node_new(N_IF, line, fl);
        set_nd_a(dgate, dref);
        set_nd_b(dgate, dclr);
        set_nd_c(dgate, ph_blk(dtest));
        set_nd_next(dgate, body);
        i64 b = node_new(N_BLOCK, line, fl);
        set_nd_a(b, dgate);
        i64 lp = node_new(N_LOOP, line, fl);
        set_nd_a(lp, b);
        set_nd_next(dpre, lp);
        i64 ob = node_new(N_BLOCK, line, fl);
        set_nd_a(ob, dpre);
        return ob;
    }
    if (ph_is("for")) {
        ph_next();
        ph_want("(", 1, "expected ( after for");
        // Each of the three parts is checked on its OWN mark. T6's rule is
        // that the check goes between computing a value and using it, and
        // each part computes one the next part uses: the initializer's is
        // read by the condition, the step's by the condition of the NEXT
        // iteration. Before the rule above, every one of them was covered by
        // accident -- php_pos set ph_can_throw for every statement, so
        // ph_cond_checked always fired and the check it put in the loop head
        // stood in for all three. The step is where that mattered: it is
        // parsed AFTER the condition, so its mark cannot reach
        // ph_cond_checked however the flag travels, and
        // `for ($m = 0; $m < 3; $m = boom())` ran the body a second time
        // with the exception pending (tests/g/94-for-init-throws.php, found
        // by the reviewer of #16).
        i64 fsave = ph_can_throw;
        i64 fany = 0;       // any part can raise: the for announces its line
        ph_can_throw = 0;
        // ph_stmt() consumes the initializer's own `;`, so the separator is
        // consumed here only when there is no initializer -- consuming it
        // after one ate the EMPTY condition's `;` and refused valid php:
        // `for ($i = 0;; $i++)` said "expected ; in for".
        i64 init = ph_empty();
        if (ph_at(";", 1)) ph_next();
        else init = ph_stmt();
        if (ph_can_throw) {
            i64 it = init;
            loop { if (!nd_next(it)) break; it = nd_next(it); }
            set_nd_next(it, ph_check(line, fl));
        }
        fany = fany | ph_can_throw;
        ph_can_throw = 0;
        i64 c = ph_bool(1);
        if (!ph_at(";", 1)) c = ph_cond_checked(ph_to_bool(ph_expr(0), ph_ety), line, fl);
        // the CONDITION's own statements run every iteration, not once
        i64 cpre2 = ph_take_pend();
        ph_want(";", 1, "expected ; in for");
        fany = fany | ph_can_throw;
        ph_can_throw = 0;
        i64 step = 0;
        if (!ph_at(")", 1)) {
            step = ph_assign_stmt(fl, line, 0);         // $i++ / $i += e, no ;
        }
        // in a BLOCK, because ph_loop_of hangs the step off an N_IF's branch
        // and a branch is one node, not a chain: appended with set_nd_next the
        // check was silently dropped, which the probe of the same fixture said
        // before this line was written.
        if (ph_can_throw && step) {
            i64 pt = step;
            loop { if (!nd_next(pt)) break; pt = nd_next(pt); }
            set_nd_next(pt, ph_check(line, fl));
            step = ph_blk(step);
        }
        // Each part's own check is placed above; what goes up is whether ANY
        // part can raise, so the statement still announces its position and a
        // diagnostic from the condition names the for's line and not the
        // previous statement's (found by the reviewer of #16).
        ph_can_throw = fany | ph_can_throw | fsave;
        ph_want(")", 1, "expected ) after for");
        i64 fopre = ph_take_pend();
        i64 alt = ph_accept(":", 1);
        ph_ls_push(0);
        i64 body = 0;
        if (alt) { body = ph_alt_body("endfor", 0); ph_alt_end("endfor"); }
        if (!alt) body = ph_block_or_stmt();
        ph_ls_pop();
        ph_cpre = cpre2;
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
        // mc-php is strict by definition (D4): strict_types=1 says what it
        // already does and is a no-op; strict_types=0 asks for the coercions
        // D4 rules out, so it is refused rather than ignored. `st` counts the
        // tokens since `strict_types`: the value is the third, after `=`.
        i64 st = 0;
        loop {
            if (ph_at(")", 1)) break;
            if (ph_tid == T_EOF) break;
            if (ph_tid == T_IDENT && str_eq(ph_tname, "strict_types")) st = 1;
            if (st == 3 && ph_tid == T_INT && ph_tval == 0)
                ph_refuse(fl, line, "declare(strict_types=0)", "D4");
            if (st) st = st + 1;
            ph_next();
        }
        ph_want(")", 1, "expected ) after declare");
        ph_accept(";", 1);
        return ph_empty();
    }
    if (ph_is("namespace") || ph_is("use")) {
        // A namespace is FLATTENED on the program road (T9), which costs a
        // program nothing but would make an EXTENSION publish `f` where the
        // source says `aw\f` -- and docs/mcphp-toml.md promises the module
        // obeys the source's own namespace. Refused by name until it does.
        if (ph_ext && ph_is("namespace"))
            ph_todo(fl, line, "a namespace in an extension source");
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
            if (ph_var_find(d) < 0) ph_bind_undef(d, fl, line, 1);
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
        i64 alts = ph_accept(":", 1);
        if (!alts) ph_want("{", 1, "expected { after switch");
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
            if (alts && ph_is("endswitch")) break;
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
                if (alts && ph_is("endswitch")) break;
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
        if (alts) ph_alt_end("endswitch");
        if (!alts) ph_next();
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
        // the two locals a `return` inside this try (or a catch of it) hands
        // its value to, so the finally still runs. One pair per function;
        // created by the first try that needs them.
        i64 frpre = 0;
        if (!ph_frf) {
            ph_nonce = ph_nonce + 1;
            uptr dg = php_dec(ph_nonce);
            ph_frf = p_cat("phff_", dg, 0, cstrlen(dg));
            ph_local(ph_frf, TY_I64);
            // The VALUE local exists only inside a function. At the top
            // level php IGNORES what a `return` returns and the generated
            // `main` has nothing to hand it to, so the flag alone is what
            // the epilogue reads -- and the flag is what was missing: it was
            // not created at the top level at all, so a `return` inside a
            // top-level try raised nothing and the script carried on past
            // the try without running its finally.
            if (!ph_toplevel) {
                ph_frv = p_cat("phfv_", dg, 0, cstrlen(dg));
                ph_local(ph_frv, ph_mcty(ph_fn_ret));
            }
        }
        frpre = ph_set(ph_frf, ph_int(0));
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
            // php runs the finally on the way out of a `return` in a CATCH
            // as well, and the catch body is not inside the try's loop --
            // so it gets one of its own (docs/review-backlog.md section 2).
            i64 scin = ph_in_try;
            ph_in_try = 1;
            ph_ls_push(1);
            i64 cbody = ph_block();
            ph_ls_pop();
            ph_in_try = scin;
            i64 cbrk = node_new(N_BREAK, line, fl);
            set_nd_val(cbrk, 1);
            i64 cbt = nd_a(cbody);
            if (!cbt) set_nd_a(cbody, cbrk);
            if (cbt) { loop { if (!nd_next(cbt)) break; cbt = nd_next(cbt); } set_nd_next(cbt, cbrk); }
            i64 clp = node_new(N_LOOP, line, fl);
            set_nd_a(clp, cbody);
            cbody = clp;
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
        // a `return` the try or a catch deferred: do it now, or -- when this
        // try is itself inside one -- break out so the outer finally runs too.
        // At the TOP LEVEL the deferred action is php's end-of-script and not
        // a return from the generated `main`: it was skipped entirely here,
        // so a `return` inside a top-level try raised a flag nothing read and
        // the script simply carried on past the try.
        if (ph_frf) {
            i64 fr = node_new(N_IDENT, line, fl);
            set_nd_name(fr, ph_frf);
            set_nd_type(fr, TY_I64);
            i64 act = 0;
            i64 outl = ph_ls_try();
            if (outl) { act = node_new(N_BREAK, line, fl); set_nd_val(act, outl); }
            if (!outl && ph_toplevel)
                act = ph_expr_stmt_of(ph_c1("php_exit", ph_int(0), TY_VOID));
            if (!outl && !ph_toplevel) {
                act = node_new(N_RETURN, line, fl);
                i64 rv = node_new(N_IDENT, line, fl);
                set_nd_name(rv, ph_frv);
                set_nd_type(rv, ph_mcty(ph_fn_ret));
                if (ph_fn_ret != PT_VOID) set_nd_a(act, rv);
            }
            i64 fif = node_new(N_IF, line, fl);
            set_nd_a(fif, ph_cast(TY_U8, fr));
            set_nd_b(fif, act);
            set_nd_next(t, fif);
            t = fif;
        }
        ph_can_throw = 1;
        i64 ob = node_new(N_BLOCK, line, fl);
        set_nd_a(ob, head);
        if (frpre) { set_nd_next(frpre, head); set_nd_a(ob, frpre); }
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
    i64 c = ph_cond_checked(ph_to_bool(ph_expr(0), ph_ety), line, fl);
    ph_want(")", 1, "expected ) after if");
    i64 alt = ph_accept(":", 1);
    i64 pre = ph_pend_head;
    i64 pret = ph_pend_tail;
    ph_pend_head = 0;
    ph_pend_tail = 0;
    i64 t = 0;
    if (alt) t = ph_alt_body("endif", 1);
    if (!alt) t = ph_block_or_stmt();
    i64 e = 0;
    if (ph_is("elseif")) e = ph_if(ph_tfile, ph_tline);
    if (!e) {
        if (ph_is("else")) {
            ph_next();
            if (ph_is("if")) e = ph_if(ph_tfile, ph_tline);
            if (!e && alt) { ph_accept(":", 1); e = ph_alt_body("endif", 0); }
            if (!e) e = ph_block_or_stmt();
        }
    }
    // the chain's OUTERMOST if closes it: an elseif recursion already did
    if (alt && ph_is("endif")) ph_alt_end("endif");
    // An elseif is an N_IF whose ELSE is the next if -- and ph_wrap hands that
    // one back as a statement LIST when its condition needed statements of
    // its own (a string comparison, any call). The else branch is ONE node,
    // so the list's tail -- the if itself -- was dropped: `if ($c === ".")
    // {} elseif ($c === "1") { ... }` never took the second branch (found by
    // examples/decimal). A block keeps the whole list.
    if (e && nd_next(e)) {
        i64 eb = node_new(N_BLOCK, line, fl);
        set_nd_a(eb, e);
        e = eb;
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
    i64 altfe = ph_accept(":", 1);

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
    i64 body = 0;
    if (altfe) { body = ph_alt_body("endforeach", 0); ph_alt_end("endforeach"); }
    if (!altfe) body = ph_block_or_stmt();
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



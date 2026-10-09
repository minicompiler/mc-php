// expr.mc -- the expression grammar, which is the module's own.
// 
// php's precedence is not mc's, so the module reads expressions itself
// (probes/t4's finding) rather than calling parse_expr. The precedence table
// is php's, in the subset this compiler reads.

// ---- the expression grammar (the module's own -- T4's finding) -------------
i64 ph_ety;                     // the php type of the node ph_expr just returned
i64 ph_fn_ret;                  // the php return type of the function being parsed
i64 ph_efresh;                  // the value is a brand-new array: no copy needed


i64 ph_digit(i64 c, i64 base) {
    i64 d = -1;
    if (c >= 48 && c <= 57)  d = c - 48;
    if (c >= 97 && c <= 102) d = c - 87;
    if (c >= 65 && c <= 70)  d = c - 55;
    if (d < 0) return -1;
    if (d >= base) return -1;
    return d;
}

// the number formats the core lexer stops short of: 0b / 0o / 1_000 / 1.5 /
// 1e3 / 0x1F. p_cp() is the cursor, p_take_lit(q) says where the literal ends.
i64 ph_number() {
    i64 v = ph_tval;
    uptr q = p_cp();
    uptr e = p_src_end();
    i64 base = 0;
    if (v == 0 && q < e) {
        i64 c0 = ld8(q);
        if (c0 == 98 || c0 == 66)  base = 2;
        if (c0 == 111 || c0 == 79) base = 8;
    }
    // php's LEGACY octal: a leading 0 followed by a digit. The core lexer read
    // it as decimal, so the digits have to be re-read from the source.
    if (!base && ld8(p_start()) == 48) {
        uptr r = p_start() + 1;
        if (r < q && ph_digit(ld8(r), 8) >= 0) {
            i64 oct = 0;
            loop {
                if (r >= q) break;
                i64 c1 = ld8(r);
                if (c1 == 95) { r = r + 1; continue; }
                i64 d1 = ph_digit(c1, 8);
                if (d1 < 0) break;
                oct = oct * 8 + d1;
                r = r + 1;
            }
            p_take_lit(q);
            ph_next();
            ph_ety = PT_INT;
            return ph_int(oct);
        }
    }
    if (base) {
        q = q + 1;
        i64 acc = 0;
        i64 nd = 0;
        loop {
            if (q >= e) break;
            i64 c = ld8(q);
            if (c == 95) { q = q + 1; continue; }
            i64 d = ph_digit(c, base);
            if (d < 0) break;
            acc = acc * base + d;
            nd = nd + 1;
            q = q + 1;
        }
        if (!nd) err_at(ph_tfile, ph_tline, "mc-php: a php integer literal with no digits");
        p_take_lit(q);
        ph_next();
        ph_ety = PT_INT;
        return ph_int(acc);
    }
    // legacy octal 0777 and 0o777 aside, the core already gave us the decimal
    // or hex value in ph_tval; what is left is _ separators and the float tail.
    i64 ipart = v;
    loop {
        if (q >= e) break;
        if (ld8(q) != 95) break;
        q = q + 1;
        loop {
            if (q >= e) break;
            i64 d = ph_digit(ld8(q), 10);
            if (d < 0) break;
            ipart = ipart * 10 + d;
            q = q + 1;
        }
    }
    i64 isf = 0;
    if (q < e) {
        i64 c = ld8(q);
        if (c == 101 || c == 69) isf = 1;
        if (c == 46) { if (q + 1 >= e) isf = 1; if (q + 1 < e && ph_digit(ld8(q + 1), 10) >= 0) isf = 1; }
    }
    if (!isf) {
        p_take_lit(q);
        ph_next();
        ph_ety = PT_INT;
        return ph_int(ipart);
    }
    // a float literal: scan the whole lexeme and hand the text to the runtime's
    // own strtod, so the compiler needs no decimal-to-binary of its own.
    uptr s0 = p_start();
    loop {
        if (q >= e) break;
        i64 c = ld8(q);
        if (c == 46 || c == 95) { q = q + 1; continue; }
        if (ph_digit(c, 10) >= 0) { q = q + 1; continue; }
        if (c == 101 || c == 69) {
            q = q + 1;
            if (q < e && (ld8(q) == 43 || ld8(q) == 45)) q = q + 1;
            continue;
        }
        break;
    }
    i64 tl = q - s0;
    uptr txt = xstrdup(s0, tl);
    p_take_lit(q);
    ph_next();
    ph_ety = PT_FLOAT;
    return ph_c1("php_stof", ph_strlit(txt, tl), ty_f64);
}

// "a $x b {$y}": the core hands over ONE T_STR with the escapes already
// decoded, so the module re-scans it for the `$`.
i64 ph_interp(uptr raw, i64 n) {
    i64 acc = 0;
    i64 seg = 0;
    i64 i = 0;
    loop {
        if (i >= n) break;
        i64 c = ld8(raw + i);
        i64 j = 0;
        i64 brace = 0;
        if (c == 123 && i + 1 < n && ld8(raw + i + 1) == 36) { brace = 1; j = i + 2; }
        if (c == 36) j = i + 1;
        if (!j) { i = i + 1; continue; }
        i64 k = j;
        loop {
            if (k >= n) break;
            i64 d = ld8(raw + k);
            i64 ok = 0;
            if (d >= 97 && d <= 122) ok = 1;
            if (d >= 65 && d <= 90)  ok = 1;
            if (d >= 48 && d <= 57)  ok = 1;
            if (d == 95) ok = 1;
            if (!ok) break;
            k = k + 1;
        }
        if (k == j) { i = i + 1; continue; }
        i64 after = k;
        if (brace) {
            if (k >= n || ld8(raw + k) != 125) { i = i + 1; continue; }
            after = k + 1;
        }
        if (i > seg) {
            i64 lit = ph_strlit(xstrdup(raw + seg, i - seg), i - seg);
            if (acc) acc = ph_c2("php_str_concat", acc, lit, ty_pstr);
            if (!acc) acc = lit;
        }
        uptr d2 = xalloc(k - j + 2);
        st8(d2, 36);
        i64 z = 0;
        loop { if (z >= k - j) break; st8(d2 + 1 + z, ld8(raw + j + z)); z = z + 1; }
        st8(d2 + 1 + (k - j), 0);
        i64 vt = PT_MIXED;
        i64 v = 0;
        if (ph_var_find(d2) < 0) v = ph_c1("php_undef_var", ph_raw(d2 + 1, cstrlen(d2) - 1), ty_pzv);
        if (!v) {
            v = ph_var_node(d2, 0);
            vt = ph_ety;
        }
        i64 sv = ph_to_str(v, vt);
        if (acc) acc = ph_c2("php_str_concat", acc, sv, ty_pstr);
        if (!acc) acc = sv;
        seg = after;
        i = after;
    }
    if (!acc) return ph_strlit(xstrdup(raw, n), n);
    if (n > seg) {
        i64 lit2 = ph_strlit(xstrdup(raw + seg, n - seg), n - seg);
        acc = ph_c2("php_str_concat", acc, lit2, ty_pstr);
    }
    return acc;
}

// an array literal: [1, 2, 3], ["k" => $v], array(...), mixed elements, any
// key php accepts. Every value is a zval, so nothing here is homogeneous.
i64 ph_array_lit(uptr close) {
    ph_nonce = ph_nonce + 1;
    uptr an = p_cat("pha_", php_dec(ph_nonce), 0, cstrlen(php_dec(ph_nonce)));
    i64 head = 0;
    i64 tail = 0;
    i64 n = 0;
    loop {
        if (ph_at(close, 1)) break;
        i64 spread = 0;
        if (ph_at("...", 3)) { ph_next(); spread = 1; }
        i64 v = ph_expr(0);
        i64 vt = ph_ety;
        i64 k = 0;
        if (ph_at("=>", 2)) {
            ph_next();
            k = ph_zkey(v, vt);
            if (ph_at("&", 1)) ph_todo(ph_tfile, ph_tline, "an array element by reference");
            v = ph_expr(0);
            vt = ph_ety;
        }
        i64 aref = node_new(N_IDENT, ph_tline, ph_tfile);
        set_nd_name(aref, an);
        set_nd_type(aref, ty_parr);
        i64 push = 0;
        if (spread) push = ph_c2("php_arr_spread", aref, ph_to_mixed(v, vt), TY_VOID);
        if (!spread && k)  push = ph_c3("php_arr_set", aref, k, ph_to_mixed(v, vt), TY_VOID);
        if (!spread && !k) push = ph_c2("php_arr_push", aref, ph_to_mixed(v, vt), TY_VOID);
        i64 st = node_new(N_EXPRSTMT, ph_tline, ph_tfile);
        set_nd_a(st, push);
        if (tail) set_nd_next(tail, st);
        if (!tail) head = st;
        tail = st;
        n = n + 1;
        if (!ph_accept(",", 1)) break;
    }
    ph_want(close, 1, "expected the end of a php array literal");
    // A literal is a LOCAL plus a run of inserts emitted before the statement
    // that contains it (ph_pending_stmt), and the expression is the local --
    // mc has no comma operator and this needs none.
    ph_local(an, ty_parr);
    i64 cap = 8;
    loop { if (cap >= n) break; cap = cap * 2; }
    i64 mk = ph_set(an, ph_c1("php_arr_new", ph_int(cap), ty_parr));
    set_nd_next(mk, head);
    ph_pending_stmt(mk);
    i64 out = node_new(N_IDENT, ph_tline, ph_tfile);
    set_nd_name(out, an);
    set_nd_type(out, ty_parr);
    ph_ety = PT_ARR;
    ph_efresh = 1;
    return out;
}

// statements an expression needs emitted BEFORE it (an array literal builds
// itself with a run of pushes). The statement parser drains this.
i64 ph_pend_head;
i64 ph_pend_tail;

// take the pending statements out of the way before parsing a BODY, which
// would otherwise steal them into itself (a foreach over an array literal
// would then rebuild the array inside its own loop)
i64 ph_take_pend() {
    i64 h = ph_pend_head;
    ph_pend_head = 0;
    ph_pend_tail = 0;
    return h;
}

// put a chain taken out with ph_take_pend back as the pending queue
void ph_put_pend(i64 h) {
    ph_pend_head = 0;
    ph_pend_tail = 0;
    if (h) ph_pending_stmt(h);
}

// a block holding a chain of statements: what a short circuit's branch needs,
// because the right side of `&&` carries pending statements of its own
i64 ph_blk(i64 head) {
    i64 b = node_new(N_BLOCK, ph_tline, ph_tfile);
    set_nd_a(b, head);
    return b;
}

// append `n` after the LAST statement of the chain `head`
void ph_tail(i64 head, i64 n) {
    i64 t = head;
    loop { if (!nd_next(t)) break; t = nd_next(t); }
    set_nd_next(t, n);
}

i64 ph_prefix_stmts(i64 pre, i64 s) {
    if (!pre) return s;
    i64 t = pre;
    loop { if (!nd_next(t)) break; t = nd_next(t); }
    set_nd_next(t, s);
    return pre;
}

void ph_pending_stmt(i64 s) {
    i64 t = s;
    loop { if (!nd_next(t)) break; t = nd_next(t); }
    if (ph_pend_tail) set_nd_next(ph_pend_tail, s);
    if (!ph_pend_tail) ph_pend_head = s;
    ph_pend_tail = t;
}

// Reading a variable with neither a declaration nor a first assignment is the
// one place T6 said D4 had no answer. php's answer is a WARNING and null, and
// null is a value of `mixed`, which D4 (c) already lowers to a zval -- so the
// read is expressible without the variable gaining a type: a later `$x = 5`
// still declares $x an int. The refusal is retired.
i64 ph_var_ref(uptr d) {
    if (ph_var_find(d) < 0) {
        ph_ety = PT_MIXED;
        // `$x ?? d` reads without warning, and the token after the name is
        // what says so -- the same test ph_index makes after its `]`.
        if (ph_at("??", 2)) return ph_call("php_znull", 0, 0, 0, 0, 0, ty_pzv);
        return ph_c1("php_undef_var", ph_raw(d + 1, cstrlen(d) - 1), ty_pzv);
    }
    return ph_var_node(d, ph_at("??", 2));
}

// a bound variable's value. At the top level a name bound to the global table
// (ph_gtop_has) reads through php_gread, php's warning for an entry no one
// assigned -- except under `??` (quiet), which asks without one
i64 ph_var_node(uptr d, i64 quiet) {
    i64 t = ph_var_type(d);
    i64 n = node_new(N_IDENT, ph_tline, ph_tfile);
    set_nd_name(n, ph_mangle(d, "v_"));
    set_nd_type(n, ph_mcty(t));
    ph_ety = t;
    if (!quiet && ph_toplevel && ph_gtop_has(d))
        return ph_c2("php_gread", n, ph_raw(d + 1, cstrlen(d) - 1), ty_pzv);
    return n;
}

// a string offset read, on either semantics (ph_index)
i64 ph_is_stroff(uptr n) {
    return str_eq(n, "php_str_off") || str_eq(n, "php_str_off_c") || str_eq(n, "php_str_off_d");
}

// a negative integer literal as the source spelled it: `-1` or `(-1)`
i64 ph_neg_lit(i64 n) {
    if (nd_kind(n) == N_INT) return nd_val(n) < 0;
    // `-1` is `0 - 1` here (the unary minus, just above)
    if (nd_kind(n) == N_BINARY && nd_op(n) == ph_tok("-", 1) && nd_kind(nd_a(n)) == N_INT
        && nd_val(nd_a(n)) == 0 && nd_kind(nd_b(n)) == N_INT) return nd_val(nd_b(n)) > 0;
    return 0;
}

// $a[i] / $s[i] on the right-hand side. An array element is a zval, which is
// what makes an array heterogeneous (D4 (d)); a string offset is a string.
i64 ph_index(i64 base, i64 bt) {
    if (bt == PT_STRING) {
        i64 i = ph_to_int(ph_expr(0), ph_ety);
        ph_want("]", 1, "expected ] after a php string offset");
        ph_ety = PT_STRING;
        // out of range is php's warning and "" (php_str_off); in range it
        // allocates nothing. `$s[$i] ?? d` is isset's quiet read, whose
        // absent offset is null, so the default is taken as php takes it.
        if (ph_at("??", 2)) { ph_ety = PT_MIXED; return ph_quiet("php_str_off_q", 2, base, i, 0, 0, ty_pzv); }
        // C semantics (docs/semantics.md): the read, unchecked -- except an
        // offset the source spells as a negative literal, which is php's
        // count-from-the-end and not a read outside the string
        if (!ph_neg_lit(i)) {
            if (ph_checked_reads) return ph_c2("php_str_off_d", base, i, ty_pstr);
            return ph_quiet("php_str_off_c", 2, base, i, 0, 0, ty_pstr);
        }
        return ph_c2("php_str_off", base, i, ty_pstr);
    }
    i64 kx = ph_expr(0);
    i64 kt = ph_ety;
    ph_want("]", 1, "expected ] after a php array index");
    ph_ety = PT_MIXED;
    if (bt == PT_PK) {
        if (kt != PT_INT) ph_pk_disagree(ph_tfile, ph_tline, "a key that is not an int");
        if (ph_at("??", 2)) return ph_c2("php_pk_getq", base, kx, ty_pzv);
        // an element is an int: C's read answers what the buffer holds
        ph_ety = PT_INT;
        if (ph_checked_reads) return ph_c2("php_pk_get_d", base, kx, TY_I64);
        // a FIXED array (src/packed.mc) is never a hash: the buffer's element
        // a STABLE one (src/packed.mc) through its buffer pointer's local
        if (ph_pk_stable(base)) return ph_quiet("php_pk_get_fd", 2, ph_pk_dref(base), kx, 0, 0, TY_I64);
        if (ph_pk_fixed(base)) return ph_quiet("php_pk_get_f", 2, base, kx, 0, 0, TY_I64);
        return ph_quiet("php_pk_get_c", 2, base, kx, 0, 0, TY_I64);
    }
    // an int key on an array needs no key zval: php_arr_iget(_w) is the
    // IS_LONG arm of php_arr_zget(_w), word for word
    if (bt == PT_ARR && kt == PT_INT) {
        if (ph_at("??", 2)) return ph_c2("php_arr_iget", base, kx, ty_pzv);
        return ph_c2("php_arr_iget_w", base, kx, ty_pzv);
    }
    i64 k = ph_zkey(kx, kt);
    // php's `??` is a FETCH_DIM_IS and warns for nothing it reads; the one
    // thing that tells this read apart from any other is the token after the
    // closing bracket, and it is right here.
    if (bt == PT_MIXED) {
        if (ph_at("??", 2)) return ph_c2("php_arr_zget", ph_c1("php_zv_arr_r", base, ty_parr), k, ty_pzv);
        return ph_c2("php_zv_dim_rd", base, k, ty_pzv);
    }
    if (ph_at("??", 2)) return ph_c2("php_arr_zget", base, k, ty_pzv);
    return ph_c2("php_arr_zget_w", base, k, ty_pzv);
}

// the postfix chain every expression can carry: [ ], and (from T6's object
// block) -> and ::. It is one function so a call, a literal and a variable all
// get the same one.
i64 ph_postfix(i64 v, i64 vt) {
    loop {
        if (ph_at("[", 1)) {
            // php reads an offset of a scalar as null with a warning; D4
            // knows the static type, so the conversion to a zval is the
            // compiler's and the warning is the runtime's.
            if (vt != PT_ARR && vt != PT_MIXED && vt != PT_STRING && vt != PT_PK) {
                v = ph_to_mixed(v, vt);
                vt = PT_MIXED;
            }
            ph_next();
            if (ph_at("]", 1)) err_at(ph_tfile, ph_tline, "mc-php: cannot use [] for reading");
            v = ph_index(v, vt);
            vt = ph_ety;
            continue;
        }
        if (ph_at("->", 2) || ph_at("?->", 3)) {
            i64 ns = ph_at("?->", 3);
            ph_next();
            if (ph_at("$", 1) || ph_at("{", 1))
                ph_refuse(ph_tfile, ph_tline, "a property name that is not a literal", "D6");
            if (ph_tid != T_IDENT) err_at2(ph_tfile, ph_tline, "mc-php: a php property needs a name", ph_tname);
            uptr pn = ph_tname;
            uptr fl2 = ph_tfile;
            i64 line2 = ph_tline;
            ph_next();
            i64 recv = ph_recv(v, vt);
            i64 iscall = 0;
            if (ph_at("(", 1)) iscall = 1;
            // `($o->p = v)`: php's assignment is an expression here too. The
            // store is a pending statement, the receiver computed once, and
            // the value is the property READ back -- what the write left in
            // it, a typed property's coerced value included
            if (!iscall && !ns && ph_at("=", 1) && !ph_at("==", 2) && !ph_at("=>", 2) && !ph_at("===", 3)) {
                ph_next();
                if (ph_at("&", 1)) ph_todo(fl2, line2, "a reference assigned to a property inside an expression");
                i64 rtmp = ph_temp(recv, ty_pzv, "pho_");
                i64 rv = ph_expr(15);
                i64 rvt = ph_ety;
                ph_pset_at = line2;
                ph_pending_stmt(ph_expr_stmt_of(ph_pset_node(ph_tref(rtmp), pn, ph_to_mixed(ph_own(rv, rvt), rvt), ph_pset_kind(0, fl2))));
                ph_pending_stmt(ph_check(line2, fl2));    // a refused store unwinds before the read
                v = ph_tref(ph_temp(ph_c1("php_zv_val", ph_c3("php_zv_pget", ph_tref(rtmp), ph_strlit(pn, cstrlen(pn)), ph_scope(), ty_pzv), ty_pzv), ty_pzv, "phov_"));
                vt = PT_MIXED;
                continue;
            }
            // `$o->p++` / `$o->p--`: the OLD value is the answer, copied first
            if (!iscall && !ns && (ph_at("++", 2) || ph_at("--", 2))) {
                i64 pup = ph_at("++", 2);
                ph_next();
                i64 rtq = ph_temp(recv, ty_pzv, "pho_");
                i64 old = ph_temp(ph_c1("php_zv_val", ph_c3("php_zv_pget", ph_tref(rtq), ph_strlit(pn, cstrlen(pn)), ph_scope(), ty_pzv), ty_pzv), ty_pzv, "phov_");
                uptr fo = "php_zv_inc";
                i64 ok = 1;
                if (!pup) { fo = "php_zv_dec"; ok = -1; }
                ph_pset_at = line2;
                ph_pending_stmt(ph_expr_stmt_of(ph_pset_node(ph_tref(rtq), pn, ph_c1(fo, ph_tref(old), ty_pzv), ph_pset_kind(ok, fl2))));
                ph_pending_stmt(ph_check(line2, fl2));
                v = ph_tref(old);
                vt = PT_MIXED;
                continue;
            }
            // `$o->p op= v` in an expression: the new value is the answer
            if (!iscall && !ns) {
                i64 cop = 0;
                if (ph_at(".=", 2))  cop = ph_tok(".", 1);
                if (ph_at("+=", 2))  cop = ph_tok("+", 1);
                if (ph_at("-=", 2))  cop = ph_tok("-", 1);
                if (ph_at("*=", 2))  cop = ph_tok("*", 1);
                if (ph_at("/=", 2))  cop = ph_tok("/", 1);
                if (ph_at("%=", 2))  cop = ph_tok("%", 1);
                if (ph_at("**=", 3)) cop = ph_tok("**", 2);
                if (cop) {
                    ph_next();
                    i64 rtc = ph_temp(recv, ty_pzv, "pho_");
                    i64 cur = ph_c3("php_zv_pget", ph_tref(rtc), ph_strlit(pn, cstrlen(pn)), ph_scope(), ty_pzv);
                    i64 crv = ph_expr(15);
                    i64 crt = ph_ety;
                    i64 nv2 = 0;
                    if (cop == ph_tok(".", 1)) nv2 = ph_c2("php_zv_concat", cur, ph_to_mixed(crv, crt), ty_pzv);
                    if (cop != ph_tok(".", 1)) nv2 = ph_arith_zv(cop, cur, PT_MIXED, crv, crt);
                    ph_pset_at = line2;
                    ph_pending_stmt(ph_expr_stmt_of(ph_pset_node(ph_tref(rtc), pn, nv2, ph_pset_kind(0, fl2))));
                    ph_pending_stmt(ph_check(line2, fl2));
                    v = ph_tref(ph_temp(ph_c1("php_zv_val", ph_c3("php_zv_pget", ph_tref(rtc), ph_strlit(pn, cstrlen(pn)), ph_scope(), ty_pzv), ty_pzv), ty_pzv, "phov_"));
                    vt = PT_MIXED;
                    continue;
                }
            }
            if (iscall)  v = ph_mcall_ns(recv, pn, fl2, line2, ns);
            uptr pg = "php_zv_pget";
            if (ns) pg = "php_zv_pget_ns";                  // `$o?->p`
            if (ph_at("??", 2)) pg = "php_zv_pget_q";       // `$o->p ?? d` is silent
            if (!iscall) v = ph_c3(pg, recv, ph_strlit(pn, cstrlen(pn)), ph_scope(), ty_pzv);
            vt = PT_MIXED;
            continue;
        }
        // a callable STRING names a function to look up at run time: a
        // program has no function table to look it up in (D6), an extension
        // has php's (lib/php_ext.mc's phx_vcall)
        if (ph_at("(", 1) && vt == PT_STRING && !ph_ext) ph_refuse(ph_tfile, ph_tline, "a callable string", "D6");
        if (ph_at("(", 1) && (vt == PT_MIXED || vt == PT_OBJ || vt == PT_STRING || vt == PT_ARR)) {
            // a callable value: $f(...) and (expr)(...); an object is called
            // through its __invoke
            if (vt != PT_MIXED) v = ph_to_mixed(v, vt);
            // five slots, and the rest in a list (src/class.mc ph_margs_n)
            u8 nb[8];
            uptr ca = ph_margs_n(5, nb, ph_tfile, ph_tline);
            i64 ctl = ph_mtail;
            if (ph_fcc) {
                ph_fcc = 0;
                v = ph_c2("php_fcc", v, ph_scope(), ty_pzv);
                vt = PT_MIXED;
                continue;
            }
            u8 all[72];
            st64(all, v);
            st64(all + 8, ph_int(ld64(nb)));
            i64 i = 0;
            loop {
                if (i >= 5) break;
                st64(all + 16 + i * 8, ld64(ca + i * 8));
                i = i + 1;
            }
            v = ph_mcalln("php_call_zv", all, 7, ctl);
            vt = PT_MIXED;
            continue;
        }
        break;
    }
    ph_ety = vt;
    return v;
}

// ++/-- on a variable whose static type has none (php 8.5): a bool keeps its
// value with a warning, an array or an object is a TypeError -- what the zval
// road does in php_zv_inc/php_zv_dec. The statement that says so, or 0 for
// an int or a float, which have their arithmetic.
i64 ph_incdec_other(i64 t, i64 dec, i64 lv) {
    i64 k = 0;
    if (t == PT_BOOL) k = 1;
    if (t == PT_ARR) k = 2;
    if (t == PT_OBJ) k = 3;
    if (!k) return 0;
    i64 o = ph_int(0);
    if (k == 3) o = lv;
    return ph_expr_stmt_of(ph_c3("php_incdec_t", ph_int(k), ph_int(dec), o, TY_VOID));
}

i64 ph_primary() {
    ph_efresh = 0;
    i64 line = ph_tline;
    uptr fl = ph_tfile;

    if (ph_tid == PHT_DSTR) {
        i64 n = ph_tnode;
        ph_next();
        ph_ety = PT_STRING;
        return n;
    }
    if (ph_tid == PHT_PSTR) {
        uptr s = ph_tname;
        i64 n = ph_tlen;
        ph_next();
        ph_ety = PT_STRING;
        return ph_strlit(s, n);
    }
    if (ph_tid == T_INT) return ph_number();
    if (ph_at(".", 1)) {
        uptr q0 = p_cp();
        uptr e0 = p_src_end();
        if (q0 < e0 && ph_digit(ld8(q0), 10) >= 0) {
            uptr q = q0;
            loop { if (q >= e0) break; i64 c = ld8(q); if (ph_digit(c, 10) >= 0 || c == 95) { q = q + 1; continue; } if (c == 101 || c == 69) { q = q + 1; if (q < e0 && (ld8(q) == 43 || ld8(q) == 45)) q = q + 1; continue; } break; }
            uptr txt = xalloc(q - q0 + 4);
            st8(txt, 48);
            st8(txt + 1, 46);
            i64 z = 0;
            loop { if (z >= q - q0) break; st8(txt + 2 + z, ld8(q0 + z)); z = z + 1; }
            st8(txt + 2 + (q - q0), 0);
            p_skip_to(q);
            ph_next();
            ph_ety = PT_FLOAT;
            return ph_c1("php_stof", ph_strlit(txt, cstrlen(txt)), ty_f64);
        }
    }
    if (ph_tid == T_STR) {
        uptr s = ph_tname;
        i64 n = cstrlen(s);
        ph_next();
        ph_ety = PT_STRING;
        return ph_interp(s, n);
    }
    if (ph_at("$", 1)) {
        ph_next();
        if (ph_at("$", 1)) ph_refuse(fl, line, "a variable variable $$name", "D6");
        if (ph_at("{", 1)) ph_refuse(fl, line, "a variable variable ${expr}", "D6");
        if (!ph_wordish()) err_at2(fl, line, "mc-php: a php variable needs a name", ph_tname);
        uptr d = p_cat("$", ph_tname, 0, cstrlen(ph_tname));
        ph_next();
        if (ph_at("::", 2)) ph_refuse(fl, line, "a class name from a variable", "D6");
        // `($fp = fopen(...))` -- php's assignment IS an expression, and the
        // idiom `if (!($x = f()))` is all over the corpus. The store is a
        // pending statement (mc has no comma operator) and the value is the
        // variable, which is also what makes `$a = $b = 1` right: the inner
        // one runs first because the pendings are a queue.
        if (ph_at("=", 1) && !ph_at("==", 2) && !ph_at("=>", 2) && !ph_at("===", 3)) {
            ph_next();
            i64 byref = 0;
            if (ph_at("&", 1)) byref = 1;
            if (!byref) {
                i64 rv = ph_expr(15);
                i64 rt = ph_ety;
                i64 known = ph_var_find(d);
                // the statement's own rules (src/lvalue.mc ph_assign_stmt):
                // null makes a zval, and a mixed variable takes any value --
                // its type IS the union, so `($x = 4)` on a mixed $x is no
                // change of type and D4 has nothing to refuse
                if (rt == PT_VOID) ph_refuse(fl, line, "assigning the result of a void function", "D4");
                if (rt == PT_NULL) { rv = ph_to_mixed(rv, rt); rt = PT_MIXED; }
                if (known >= 0 && ph_var_type(d) == PT_MIXED && rt != PT_MIXED) { rv = ph_to_mixed(rv, rt); rt = PT_MIXED; }
                ph_var_bind(d, rt);
                i64 bt = ph_var_type(d);
                i64 sv = ph_own(rv, rt);
                if (bt != rt) sv = ph_to_mixed(sv, rt);
                if (known >= 0 && ph_is_ref(d)) {
                    i64 lvr = node_new(N_IDENT, line, fl);
                    set_nd_name(lvr, ph_mangle(d, "v_"));
                    set_nd_type(lvr, ty_pzv);
                    ph_pending_stmt(ph_expr_stmt_of(ph_c2("php_zv_store", lvr, ph_to_mixed(ph_own(rv, rt), rt), ty_pzv)));
                } else {
                    ph_pending_stmt(ph_set(ph_mangle(d, "v_"), sv));
                }
                i64 rr = ph_var_ref(d);
                return ph_postfix(rr, ph_ety);
            }
        }
        i64 v = ph_var_ref(d);
        return ph_postfix(v, ph_ety);
    }
    if (ph_at("(", 1)) {
        ph_next();
        // a cast: (int) (float) (string) (bool)
        if (ph_tid == T_IDENT || ph_tid == T_STR) {
            i64 ct = -1;
            if (ph_is("int") || ph_is("integer")) ct = PT_INT;
            if (ph_is("float") || ph_is("double")) ct = PT_FLOAT;
            if (ph_is("string") || ph_is("binary")) ct = PT_STRING;
            if (ph_is("bool") || ph_is("boolean")) ct = PT_BOOL;
            if (ph_is("array")) ct = PT_ARR;
            if (ph_is("object")) ct = PT_OBJ;
            // php 8.5 deprecates the long spellings while compiling
            uptr noncan = 0;
            uptr canon = 0;
            if (ph_is("integer")) { noncan = "integer"; canon = "int"; }
            if (ph_is("double"))  { noncan = "double"; canon = "float"; }
            if (ph_is("boolean")) { noncan = "boolean"; canon = "bool"; }
            if (ph_is("binary"))  { noncan = "binary"; canon = "string"; }
            uptr cfl = ph_tfile;
            i64 cline = ph_tline;
            if (ct >= 0) {
                // only a cast if the ) follows immediately
                uptr q = p_cp();
                uptr e = p_src_end();
                loop { if (q >= e) break; if (!ph_space(ld8(q))) break; q = q + 1; }
                if (q < e && ld8(q) == 41) {
                    if (noncan) {
                        uptr nm = p_cat(p_cat("Non-canonical cast (", noncan, 0, cstrlen(noncan)), ") is deprecated, use the (", 0, 26);
                        nm = p_cat(p_cat(nm, canon, 0, cstrlen(canon)), ") cast instead", 0, 14);
                        ph_cdiag(8192, nm, cfl, cline);
                    }
                    ph_next();
                    ph_next();                     // the )
                    // a cast binds as tightly as unary minus: `(int) $s - 1`
                    // is ((int) $s) - 1 in php. This read 55, which took the
                    // `+ - * / %` after the operand INTO the cast --
                    // `(int) "1.9" + 0.5` was int(2), php's float(1.5).
                    i64 v = ph_expr(70);
                    i64 vt = ph_ety;
                    ph_ety = ct;
                    // (int) substr(...): the window read as an int in
                    // place, the substring never built (php_substr_i). Only
                    // here, where the substr's value has no other reader.
                    if (ct == PT_INT && vt == PT_STRING && nd_kind(v) == N_CALL
                        && str_eq(nd_name(v), "php_substr")) {
                        set_nd_name(v, "php_substr_i");
                        set_nd_type(v, TY_I64);
                        return v;
                    }
                    if (ct == PT_INT)    return ph_to_int(v, vt);
                    if (ct == PT_FLOAT)  return ph_to_float(v, vt);
                    if (ct == PT_STRING) return ph_to_str(v, vt);
                    // (array): an array stays one, an object becomes its
                    // properties (php's mangled keys), null nothing, a scalar
                    // the one element; (object): stdClass of an array's
                    // entries, a scalar as `scalar`, an object itself
                    if (ct == PT_ARR) {
                        if (vt == PT_ARR) return v;
                        if (vt == PT_PK) ph_pk_disagree(ph_tfile, ph_tline, "a packed array cast to array");
                        ph_efresh = 1;
                        return ph_c1("php_zv_to_arr", ph_to_mixed(v, vt), ty_parr);
                    }
                    if (ct == PT_OBJ) {
                        ph_ety = PT_MIXED;
                        return ph_c1("php_zv_to_obj", ph_to_mixed(v, vt), ty_pzv);
                    }
                    return ph_to_bool(v, vt);
                }
            }
        }
        i64 e2 = ph_expr(0);
        ph_want(")", 1, "expected ) in a php expression");
        return e2;
    }
    if (ph_at("[", 1)) { ph_next(); return ph_array_lit("]"); }
    if (ph_at("-", 1)) {
        ph_next();
        i64 v = ph_expr(70);
        i64 t = ph_ety;
        if (t == PT_FLOAT) return ph_c1("php_fneg", v, ty_f64);
        // -"1.2" is float(-1.2) and -"abc" is a TypeError: a zval keeps its
        // own rules, and converting to int first threw the fraction away.
        if (t == PT_MIXED || t == PT_STRING || t == PT_NULL) {
            ph_can_throw = 1;
            ph_ety = PT_MIXED;
            return ph_c1("php_zv_neg", ph_to_mixed(v, t), ty_pzv);
        }
        i64 iv = ph_to_int(v, t);
        ph_ety = PT_INT;
        return ph_bin(ph_tok("-", 1), ph_int(0), iv, TY_I64);
    }
    if (ph_at("+", 1)) { ph_next(); i64 v = ph_expr(70); return v; }
    if (ph_at("!", 1)) {
        ph_next();
        i64 v = ph_to_bool(ph_expr(70), ph_ety);
        ph_ety = PT_BOOL;
        i64 n = node_new(N_UNARY, line, fl);
        set_nd_op(n, ph_tok("!", 1));
        set_nd_a(n, v);
        set_nd_type(n, TY_U8);
        return n;
    }
    if (ph_at("~", 1)) {
        ph_next();
        i64 v = ph_expr(70);
        i64 t = ph_ety;
        if (t == PT_MIXED || t == PT_STRING) { ph_ety = PT_MIXED; return ph_c1("php_zv_bnot", ph_to_mixed(v, t), ty_pzv); }
        ph_ety = PT_INT;
        return ph_bin(ph_tok("-", 1), ph_bin(ph_tok("-", 1), ph_int(0), ph_to_int(v, t), TY_I64), ph_int(1), TY_I64);
    }
    if (ph_at("++", 2) || ph_at("--", 2)) {
        // ++$x in expression position: the increment is a pending statement
        i64 up = 1;
        if (ph_at("--", 2)) up = 0;
        ph_next();
        if (!ph_at("$", 1)) ph_todo(fl, line, "++ on something that is not a $variable");
        ph_next();
        uptr d = p_cat("$", ph_tname, 0, cstrlen(ph_tname));
        ph_next();
        if (ph_var_find(d) < 0) ph_bind_undef(d, fl, line, 0);
        // `++$o->p`: the property incremented, its new value the answer
        if (ph_at("->", 2)) {
            ph_next();
            if (ph_tid != T_IDENT) err_at2(ph_tfile, ph_tline, "mc-php: a php property needs a name", ph_tname);
            uptr ppn = ph_tname;
            ph_next();
            if (ph_at("->", 2) || ph_at("[", 1) || ph_at("(", 1)) ph_todo(fl, line, "++ on a property of a property");
            i64 rtp = ph_temp(ph_recv(ph_var_ref(d), ph_ety), ty_pzv, "pho_");
            uptr fi = "php_zv_inc";
            if (!up) fi = "php_zv_dec";
            i64 nv = ph_c1(fi, ph_c3("php_zv_pget", ph_tref(rtp), ph_strlit(ppn, cstrlen(ppn)), ph_scope(), ty_pzv), ty_pzv);
            i64 ik = 1;
            if (!up) ik = -1;
            ph_pset_at = line;
            ph_pending_stmt(ph_expr_stmt_of(ph_pset_node(ph_tref(rtp), ppn, nv, ph_pset_kind(ik, fl))));
            ph_pending_stmt(ph_check(line, fl));
            ph_ety = PT_MIXED;
            return ph_tref(ph_temp(ph_c1("php_zv_val", ph_c3("php_zv_pget", ph_tref(rtp), ph_strlit(ppn, cstrlen(ppn)), ph_scope(), ty_pzv), ty_pzv), ty_pzv, "phov_"));
        }
        i64 t = ph_var_type(d);
        i64 lv = ph_var_node(d, 0);         // the read: php_gread for a global
        i64 io = ph_incdec_other(t, !up, lv);
        if (io) {
            ph_pending_stmt(io);
            ph_ety = t;
            return ph_var_node(d, 0);
        }
        i64 val = 0;
        if (t == PT_MIXED) {
            uptr f = "php_zv_inc";
            if (!up) f = "php_zv_dec";
            val = ph_c1(f, lv, ty_pzv);
        }
        if (t != PT_MIXED) {
            i64 one = ph_int(1);
            if (t == PT_FLOAT) one = ph_cast(ty_f64, ph_int(1));
            val = ph_bin(ph_tok("+", 1), lv, one, ph_mcty(t));
            if (!up) set_nd_op(val, ph_tok("-", 1));
        }
        if (ph_is_ref(d)) {
            i64 lvi = node_new(N_IDENT, line, fl);
            set_nd_name(lvi, ph_mangle(d, "v_"));
            set_nd_type(lvi, ty_pzv);
            ph_pending_stmt(ph_expr_stmt_of(ph_c2("php_zv_store", lvi, val, ty_pzv)));
        }
        if (!ph_is_ref(d)) ph_pending_stmt(ph_set(ph_mangle(d, "v_"), val));
        i64 r = node_new(N_IDENT, line, fl);
        set_nd_name(r, ph_mangle(d, "v_"));
        set_nd_type(r, ph_mcty(t));
        ph_ety = t;
        return r;
    }
    // @EXPR: php suppresses the diagnostics the expression raises and keeps
    // its value. The runtime has a suppression depth since T7's diagnostic
    // channel, so this is a pending statement on each side of a temporary --
    // the pendings are a queue, so the expression's own land between them.
    if (ph_at("@", 1)) {
        ph_next();
        ph_pending_stmt(ph_stmt_of(ph_call("php_quiet_on", 0, 0, 0, 0, 0, TY_VOID)));
        i64 av = ph_expr(70);
        i64 at = ph_ety;
        i64 atmp = ph_temp(av, ph_mcty(at), "pha_");
        ph_pending_stmt(ph_stmt_of(ph_call("php_quiet_off", 0, 0, 0, 0, 0, TY_VOID)));
        ph_ety = at;
        return ph_tref(atmp);
    }
    // `throw expr` as an expression (php 8: `$x ?? throw ...`, `fn() =>
    // throw ...`, a match arm). The throw runs, with the unwinding check
    // right behind it, among the statements the enclosing expression puts
    // in front of itself -- inside a short circuit's branch when it is one,
    // so it runs only on that branch. Its value is never reached; it is a
    // null, which a conditional takes as the OTHER branch's type (ph_never).
    if (ph_is("throw")) {
        ph_next();
        i64 tsave = ph_can_throw;
        ph_can_throw = 0;
        i64 te = ph_expr(0);
        i64 tt = ph_ety;
        // as the statement: a scalar operand that throws is that exception
        if (ph_can_throw && tt != PT_OBJ && tt != PT_MIXED) te = ph_checked_now(te, ph_mcty(tt), line, fl);
        i64 ts = node_new(N_EXPRSTMT, line, fl);
        set_nd_a(ts, ph_c1("php_throw", ph_recv(te, tt), ty_pzv));
        ph_pending_stmt(ts);
        ph_pending_stmt(ph_check(line, fl));
        ph_can_throw = 1;
        if (tsave) ph_can_throw = 1;
        ph_never = ph_int(0);
        ph_ety = PT_NULL;
        return ph_never;
    }
    // `print expr` in an expression: the text printed, and 1 (a statement
    // `print` is lvalue.mc's, with echo)
    if (ph_is("print")) {
        uptr pfl = ph_tfile;
        i64 pline = ph_tline;
        ph_next();
        i64 pv = ph_expr(0);
        i64 pt = ph_ety;
        ph_pending_stmt(ph_stmt_of(ph_echo_of(pv, pt, pfl, pline)));
        ph_ety = PT_INT;
        return ph_int(1);
    }
    if (ph_is("new")) {
        ph_next();
        ph_accept("\\", 1);
        if (ph_at("$", 1)) ph_refuse(fl, line, "new with a class name from a variable", "D6");
        // `new class (args) extends B implements I { ... }`: the body is an
        // ordinary class declaration under a generated name, registered with
        // every other class before main runs, and the `new` that follows is
        // the ordinary one. The ARGUMENTS come before `extends`, so they are
        // read here and replayed after the body -- which is why the class is
        // parsed first and the constructor call built from what it left.
        uptr cn = 0;
        i64 anonargs = 0;
        if (ph_is("class")) {
            ph_nonce = ph_nonce + 1;
            cn = p_cat("class@anonymous", php_dec(ph_nonce), 0, cstrlen(php_dec(ph_nonce)));
            ph_anon_name = cn;
            ph_class(fl, line, 0);
            uptr ama = ph_anon_args;
            i64 anc = ph_anon_nargs;
            if (anc) anonargs = 1;
            if (anc < 0) anc = 0;
            i64 aob = ph_c3("php_new_at", ph_strlit(cn, cstrlen(cn)), ph_strlit(ph_disp(ph_absfile(fl)), cstrlen(ph_disp(ph_absfile(fl)))), ph_int(line), TY_UPTR);
            i64 atmp = ph_temp(aob, TY_UPTR, "phw_");
            if (anonargs) {
                u8 aall[88];
                st64(aall, ph_tref(atmp));
                st64(aall + 8, ph_strlit("__construct", 11));
                st64(aall + 16, ph_scope());
                st64(aall + 24, ph_int(anc));
                i64 ai = 0;
                loop { if (ai >= 6) break; st64(aall + 32 + ai * 8, ld64(ama + ai * 8)); ai = ai + 1; }
                ph_pending_stmt(ph_stmt_of(ph_mcalln("php_ctor", aall, 10, ph_anon_tail)));
            }
            if (!anonargs) ph_pending_stmt(ph_stmt_of(ph_c1("php_ctor0", ph_tref(atmp), ty_pzv)));
            ph_ety = PT_OBJ;
            return ph_tref(atmp);
        }
        if (ph_tid != T_IDENT) err_at2(fl, line, "mc-php: a php class name was expected after new", ph_tname);
        cn = ph_ns_class(ph_tname);
        ph_next();
        // `new static()` / `new self()` / `new parent()`: the class ENTRY
        if (str_eq(cn, "static") || str_eq(cn, "self") || str_eq(cn, "parent")) {
            i64 ceo = ph_ce_of(cn, fl, line);
            i64 obs = ph_c3("php_new_ce_at", ceo, ph_strlit(ph_disp(ph_absfile(fl)), cstrlen(ph_disp(ph_absfile(fl)))), ph_int(line), TY_UPTR);
            i64 tmps = ph_temp(obs, TY_UPTR, "phw_");
            i64 hasa = 0;
            if (ph_at("(", 1)) {
                u8 nbs[8];
                uptr mas = ph_margs(nbs, fl, line);
                i64 tls = ph_mtail;
                i64 ncs = ld64(nbs);
                u8 alls[88];
                st64(alls, ph_tref(tmps));
                st64(alls + 8, ph_strlit("__construct", 11));
                st64(alls + 16, ph_scope());
                st64(alls + 24, ph_int(ncs));
                i64 qi = 0;
                loop { if (qi >= 6) break; st64(alls + 32 + qi * 8, ld64(mas + qi * 8)); qi = qi + 1; }
                ph_pending_stmt(ph_stmt_of(ph_mcalln("php_ctor", alls, 10, tls)));
                hasa = 1;
            }
            if (!hasa) ph_pending_stmt(ph_stmt_of(ph_c1("php_ctor0", ph_tref(tmps), ty_pzv)));
            ph_ety = PT_OBJ;
            return ph_tref(tmps);
        }
        i64 ob = ph_c3("php_new_at", ph_strlit(cn, cstrlen(cn)), ph_strlit(ph_disp(ph_absfile(fl)), cstrlen(ph_disp(ph_absfile(fl)))), ph_int(line), TY_UPTR);
        i64 tmp = ph_temp(ob, TY_UPTR, "phw_");
        i64 hasargs = 0;
        if (ph_at("(", 1)) hasargs = 1;
        if (hasargs) {
            u8 nb[8];
            uptr ma = ph_margs(nb, fl, line);
            i64 tln = ph_mtail;
            u8 all[88];
            st64(all, ph_tref(tmp));
            st64(all + 8, ph_strlit("__construct", 11));
            st64(all + 16, ph_scope());
            st64(all + 24, ph_int(ld64(nb)));
            i64 i = 0;
            loop { if (i >= 6) break; st64(all + 32 + i * 8, ld64(ma + i * 8)); i = i + 1; }
            ph_pending_stmt(ph_stmt_of(ph_mcalln("php_ctor", all, 10, tln)));
        }
        if (!hasargs) ph_pending_stmt(ph_stmt_of(ph_c1("php_ctor0", ph_tref(tmp), ty_pzv)));
        ph_ety = PT_OBJ;
        return ph_tref(tmp);
    }
    if (ph_is("fn")) { ph_next(); return ph_closure(fl, line, 1); }
    if (ph_is("function")) { ph_next(); ph_accept("&", 1); return ph_closure(fl, line, 0); }
    if (ph_is("static")) {
        // `static function () {}` / `static fn() =>`: a closure with no
        // $this. `static::` is a CLASS name and goes the ordinary way, so
        // the cursor decides which of the two this is -- ph_builtin wants
        // the name token still current and there is no token lookahead.
        if (!ph_dcolon_next()) {
            ph_next();
            if (ph_is("fn")) { ph_next(); return ph_closure(fl, line, 1); }
            if (ph_is("function")) { ph_next(); ph_accept("&", 1); return ph_closure(fl, line, 0); }
            ph_todo2(fl, line, "the storage keyword", "static");
        }
    }
    if (ph_is("match")) {
        ph_next();
        ph_want("(", 1, "expected ( after match");
        i64 sv = ph_expr(0);
        i64 svt = ph_ety;
        ph_want(")", 1, "expected ) after match");
        ph_want("{", 1, "expected { after match");
        i64 subj = ph_temp(ph_to_mixed(sv, svt), ty_pzv, "phm_");
        i64 res = ph_temp(ph_call("php_znull", 0, 0, 0, 0, 0, ty_pzv), ty_pzv, "phr_");
        // Each arm's conditions are tried in order and its value computed
        // only when it is the arm taken: whatever statements a condition or a
        // value needs ahead of itself (a ?? temporary, a call's check, a
        // throw expression) go inside that test or that arm, never in front of
        // the whole match. `default` runs when nothing matched, wherever it is
        // written.
        i64 oq = ph_take_pend();
        i64 chain = 0;
        i64 last = 0;
        i64 dflt = 0;
        uptr cpre = xalloc(256 * 8);
        uptr ccnd = xalloc(256 * 8);
        loop {
            if (ph_at("}", 1)) break;
            if (ph_tid == T_EOF) err_at(fl, line, "mc-php: unterminated match");
            i64 isdef = 0;
            if (ph_is("default")) { ph_next(); isdef = 1; }
            i64 nc = 0;
            i64 anyp = 0;
            if (!isdef) {
                loop {
                    i64 cv = ph_expr(0);
                    i64 one = ph_cast(TY_U8, ph_c2("php_zv_identical", ph_tref(subj), ph_to_mixed(cv, ph_ety), TY_I64));
                    i64 cp = ph_take_pend();
                    if (nc >= 256) ph_todo(fl, line, "more than 256 conditions in one match arm");
                    st64(cpre + nc * 8, cp);
                    st64(ccnd + nc * 8, one);
                    if (cp) anyp = 1;
                    nc = nc + 1;
                    if (!ph_accept(",", 1)) break;
                    if (ph_at("=>", 2)) break;
                }
            }
            ph_want("=>", 2, "expected => in a match arm");
            i64 rv = ph_expr(0);
            i64 rvt = ph_ety;
            i64 vp = ph_take_pend();
            i64 body = ph_blk(ph_prefix_stmts(vp, ph_set(nd_name(res), ph_to_mixed(rv, rvt))));
            if (isdef) dflt = body;
            if (!isdef) {
                i64 test = 0;
                i64 cond = 0;
                if (!anyp) {
                    i64 k = 0;
                    loop {
                        if (k >= nc) break;
                        i64 one2 = ld64(ccnd + k * 8);
                        if (!cond) cond = one2;
                        if (cond != one2) cond = ph_bin(ph_tok("||", 2), cond, one2, TY_U8);
                        k = k + 1;
                    }
                } else {
                    // a flag: condition k's statements run only when 0..k-1 missed
                    ph_nonce = ph_nonce + 1;
                    uptr fg = p_cat("phmf_", php_dec(ph_nonce), 0, cstrlen(php_dec(ph_nonce)));
                    ph_local(fg, TY_U8);
                    i64 inner = 0;
                    i64 k2 = nc - 1;
                    loop {
                        if (k2 < 0) break;
                        i64 hit = node_new(N_IF, line, fl);
                        set_nd_a(hit, ld64(ccnd + k2 * 8));
                        set_nd_b(hit, ph_set(fg, ph_cast(TY_U8, ph_int(1))));
                        if (inner) set_nd_c(hit, ph_blk(inner));
                        inner = ph_prefix_stmts(ld64(cpre + k2 * 8), hit);
                        k2 = k2 - 1;
                    }
                    test = ph_prefix_stmts(ph_set(fg, ph_cast(TY_U8, ph_int(0))), inner);
                    cond = node_new(N_IDENT, line, fl);
                    set_nd_name(cond, fg);
                    set_nd_type(cond, TY_U8);
                }
                i64 iff = node_new(N_IF, line, fl);
                set_nd_a(iff, cond);
                set_nd_b(iff, body);
                test = ph_prefix_stmts(test, iff);
                if (last) set_nd_c(last, ph_blk(test));
                if (!last) chain = test;
                last = iff;
            }
            if (!ph_accept(",", 1)) break;
        }
        ph_want("}", 1, "expected } after match");
        i64 fin = dflt;
        if (!fin) fin = ph_stmt_of(ph_c1("php_unhandled_match", ph_tref(subj), ty_pzv));
        if (last) set_nd_c(last, fin);
        if (!last) chain = fin;
        ph_put_pend(oq);
        ph_pending_stmt(chain);
        ph_ety = PT_MIXED;
        return ph_tref(res);
    }
    if (ph_is("clone")) {
        ph_next();
        i64 v = ph_expr(70);
        i64 vt2 = ph_ety;
        ph_ety = PT_MIXED;
        return ph_c1("php_clone", ph_recv(v, vt2), ty_pzv);
    }
    if (ph_at("&", 1)) ph_todo(fl, line, "a reference &$x");
    if (ph_at("\\", 1)) { ph_next(); return ph_primary(); }   // a root-namespaced name
    if (ph_tid == T_IDENT) {
        uptr name = ph_tname;
        return ph_builtin(name, line, fl);
    }
    err_at2(fl, line, "mc-php: a php expression was expected", ph_tname);
    return 0;
}

// ---- PHP's precedence, the subset T5 reads ---------------------------------
i64 ph_prec(i64 t) {
    if (t == ph_tok("**", 2)) return 80;
    if (t == ph_tok("*", 1) || t == ph_tok("/", 1) || t == ph_tok("%", 1)) return 60;
    if (t == ph_tok("+", 1) || t == ph_tok("-", 1)) return 55;
    if (t == ph_tok(".", 1)) return 54;
    if (t == ph_tok("<<", 2) || t == ph_tok(">>", 2)) return 52;
    if (t == ph_tok("<", 1) || t == ph_tok(">", 1) || t == ph_tok("<=", 2) || t == ph_tok(">=", 2)) return 45;
    if (t == ph_tok("==", 2) || t == ph_tok("!=", 2) || t == ph_tok("===", 3)
        || t == ph_tok("!==", 3) || t == ph_tok("<>", 2) || t == ph_tok("<=>", 3)) return 40;
    if (t == ph_tok("&", 1)) return 38;
    if (t == ph_tok("^", 1)) return 37;
    if (t == ph_tok("|", 1)) return 36;
    if (t == ph_tok("&&", 2)) return 30;
    if (t == ph_tok("||", 2)) return 28;
    return -1;
}

// the zval road: php's own numeric-string, overflow-to-float and array-union
// rules all live in the runtime, so anything the static types cannot answer
// exactly is lowered to one call instead of guessed at here.
i64 ph_arith_zv(i64 op, i64 lhs, i64 lt, i64 rhs, i64 rt) {
    uptr f = 0;
    if (op == ph_tok("+", 1))  f = "php_zv_add";
    if (op == ph_tok("-", 1))  f = "php_zv_sub";
    if (op == ph_tok("*", 1))  f = "php_zv_mul";
    if (op == ph_tok("/", 1))  f = "php_zv_div";
    if (op == ph_tok("%", 1))  f = "php_zv_mod";
    if (op == ph_tok("**", 2)) f = "php_zv_pow";
    if (op == ph_tok("&", 1))  f = "php_zv_band";
    if (op == ph_tok("|", 1))  f = "php_zv_bor";
    if (op == ph_tok("^", 1))  f = "php_zv_bxor";
    if (op == ph_tok("<<", 2)) f = "php_zv_shl";
    if (op == ph_tok(">>", 2)) f = "php_zv_shr";
    if (!f) err_at(ph_tfile, ph_tline, "mc-php: this operator has no zval form");
    ph_ety = PT_MIXED;
    // one side a NATIVE int: no box for it, and the int-and-int case in
    // place (php_zv_add_zi and its siblings fall back to the zval operator)
    uptr fi = 0;
    if (lt == PT_MIXED && rt == PT_INT) {
        if (op == ph_tok("+", 1)) fi = "php_zv_add_zi";
        if (op == ph_tok("-", 1)) fi = "php_zv_sub_zi";
        if (op == ph_tok("*", 1)) fi = "php_zv_mul_zi";
        if (op == ph_tok("%", 1)) fi = "php_zv_mod_zi";
        if (fi) return ph_c2(fi, lhs, rhs, ty_pzv);
    }
    if (lt == PT_INT && rt == PT_MIXED) {
        if (op == ph_tok("+", 1)) fi = "php_zv_add_iz";
        if (op == ph_tok("-", 1)) fi = "php_zv_sub_iz";
        if (op == ph_tok("*", 1)) fi = "php_zv_mul_iz";
        if (fi) return ph_c2(fi, lhs, rhs, ty_pzv);
    }
    return ph_c2(f, ph_to_mixed(lhs, lt), ph_to_mixed(rhs, rt), ty_pzv);
}

i64 ph_numeric(i64 t) {
    if (t == PT_INT || t == PT_IFALSE || t == PT_BOOL || t == PT_FLOAT) return 1;
    return 0;
}

i64 ph_arith(i64 op, i64 lhs, i64 lt, i64 rhs, i64 rt, uptr fl, i64 line) {
    // anything a static type cannot answer exactly goes to the zval
    if (!ph_numeric(lt) || !ph_numeric(rt)) return ph_arith_zv(op, lhs, lt, rhs, rt);
    if (lt == PT_BOOL) { lhs = ph_to_int(lhs, lt); lt = PT_INT; }
    if (rt == PT_BOOL) { rhs = ph_to_int(rhs, rt); rt = PT_INT; }
    if (lt == PT_IFALSE) lt = PT_INT;
    if (rt == PT_IFALSE) rt = PT_INT;
    i64 flt = 0;
    if (lt == PT_FLOAT || rt == PT_FLOAT) flt = 1;
    if (op == ph_tok("/", 1)) {
        // int / int is int|float in php -- a union, so a zval (D4 (c))
        if (!flt) return ph_arith_zv(op, lhs, lt, rhs, rt);
        ph_ety = PT_FLOAT;
        return ph_c2("php_div_f", ph_to_float(lhs, lt), ph_to_float(rhs, rt), ty_f64);
    }
    if (op == ph_tok("%", 1)) {
        ph_ety = PT_INT;
        // `%` throws DivisionByZeroError, and that is the ONLY thing it can
        // do besides the remainder -- so a divisor the compiler can see is a
        // positive literal takes mc's own `%`, which is one instruction and
        // cannot raise. The statement around it then needs neither php_pos
        // nor php_thrown, which is what `$s + $i % 7` in a loop was paying.
        // The same shape as the literal exponent below, and positive rather
        // than non-zero for the same reason C has: php answers 0 for
        // `PHP_INT_MIN % -1` and a native sdiv is where that is not free.
        if (nd_kind(rhs) == N_INT && nd_val(rhs) > 0)
            return ph_bin(op, ph_to_int(lhs, lt), ph_to_int(rhs, rt), TY_I64);
        return ph_c2("php_mod", ph_to_int(lhs, lt), ph_to_int(rhs, rt), TY_I64);
    }
    if (op == ph_tok("**", 2)) {
        if (flt) { ph_ety = PT_FLOAT; return ph_c2("php_pow_f", ph_to_float(lhs, lt), ph_to_int(rhs, rt), ty_f64); }
        // `2 ** -1` is float(0.5), so `int ** int` is int|float and D4 (c)
        // sends that to a zval -- unless the exponent is a literal the
        // compiler can see is not negative, which keeps the cheap int path
        // for every `$x ** 2` in the corpus
        // (docs/review-backlog.md section 2).
        i64 lit = 0;
        if (nd_kind(rhs) == N_INT && nd_val(rhs) >= 0) lit = 1;
        if (!lit) {
            ph_ety = PT_MIXED;
            return ph_c2("php_zv_pow", ph_to_mixed(lhs, lt), ph_to_mixed(rhs, rt), ty_pzv);
        }
        ph_ety = PT_INT;
        return ph_c2("php_pow_i", ph_to_int(lhs, lt), ph_to_int(rhs, rt), TY_I64);
    }
    if (op == ph_tok("<<", 2) || op == ph_tok(">>", 2)) {
        ph_ety = PT_INT;
        uptr sf = "php_shl_i";
        if (op == ph_tok(">>", 2)) sf = "php_shr_i";
        // a count the source spells as a literal 0..63 is neither negative
        // (php's ArithmeticError) nor 64 or more (php's 0 or -1): mc's own
        // shift, arithmetic for >> on an int, is exactly php's
        if (nd_kind(rhs) == N_INT && nd_val(rhs) >= 0 && nd_val(rhs) < 64)
            return ph_bin(op, ph_to_int(lhs, lt), rhs, TY_I64);
        ph_can_throw = 1;
        return ph_c2(sf, ph_to_int(lhs, lt), ph_to_int(rhs, rt), TY_I64);
    }
    if (op == ph_tok("&", 1) || op == ph_tok("|", 1) || op == ph_tok("^", 1)) {
        ph_ety = PT_INT;
        return ph_bin(op, ph_to_int(lhs, lt), ph_to_int(rhs, rt), TY_I64);
    }
    if (flt) {
        ph_ety = PT_FLOAT;
        return ph_bin(op, ph_to_float(lhs, lt), ph_to_float(rhs, rt), ty_f64);
    }
    ph_ety = PT_INT;
    // + - * wrap as C's do, on any int (docs/semantics.md). A literal on the
    // left of + or * goes to the right, where src/mach.mc's P1 makes it the
    // instruction's immediate: `chr(48 + $d % 10)` was a movz and an add. The
    // literal evaluates nothing, so the order of evaluation is unchanged.
    if ((op == ph_tok("+", 1) || op == ph_tok("*", 1)) && nd_kind(lhs) == N_INT && nd_kind(rhs) != N_INT)
        return ph_bin(op, rhs, lhs, TY_I64);
    return ph_bin(op, lhs, rhs, TY_I64);
}

i64 ph_cmp_zv(i64 t, i64 lhs, i64 lt, i64 rhs, i64 rt) {
    i64 a = ph_to_mixed(lhs, lt);
    i64 b = ph_to_mixed(rhs, rt);
    i64 neg = 0;
    if (t == ph_tok("!=", 2) || t == ph_tok("<>", 2) || t == ph_tok("!==", 3)) neg = 1;
    if (t == ph_tok("===", 3) || t == ph_tok("!==", 3)) {
        ph_ety = PT_BOOL;
        i64 id = ph_c2("php_zv_identical", a, b, TY_I64);
        i64 op = ph_tok("!=", 2);
        if (neg) op = ph_tok("==", 2);
        return ph_cast(TY_U8, ph_bin(op, id, ph_int(0), TY_U8));
    }
    i64 c = ph_c2("php_zv_cmp", a, b, TY_I64);
    if (t == ph_tok("<=>", 3)) { ph_ety = PT_INT; return c; }
    i64 op2 = t;
    if (op2 == ph_tok("<>", 2)) op2 = ph_tok("!=", 2);
    ph_ety = PT_BOOL;
    return ph_cast(TY_U8, ph_bin(op2, c, ph_int(0), TY_U8));
}

// n can be dropped unevaluated: it runs no code and raises nothing -- a
// variable, a literal, a cast of one. A strict comparison whose answer the
// static types already know is folded to a constant only over such operands;
// anything else (a call, an arithmetic that can throw) is still EVALUATED,
// for its side effects and its exception (`side() === null` must call side()).
i64 ph_pure(i64 n) {
    if (!n) return 1;
    i64 k = nd_kind(n);
    if (k == N_IDENT || k == N_INT || k == N_STR) return 1;
    if (k == N_CAST) return ph_pure(nd_a(n));
    if (k == N_CALL && str_eq(nd_name(n), "php_str_lit")) return 1;
    // a float literal: php_stof(ld64(<its cached string>))
    if (k == N_CALL && (str_eq(nd_name(n), "php_stof") || str_eq(nd_name(n), "ld64"))
        && nd_a(n) && !nd_next(nd_a(n))) return ph_pure(nd_a(n));
    return 0;
}

i64 ph_compare(i64 t, i64 lhs, i64 lt, i64 rhs, i64 rt, uptr fl, i64 line) {
    i64 strict = 0;
    if (t == ph_tok("===", 3) || t == ph_tok("!==", 3)) strict = 1;
    i64 neg = 0;
    if (t == ph_tok("!=", 2) || t == ph_tok("<>", 2) || t == ph_tok("!==", 3)) neg = 1;
    i64 eq = 0;
    if (t == ph_tok("==", 2) || t == ph_tok("!=", 2) || t == ph_tok("<>", 2) || strict) eq = 1;

    // `=== null` / `!== null`: no znull allocation and no php_zv_identical
    // call. The null literal is PT_NULL; the other side decides. A statically
    // non-null type is a compile-time answer (an int is never null); only a
    // zval can be null at runtime, and then it is the type byte against IS_NULL
    // (ld8(z + 8), what php_zv_identical against a null zval tests) in place.
    if (strict && (lt == PT_NULL || rt == PT_NULL)) {
        i64 nt = lt; i64 nn = lhs;                     // rt is the null literal: lhs decides
        if (lt == PT_NULL && rt == PT_NULL) { nt = PT_NULL; }
        if (lt == PT_NULL && rt != PT_NULL) { nt = rt; nn = rhs; }   // lhs is null: rhs decides
        ph_ety = PT_BOOL;
        i64 pure = ph_pure(lhs) && ph_pure(rhs);
        if (nt == PT_NULL && pure) { i64 r0 = 1; if (neg) r0 = 0; return ph_bool(r0); }  // null === null
        // a native nullable scalar (src/decl.mc): its null-ness is its u8 flag,
        // not its value's tag -- the value is a native scalar with no tag
        if (nn && nd_kind(nn) == N_IDENT) {
            uptr ofl = ph_opt_flag_of(nd_name(nn));
            if (ofl) {
                i64 fr = node_new(N_IDENT, line, fl);
                set_nd_name(fr, ofl);
                set_nd_type(fr, TY_U8);
                if (neg) return ph_cast(TY_U8, ph_bin(ph_tok("==", 2), fr, ph_int(0), TY_U8));
                return fr;                             // the flag is 1 iff null
            }
        }
        if (nt != PT_MIXED && nt != PT_NULL && pure) { i64 r1 = 0; if (neg) r1 = 1; return ph_bool(r1); } // a static non-null type
        i64 a = ph_to_mixed(nn, nt);
        i64 tag = ph_quiet("ld8", 1, ph_bin(ph_tok("+", 1), a, ph_int(8), TY_UPTR), 0, 0, 0, TY_I64);
        i64 op = ph_tok("==", 2);
        if (neg) op = ph_tok("!=", 2);
        return ph_cast(TY_U8, ph_bin(op, tag, ph_int(1), TY_U8));   // IS_NULL
    }

    // the one union T5 has: `strpos(...) === false`
    if (lt == PT_IFALSE && rt == PT_BOOL && eq) {
        ph_ety = PT_BOOL;
        i64 op = ph_tok("==", 2);
        if (neg) op = ph_tok("!=", 2);
        return ph_cast(TY_U8, ph_bin(op, lhs, ph_int(-1), TY_U8));
    }
    if (lt == PT_MIXED || rt == PT_MIXED || lt == PT_NULL || rt == PT_NULL
        || ph_is_arr(lt) || ph_is_arr(rt))
        return ph_cmp_zv(t, lhs, lt, rhs, rt);
    // an object compared loosely is php's property-by-property comparison
    // (php_zv_cmp), not its handle's; `===` of two is the same object
    if ((lt == PT_OBJ || rt == PT_OBJ) && (!strict || lt != rt)) return ph_cmp_zv(t, lhs, lt, rhs, rt);
    if (lt == PT_STRING && rt != PT_STRING) return ph_cmp_zv(t, lhs, lt, rhs, rt);
    if (rt == PT_STRING && lt != PT_STRING) return ph_cmp_zv(t, lhs, lt, rhs, rt);
    if (strict && lt != rt) {
        if (lt == PT_IFALSE && rt == PT_INT) { lt = PT_INT; }
        else if (!ph_pure(lhs) || !ph_pure(rhs)) return ph_cmp_zv(t, lhs, lt, rhs, rt);   // evaluated
        else {
            ph_ety = PT_BOOL;
            if (neg) return ph_bool(1);
            return ph_bool(0);
        }
    }
    if (lt == PT_IFALSE) lt = PT_INT;
    if (rt == PT_IFALSE) rt = PT_INT;
    if (lt == PT_STRING && rt == PT_STRING) {
        // $s[$i] === 'c' (either side): the byte compared in place. A string
        // offset is a one-byte string or "", so only === and !== against a
        // one-byte LITERAL are this -- `==` would compare numeric strings.
        // $r[$m] === $b[$m]: C's reads (php_str_off_c) and the trapping ones
        // (php_str_off_d) are always ONE byte each (src/lvalue.mc says why),
        // so two of them are equal exactly when the bytes are
        if (strict && nd_kind(lhs) == N_CALL && nd_kind(rhs) == N_CALL
            && (str_eq(nd_name(lhs), "php_str_off_c") || str_eq(nd_name(lhs), "php_str_off_d"))
            && (str_eq(nd_name(rhs), "php_str_off_c") || str_eq(nd_name(rhs), "php_str_off_d"))) {
            if (str_eq(nd_name(lhs), "php_str_off_c")) set_nd_name(lhs, "php_str_byte_c");
            else set_nd_name(lhs, "php_str_byte_d");
            if (str_eq(nd_name(rhs), "php_str_off_c")) set_nd_name(rhs, "php_str_byte_c");
            else set_nd_name(rhs, "php_str_byte_d");
            set_nd_type(lhs, TY_I64);
            set_nd_type(rhs, TY_I64);
            ph_ety = PT_BOOL;
            i64 bop = ph_tok("==", 2);
            if (neg) bop = ph_tok("!=", 2);
            return ph_bin(bop, lhs, rhs, TY_U8);
        }
        if (strict) {
            i64 off = 0;
            i64 lit = 0;
            if (nd_kind(lhs) == N_CALL && ph_is_stroff(nd_name(lhs)) && ph_is_strlit(rhs)) { off = lhs; lit = rhs; }
            if (nd_kind(rhs) == N_CALL && ph_is_stroff(nd_name(rhs)) && ph_is_strlit(lhs)) { off = rhs; lit = lhs; }
            if (off && nd_val(nd_next(nd_next(nd_a(lit)))) == 1) {
                i64 by = ld8(nd_name(nd_next(nd_a(lit))));
                uptr onm = nd_name(off);
                i64 sb = nd_a(off);
                i64 ix = nd_next(sb);
                set_nd_next(sb, 0);
                i64 at = 0;
                // C semantics: the byte, read (and checked by the debug trap)
                if (str_eq(onm, "php_str_off_c"))
                    at = ph_bin(ph_tok("==", 2), ph_quiet("php_str_byte_c", 2, sb, ix, 0, 0, TY_I64), ph_int(by), TY_U8);
                if (str_eq(onm, "php_str_off_d"))
                    at = ph_bin(ph_tok("==", 2), ph_c2("php_str_byte_d", sb, ix, TY_I64), ph_int(by), TY_U8);
                // a variable and a variable or literal index: the in-range
                // byte compared right here, and the call only outside the
                // string, where php_str_at_is warns (both operands are read
                // twice, so only names and literals qualify)
                if (!at && (nd_kind(sb) == N_IDENT) && (nd_kind(ix) == N_IDENT || nd_kind(ix) == N_INT)) {
                    i64 len = ph_strlen_of(ph_tref(sb));
                    i64 ix1 = ph_tref(ix);
                    if (nd_kind(ix) == N_INT) ix1 = ph_int(nd_val(ix));
                    i64 ix2 = ph_tref(ix);
                    if (nd_kind(ix) == N_INT) ix2 = ph_int(nd_val(ix));
                    i64 ix3 = ph_tref(ix);
                    if (nd_kind(ix) == N_INT) ix3 = ph_int(nd_val(ix));
                    // a literal index at or above 0 needs only the upper bound
                    // (mc folds no comparison of two constants)
                    i64 lit0 = nd_kind(ix) == N_INT && nd_val(ix) >= 0;
                    i64 inr = ph_bin(ph_tok("<", 1), ix2, len, TY_U8);
                    if (!lit0) inr = ph_bin(ph_tok("&&", 2), ph_bin(ph_tok(">=", 2), ix1, ph_int(0), TY_U8), inr, TY_U8);
                    i64 bp = ph_bin(ph_tok("+", 1), ph_bin(ph_tok("+", 1), ph_tref(sb), ph_int(24), TY_UPTR), ix3, TY_UPTR);
                    i64 hit = ph_bin(ph_tok("&&", 2), inr,
                                     ph_bin(ph_tok("==", 2), ph_quiet("ld8", 1, bp, 0, 0, 0, TY_I64), ph_int(by), TY_U8), TY_U8);
                    i64 len2 = ph_strlen_of(ph_tref(sb));
                    i64 iy1 = ph_tref(ix);
                    if (nd_kind(ix) == N_INT) iy1 = ph_int(nd_val(ix));
                    i64 iy2 = ph_tref(ix);
                    if (nd_kind(ix) == N_INT) iy2 = ph_int(nd_val(ix));
                    i64 outr = ph_bin(ph_tok(">=", 2), iy2, len2, TY_U8);
                    if (!lit0) outr = ph_bin(ph_tok("||", 2), ph_bin(ph_tok("<", 1), iy1, ph_int(0), TY_U8), outr, TY_U8);
                    i64 miss = ph_bin(ph_tok("&&", 2), outr,
                                      ph_bin(ph_tok("!=", 2), ph_c3("php_str_at_is", sb, ix, ph_int(by), TY_I64), ph_int(0), TY_U8), TY_U8);
                    at = ph_bin(ph_tok("||", 2), hit, miss, TY_U8);
                }
                if (!at) at = ph_c3("php_str_at_is", sb, ix, ph_int(by), TY_I64);
                ph_ety = PT_BOOL;
                i64 eop = ph_tok("!=", 2);
                if (neg) eop = ph_tok("==", 2);
                return ph_cast(TY_U8, ph_bin(eop, at, ph_int(0), TY_U8));
            }
        }
        // === and !== ask only whether the bytes are the same: the lengths
        // first, and no ordering (php_str_eq)
        if (strict) {
            ph_ety = PT_BOOL;
            i64 eop2 = ph_tok("!=", 2);
            if (neg) eop2 = ph_tok("==", 2);
            return ph_cast(TY_U8, ph_bin(eop2, ph_quiet("php_str_eq", 2, lhs, rhs, 0, 0, TY_I64), ph_int(0), TY_U8));
        }
        i64 c = ph_c2("php_str_cmp", lhs, rhs, TY_I64);
        if (t == ph_tok("<=>", 3)) { ph_ety = PT_INT; return c; }
        i64 op = t;
        if (strict) { op = ph_tok("==", 2); if (neg) op = ph_tok("!=", 2); }
        if (op == ph_tok("<>", 2)) op = ph_tok("!=", 2);
        ph_ety = PT_BOOL;
        return ph_cast(TY_U8, ph_bin(op, c, ph_int(0), TY_U8));
    }
    if (lt == PT_STRING || rt == PT_STRING) {
        if (lt == PT_BOOL || rt == PT_BOOL) {
            lhs = ph_to_bool(lhs, lt); rhs = ph_to_bool(rhs, rt); lt = PT_BOOL; rt = PT_BOOL;
        } else {
            // php 8 compares a non-numeric string with a number AS STRINGS
            ph_refuse2(fl, line, "comparing a string with a number", ph_tyname(lt), "D4");
        }
    }
    if (ph_is_arr(lt) || ph_is_arr(rt)) ph_todo(fl, line, "comparing arrays");
    i64 flt = 0;
    if (lt == PT_FLOAT || rt == PT_FLOAT) flt = 1;
    i64 a = lhs;
    i64 b = rhs;
    if (flt) { a = ph_to_float(lhs, lt); b = ph_to_float(rhs, rt); }
    if (!flt) { a = ph_to_int(lhs, lt); b = ph_to_int(rhs, rt); }
    if (t == ph_tok("<=>", 3)) {
        ph_ety = PT_INT;
        if (flt) return ph_c2("php_cmp_f", a, b, TY_I64);
        return ph_c2("php_cmp_i", a, b, TY_I64);
    }
    i64 op2 = t;
    if (strict) { op2 = ph_tok("==", 2); if (neg) op2 = ph_tok("!=", 2); }
    if (op2 == ph_tok("<>", 2)) op2 = ph_tok("!=", 2);
    ph_ety = PT_BOOL;
    return ph_cast(TY_U8, ph_bin(op2, a, b, TY_U8));
}

i64 ph_expr(i64 minp) {
    ph_efresh = 0;
    i64 lhs0 = ph_postfix(ph_primary(), ph_ety);
    return ph_expr_tail(lhs0, ph_ety, minp);
}

// the operators php's null takes as 0: + - * / % ** & | ^ << >>
i64 ph_arith_op(i64 t) {
    return t == ph_tok("+", 1) || t == ph_tok("-", 1) || t == ph_tok("*", 1) || t == ph_tok("/", 1)
        || t == ph_tok("%", 1) || t == ph_tok("**", 2) || t == ph_tok("&", 1) || t == ph_tok("|", 1)
        || t == ph_tok("^", 1) || t == ph_tok("<<", 2) || t == ph_tok(">>", 2);
}

// php evaluates a binary operator's operands left to right. A right operand
// that needs statements ahead of the expression (a checked call's temporary,
// an array literal) puts them in the pending queue, which runs BEFORE the
// expression -- before a left operand still inside it: `f(5) . intdiv(9,
// f(3))` printed f3 before f5. So when the right side added any, a left side
// that calls something is computed first, in a temporary placed ahead of them
// (after `mark`, the queue's tail before the right side), with the check a
// call needs behind it.
i64 ph_spill_left(i64 lhs, i64 mark) {
    if (ph_pend_tail == mark || !phi_calls_any(lhs)) return lhs;
    ph_nonce = ph_nonce + 1;
    uptr tn = p_cat("phsp_", php_dec(ph_nonce), 0, cstrlen(php_dec(ph_nonce)));
    ph_local(tn, nd_type(lhs));
    i64 as = ph_set(tn, lhs);
    i64 ck = ph_check(nd_line(lhs), nd_file(lhs));
    set_nd_next(as, ck);
    if (mark) { set_nd_next(ck, nd_next(mark)); set_nd_next(mark, as); }
    if (!mark) { set_nd_next(ck, ph_pend_head); ph_pend_head = as; }
    i64 r = node_new(N_IDENT, nd_line(lhs), nd_file(lhs));
    set_nd_name(r, tn);
    set_nd_type(r, nd_type(lhs));
    return r;
}

// the operator half of ph_expr, on a left-hand side somebody else already
// has: what a STATEMENT starting with a $variable needs once it turns out
// not to be an assignment (`$f();`, `$x or die();`).
i64 ph_expr_tail(i64 lhs, i64 lt, i64 minp) {
    loop {
        if (ph_is("instanceof")) {
            if (minp > 65) break;
            ph_next();
            uptr cn = ph_ns_class(ph_tname);
            if (ph_at("$", 1)) ph_refuse(ph_tfile, ph_tline, "instanceof with a class name from a variable", "D6");
            ph_next();
            lhs = ph_cast(TY_U8, ph_c2("php_instanceof", ph_recv(lhs, lt), ph_strlit(cn, cstrlen(cn)), TY_I64));
            lt = PT_BOOL;
            continue;
        }
        i64 t = ph_tid;
        i64 pr = ph_prec(t);
        if (pr < 0) break;
        if (pr < minp) break;
        i64 line = ph_tline;
        uptr fl = ph_tfile;
        ph_next();
        // php SHORT-CIRCUITS && and ||: the right operand is not evaluated at
        // all when the left already decides the answer. An mc expression has
        // no branch, so the value is a u8 temporary and the right side is an
        // `if` -- and the right side's OWN pending statements (an array
        // literal, a call's temporary, a nested short circuit) have to go
        // INSIDE that if, which is what ph_take_pend is for. It is done here,
        // BEFORE the right side is parsed, which is the whole point: the code
        // this replaces parsed it first and then built one mc `&&` over both
        // operands, so the right side ran every time
        // (docs/review-backlog.md section 2, first finding).
        if (t == ph_tok("&&", 2) || t == ph_tok("||", 2)) {
            i64 sct = ph_temp(ph_to_bool(lhs, lt), TY_U8, "phs_");
            i64 outer = ph_take_pend();
            i64 rv = ph_expr(pr + 1);
            i64 rvt = ph_ety;
            i64 inner = ph_take_pend();
            i64 body = ph_blk(ph_prefix_stmts(inner,
                ph_set(nd_name(sct), ph_to_bool(rv, rvt))));
            i64 cnd = ph_tref(sct);
            if (t == ph_tok("||", 2)) {
                i64 nsc = node_new(N_UNARY, line, fl);
                set_nd_op(nsc, ph_tok("!", 1));
                set_nd_a(nsc, cnd);
                set_nd_type(nsc, TY_U8);
                cnd = nsc;
            }
            i64 sif = node_new(N_IF, line, fl);
            set_nd_a(sif, cnd);
            set_nd_b(sif, body);
            ph_put_pend(outer);
            ph_pending_stmt(sif);
            lhs = ph_tref(sct);
            lt = PT_BOOL;
            continue;
        }
        // `**` is php's one right-associative binary operator: `2 ** 3 ** 2`
        // is 2 ** 9, not (2 ** 3) ** 2 (found while fixing `2 ** -1`).
        i64 rp = pr + 1;
        if (t == ph_tok("**", 2)) rp = pr;
        i64 mark = ph_pend_tail;
        i64 rhs = ph_expr(rp);
        i64 rt = ph_ety;
        lhs = ph_spill_left(lhs, mark);
        if (t == ph_tok(".", 1)) {
            i64 rs = ph_to_str(rhs, rt);
            // `a . b . c` is ONE string: the chain php_str_concat just built
            // takes the next part instead of being copied into a new string
            // (php_str_cat3, then php_str_cat4) -- php's own rope, in short
            if (lt == PT_STRING && nd_kind(lhs) == N_CALL && str_eq(nd_name(lhs), "php_str_concat")) {
                i64 p0 = nd_a(lhs);
                set_nd_next(nd_next(p0), rs);
                set_nd_name(lhs, "php_str_cat3");
                continue;
            }
            if (lt == PT_STRING && nd_kind(lhs) == N_CALL && str_eq(nd_name(lhs), "php_str_cat3")) {
                i64 q0 = nd_a(lhs);
                set_nd_next(nd_next(nd_next(q0)), rs);
                set_nd_name(lhs, "php_str_cat4");
                continue;
            }
            lhs = ph_c2("php_str_concat", ph_to_str(lhs, lt), rs, ty_pstr);
            lt = PT_STRING;
            continue;
        }
        if (ph_prec(t) == 45 || ph_prec(t) == 40) {
            lhs = ph_compare(t, lhs, lt, rhs, rt, fl, line);
            lt = ph_ety;
            continue;
        }
        lhs = ph_arith(t, lhs, lt, rhs, rt, fl, line);
        lt = ph_ety;
    }
    ph_ety = lt;
    // ?? and the conditional, both right-associative and both short-circuiting.
    // A short circuit needs a branch, and an mc expression has none: the value
    // is a temporary assigned by statements ph_pending_stmt emits in front of
    // the statement that contains the expression.
    if (minp <= 26 && ph_at("??", 2)) {
        i64 line2 = ph_tline;
        uptr fl2 = ph_tfile;
        i64 tmp = ph_temp(ph_to_mixed(lhs, lt), ty_pzv, "phn_");
        ph_next();
        i64 oq = ph_take_pend();
        i64 r = ph_expr(26);
        i64 rt = ph_ety;
        i64 iq = ph_take_pend();
        ph_put_pend(oq);
        i64 nn = node_new(N_UNARY, line2, fl2);
        set_nd_op(nn, ph_tok("!", 1));
        set_nd_a(nn, ph_cast(TY_U8, ph_c1("php_zv_isset", ph_tref(tmp), TY_I64)));
        set_nd_type(nn, TY_U8);
        i64 iff = node_new(N_IF, line2, fl2);
        set_nd_a(iff, nn);
        set_nd_b(iff, ph_blk(ph_prefix_stmts(iq,
            ph_set(nd_name(tmp), ph_to_mixed(r, rt)))));
        ph_pending_stmt(iff);
        ph_ety = PT_MIXED;
        return ph_tref(tmp);
    }
    if (minp <= 20 && ph_at("?", 1)) {
        i64 line3 = ph_tline;
        uptr fl3 = ph_tfile;
        ph_next();
        if (!ph_at(":", 1)) {
            // The full a ? b : c. Its value is only ever one branch, so when
            // both branches have one native type the temporary has it too and
            // no zval is made: a zval per evaluation is an ALLOCATION, and a
            // recursive `return $n < 2 ? $n : f($n-1) + f($n-2);` made one
            // per call until the arena ran out (docs/plan.md § 7). Two
            // different types keep the zval: php's value keeps its own type.
            i64 cnd3 = ph_to_bool(lhs, lt);
            i64 oc3 = ph_take_pend();
            i64 b3 = ph_expr(0);
            i64 bt3 = ph_ety;
            i64 ib3 = ph_take_pend();
            ph_want(":", 1, "expected : in a php conditional");
            i64 c3 = ph_expr(20);
            i64 ct3 = ph_ety;
            i64 ic3 = ph_take_pend();
            ph_put_pend(oc3);
            // a branch that is a throw expression has no value: the
            // conditional's type is the other branch's
            if (ph_never && b3 == ph_never && ct3 != PT_NULL) { bt3 = ct3; b3 = ph_cast(ph_mcty(ct3), ph_int(0)); }
            if (ph_never && c3 == ph_never && bt3 != PT_NULL) { ct3 = bt3; c3 = ph_cast(ph_mcty(bt3), ph_int(0)); }
            i64 rt3 = PT_MIXED;
            if (bt3 == ct3 && (bt3 == PT_INT || bt3 == PT_FLOAT || bt3 == PT_BOOL || bt3 == PT_STRING))
                rt3 = bt3;
            if (rt3 == PT_MIXED) { b3 = ph_to_mixed(b3, bt3); c3 = ph_to_mixed(c3, ct3); }
            // two int literals: `c ? B : C` is C + c * (B - C), no branch
            // (`$d >= 10 ? 1 : 0` is a carry, and a branch on it is taken
            // at random)
            if (rt3 == PT_INT && !ib3 && !ic3 && nd_kind(b3) == N_INT && nd_kind(c3) == N_INT
                && nd_val(b3) > -2147483648 && nd_val(b3) < 2147483648
                && nd_val(c3) > -2147483648 && nd_val(c3) < 2147483648) {
                i64 kb = nd_val(b3);
                i64 kc = nd_val(c3);
                i64 cv = ph_cast(TY_I64, cnd3);
                ph_ety = PT_INT;
                if (kb == 1 && kc == 0) return cv;
                return ph_bin(ph_tok("+", 1), ph_int(kc), ph_bin(ph_tok("*", 1), cv, ph_int(kb - kc), TY_I64), TY_I64);
            }
            ph_nonce = ph_nonce + 1;
            uptr nn3 = php_dec(ph_nonce);
            uptr tn3 = p_cat("phq_", nn3, 0, cstrlen(nn3));
            ph_local(tn3, ph_mcty(rt3));
            i64 iff3 = node_new(N_IF, line3, fl3);
            set_nd_a(iff3, cnd3);
            set_nd_b(iff3, ph_blk(ph_prefix_stmts(ib3, ph_set(tn3, b3))));
            set_nd_c(iff3, ph_blk(ph_prefix_stmts(ic3, ph_set(tn3, c3))));
            ph_pending_stmt(iff3);
            ph_ety = rt3;
            i64 r3 = node_new(N_IDENT, line3, fl3);
            set_nd_name(r3, tn3);
            set_nd_type(r3, ph_mcty(rt3));
            return r3;
        }
        // a ?: c -- the condition IS the value, so it stays a zval
        i64 tmp2 = ph_temp(ph_to_mixed(lhs, lt), ty_pzv, "phq_");
        i64 cnd = ph_cast(TY_U8, ph_c1("php_zv_bool", ph_tref(tmp2), TY_I64));
        i64 oc = ph_take_pend();
        ph_want(":", 1, "expected : in a php conditional");
        i64 c = ph_expr(20);
        i64 ic2 = ph_take_pend();
        i64 elsev = ph_blk(ph_prefix_stmts(ic2,
            ph_set(nd_name(tmp2), ph_to_mixed(c, ph_ety))));
        ph_put_pend(oc);
        i64 iff2 = node_new(N_IF, line3, fl3);
        i64 nn2 = node_new(N_UNARY, line3, fl3);
        set_nd_op(nn2, ph_tok("!", 1));
        set_nd_a(nn2, cnd);
        set_nd_type(nn2, TY_U8);
        set_nd_a(iff2, nn2);
        set_nd_b(iff2, elsev);
        ph_pending_stmt(iff2);
        ph_ety = PT_MIXED;
        return ph_tref(tmp2);
    }
    return lhs;
}


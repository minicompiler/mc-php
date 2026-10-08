// decl.mc -- the top-level declarations.
// 
// function, and the statement forms that may only appear at the top of a
// file. A global function is HOISTED, so the declaration is collected before
// the statement stream that may call it.

// ---- declarations ----------------------------------------------------------
// A function is registered BEFORE its body is parsed, so it may call itself.
i64 ph_main_head;
i64 ph_main_tail;

// the boundary's record of what slot k of row fi declared (tables.mc)
void ph_bnd_set(i64 fi, i64 k, i64 pt) {
    i64 i = fi * (PH_MAXP + 1) + k;
    i64 bk = ph_lt_k;
    i64 nul = ph_lt_null;
    if (pt < 0) nul = 1;                                  // untyped: anything
    if (pt == PT_MIXED && bk >= 10) { pt = bk - 10; bk = BK_ANY; }   // ?int, ?array
    st64(ph_fdpt + i * 8, pt);
    st64(ph_fbk + i * 8, bk);
    st64(ph_fbn + i * 8, ph_lt_n);
    st64(ph_fbnul + i * 8, nul);
}

// Does this statement guarantee control leaves the function (so the fall-off
// guard the caller is about to append is unreachable)? Conservative: only an
// unconditional return, or a block whose last statement is one. Anything else
// -- an if without a guaranteed-returning else, a loop, a switch -- answers 0,
// so the guard is still emitted. A wrong 0 only keeps dead code; a wrong 1
// would drop a real TypeError, so the default errs toward keeping it.
i64 ph_always_returns(i64 s) {
    if (!s) return 0;
    if (nd_kind(s) == N_RETURN) return 1;
    if (nd_kind(s) == N_BLOCK) {
        i64 t = nd_a(s);
        if (!t) return 0;
        loop { if (!nd_next(t)) break; t = nd_next(t); }
        return ph_always_returns(t);
    }
    return 0;
}

// ---- which `?int $x` parameter may be carried natively ---------------------
// A native nullable int is two locals, the value v_x and the null flag vn_x
// (src/vars.mc). Only a few lowerings read the flag -- `=== null`/`!== null`,
// `??`, isset/is_null, and passing the pair on to another `?int` (or boxing it
// into a zval parameter). Every OTHER read sees the bare int, where null is 0:
// `$y = $x` copied int(0), `return $x` from an `: int` function returned 0
// instead of php's TypeError, `$x < -1` answered false where php's null < -1
// is true, `$x === 0` answered true. So the lowering is a PROOF over the body,
// made by a token scan before the body is compiled (the src/packed.mc lexer),
// and it fails in the safe direction: a parameter whose every occurrence is
// not one of the shapes below keeps the zval, which is php's own semantics.
//
//   * `$x === null` / `$x !== null` (either order), bounded on both sides by
//     tokens of lower precedence, so the comparison is the whole operand;
//   * `$x ?? ...`, `isset($x)`, `is_null($x)`;
//   * `$x` as a WHOLE argument of a user function declared before this one
//     whose parameter there is a native `?int` (the pair is passed) or a
//     by-value zval (the pair is boxed) -- never a builtin, a method, a
//     plain `int`, a by-reference or a variadic parameter;
//   * a statement `$x = ...;` -- the write clears the flag (ph_opt_wflag);
//   * ANY use where $x is provably not null: inside the then-block of
//     `if ($x !== null) {`, and after an `if ($x === null) { ... }` whose
//     block ends in `return`/`throw` or is the single statement `$x = ...;`,
//     to the end of the enclosing block. Null is never written back (a null
//     assignment and unset() of an int are D4 refusals), so it stays proved.
//
// A body the scan cannot see through (a closure, a heredoc, `$$`, `?>`, ...)
// proves nothing, and so does a source with no body at all.
i64  ph_optok;              // 1 when the body was scanned
uptr ph_optbad;             // the names some occurrence disproved, 0-terminated

i64 ph_opt_safe(uptr d) { return ph_optok && !pkx_in(ph_optbad, d); }

i64 ph_opt_null(i64 i) { return pkx_isid(i, "null") || pkx_isid(i, "NULL"); }
i64 ph_opt_cmp(i64 i) { return pkx_isp(i, "===") || pkx_isp(i, "!=="); }
// a token an operand may start after / end before, of lower precedence than ===
i64 ph_opt_lo(i64 i) {
    return pkx_isp(i, "(") || pkx_isp(i, ",") || pkx_isp(i, ";") || pkx_isp(i, "{") || pkx_isp(i, "}")
        || pkx_isp(i, "&&") || pkx_isp(i, "||") || pkx_isp(i, "?") || pkx_isp(i, ":") || pkx_isp(i, "=")
        || pkx_isid(i, "return") || pkx_isid(i, "and") || pkx_isid(i, "or");
}
i64 ph_opt_hi(i64 i) {
    return pkx_isp(i, ")") || pkx_isp(i, ",") || pkx_isp(i, ";") || pkx_isp(i, "&&") || pkx_isp(i, "||")
        || pkx_isp(i, "?") || pkx_isp(i, ":") || pkx_isid(i, "and") || pkx_isid(i, "or");
}
i64 ph_opt_stmt(i64 i) { return i < 0 || pkx_isp(i, ";") || pkx_isp(i, "{") || pkx_isp(i, "}"); }

// the block ob..cb (a `{` and its `}`) leaves the function: its last top-level
// statement starts with `return` or `throw`
i64 ph_opt_exits(i64 ob, i64 cb) {
    if (!pkx_isp(cb - 1, ";")) return 0;
    i64 st = ob + 1;
    i64 j = ob + 1;
    loop {
        if (j >= cb) break;
        if (pkx_isp(j, "(") || pkx_isp(j, "[") || pkx_isp(j, "{")) {
            i64 m = pkx_mat(j);
            if (pkx_isp(j, "{")) st = m + 1;      // a nested block ends a statement
            j = m + 1;
            continue;
        }
        if (pkx_isp(j, ";")) { if (j == cb - 1) break; st = j + 1; }
        j = j + 1;
    }
    return pkx_isid(st, "return") || pkx_isid(st, "throw");
}

// the block ob..cb is the single statement `$x = ...;` for name index v
i64 ph_opt_fills(i64 ob, i64 cb, i64 v) {
    if (pkx_kind(ob + 1) != PKK_VAR || ld64(pkx_vi + (ob + 1) * 8) != v) return 0;
    if (!pkx_isp(ob + 2, "=") || !pkx_isp(cb - 1, ";")) return 0;
    i64 j = ob + 3;
    loop {
        if (j >= cb - 1) break;
        if (pkx_isp(j, "(") || pkx_isp(j, "[") || pkx_isp(j, "{")) { j = pkx_mat(j) + 1; continue; }
        if (pkx_isp(j, ";")) return 0;
        j = j + 1;
    }
    return 1;
}

// `$x` at token j is a whole argument of a user function whose parameter
// there takes the pair (?int) or a boxed zval
i64 ph_opt_arg(i64 j) {
    if (!pkx_isp(j - 1, "(") && !pkx_isp(j - 1, ",")) return 0;
    if (!pkx_isp(j + 1, ",") && !pkx_isp(j + 1, ")")) return 0;
    i64 k = j - 1;
    i64 idx = 0;
    loop {
        if (k < 0) return 0;
        if (pkx_isp(k, "(")) break;
        if (pkx_isp(k, "[") || pkx_isp(k, "{")) return 0;
        if (pkx_isp(k, ")") || pkx_isp(k, "]") || pkx_isp(k, "}")) { k = pkx_mat(k) - 1; continue; }
        if (pkx_isp(k, ",")) idx = idx + 1;
        k = k - 1;
    }
    if (pkx_kind(k - 1) != PKK_ID) return 0;
    if (pkx_isp(k - 2, "->") || pkx_isp(k - 2, "?->") || pkx_isp(k - 2, "::") || pkx_isp(k - 2, "\\")
        || pkx_isid(k - 2, "new") || pkx_isid(k - 2, "function")) return 0;
    i64 fi = ph_fn_find0(ld64(pkx_t + (k - 1) * 8));
    if (fi < 0) return 0;
    if (ld64(ph_fvar + fi * 8)) return 0;
    if (idx >= ld64(ph_fnp + fi * 8)) return 0;
    if ((ld64(ph_fpr + fi * 8) >> idx) & 1) return 0;
    i64 o = ld64(ph_fopt + (fi * PH_MAXP + idx) * 8);
    if (o == 1) return 1;
    return o == 0 && ld64(ph_fpt + (fi * PH_MAXP + idx) * 8) == PT_MIXED;
}

// Called with the parameter list's `(` as the current token.
void ph_opt_scan() {
    ph_optok = 0;
    ph_optbad = 0;
    uptr src = p_cp();
    i64 len = p_src_end() - src;
    if (len <= 0) return;
    // past the parameter list's `)`, then the return type, to the body's `{`
    i64 dp = 1;
    i64 i = 0;
    loop {
        if (i >= len) return;
        i64 h = ph_scan_hop(src, len, i);
        if (h != i) { i = h; continue; }
        i64 c = ld8(src + i);
        i = i + 1;
        if (c == 40) dp = dp + 1;
        if (c == 41) { dp = dp - 1; if (!dp) break; }
    }
    loop {
        if (i >= len) return;
        i64 h2 = ph_scan_hop(src, len, i);
        if (h2 != i) { i = h2; continue; }
        i64 c2 = ld8(src + i);
        if (c2 == 123) break;
        if (c2 == 59 || c2 == 40 || c2 == 61 || c2 == 125) return;
        i = i + 1;
    }
    pkx_reset();
    pkx_lex(src + i + 1, len - i - 1);
    if (pkx_bad) return;
    pkx_nest();
    if (pkx_bad) return;
    // proved non-null, per token
    uptr nn = xalloc(pkx_n * 8 + 8);
    i64 t = 0;
    loop { if (t > pkx_n) break; st64(nn + t * 8, 0); t = t + 1; }
    t = 0;
    loop {
        if (t >= pkx_n) break;
        if (pkx_isid(t, "if") && pkx_isp(t + 1, "(") && pkx_mat(t + 1) == t + 5 && pkx_isp(t + 6, "{")) {
            i64 vt = 0 - 1;
            if (pkx_kind(t + 2) == PKK_VAR && ph_opt_cmp(t + 3) && ph_opt_null(t + 4)) vt = t + 2;
            if (ph_opt_null(t + 2) && ph_opt_cmp(t + 3) && pkx_kind(t + 4) == PKK_VAR) vt = t + 4;
            if (vt >= 0) {
                i64 v = ld64(pkx_vi + vt * 8);
                i64 ob = t + 6;
                i64 cb = pkx_mat(ob);
                i64 lo = 0 - 1;
                i64 hi = 0 - 1;
                if (pkx_isp(t + 3, "!==")) { lo = ob; hi = cb; }
                if (pkx_isp(t + 3, "===") && ph_opt_stmt(t - 1) && (ph_opt_exits(ob, cb) || ph_opt_fills(ob, cb, v))) {
                    lo = cb;
                    hi = pkx_n;
                    i64 eb = ld64(pkx_b + t * 8);
                    if (eb >= 0) hi = pkx_mat(eb);
                }
                i64 j = lo + 1;
                loop {
                    if (lo < 0 || j >= hi) break;
                    if (pkx_kind(j) == PKK_VAR && ld64(pkx_vi + j * 8) == v) st64(nn + j * 8, 1);
                    j = j + 1;
                }
            }
        }
        t = t + 1;
    }
    // every other occurrence must be one of the listed shapes
    uptr bad = xalloc(pkx_nv * 8 + 8);
    i64 v2 = 0;
    loop { if (v2 >= pkx_nv) break; st64(bad + v2 * 8, ld64(pkx_vx + v2 * 8)); v2 = v2 + 1; }
    i64 j2 = 0;
    loop {
        if (j2 >= pkx_n) break;
        if (pkx_kind(j2) == PKK_VAR && !ld64(nn + j2 * 8)) {
            i64 ok = 0;
            if (ph_opt_lo(j2 - 1) && ph_opt_cmp(j2 + 1) && ph_opt_null(j2 + 2) && ph_opt_hi(j2 + 3)) ok = 1;
            if (ph_opt_lo(j2 - 3) && ph_opt_null(j2 - 2) && ph_opt_cmp(j2 - 1) && ph_opt_hi(j2 + 1)) ok = 1;
            if (ph_opt_lo(j2 - 1) && pkx_isp(j2 + 1, "??")) ok = 1;
            if ((pkx_isid(j2 - 2, "isset") || pkx_isid(j2 - 2, "is_null")) && pkx_isp(j2 - 1, "(") && pkx_isp(j2 + 1, ")")) ok = 1;
            if (ph_opt_stmt(j2 - 1) && pkx_isp(j2 + 1, "=")) ok = 1;
            if (!ok && ph_opt_arg(j2)) ok = 1;
            if (!ok) st64(bad + ld64(pkx_vi + j2 * 8) * 8, 1);
        }
        j2 = j2 + 1;
    }
    ph_optbad = xalloc(pkx_nv * 8 + 8);
    i64 a = 0;
    v2 = 0;
    loop {
        if (v2 >= pkx_nv) break;
        if (ld64(bad + v2 * 8)) { st64(ph_optbad + a * 8, ld64(pkx_vn + v2 * 8)); a = a + 1; }
        v2 = v2 + 1;
    }
    st64(ph_optbad + a * 8, 0);
    ph_optok = 1;
}

// After the body: every assignment of a native `?int` (whichever lowering
// made it -- a statement, an expression's pending store, ++/--) is followed by
// clearing its null flag, so a later `=== null`, isset() or a pair passed on
// sees the value just written and not the null the call came in with.
void ph_opt_wflag(i64 s, uptr v, uptr f) {
    loop {
        if (!s) break;
        ph_opt_wflag(nd_a(s), v, f);
        ph_opt_wflag(nd_b(s), v, f);
        ph_opt_wflag(nd_c(s), v, f);
        ph_opt_wflag(nd_d(s), v, f);
        if (nd_kind(s) == N_ASSIGN && str_eq(nd_name(s), v)) {
            i64 z = node_new(N_ASSIGN, ph_tline, ph_tfile);
            set_nd_name(z, f);
            set_nd_a(z, ph_int(0));
            set_nd_next(z, nd_next(s));
            set_nd_next(s, z);
            s = z;
        }
        s = nd_next(s);
    }
}

i64 ph_function() {
    i64 line = ph_tline;
    uptr fl = ph_tfile;
    ph_next();                                    // function
    // `function &f()`: php returns a reference. D7 has no refcount and no
    // free, so what `&` can mean here is that the value does NOT get copied
    // on the way out -- a returned zval IS the callee's cell. A caller that
    // writes through it (`$r = &f(); $r = 1;`) then sees the alias; one that
    // assigns by value copies as it always did.
    i64 retref = 0;
    if (ph_at("&", 1)) { ph_next(); retref = 1; }
    // reset per function (restored at the end for a nested declaration): 1 once
    // the body lowers a call that may push a pool temporary. src/rc.mc reads it
    // to decide whether the drain is needed.
    i64 sfp = ph_fn_pushes;
    ph_fn_pushes = 0;
    // a function body parsed inside a guarded branch (`if (is_string($t)) {
    // function g(...) ... }`) starts with clean narrowing and restores the
    // enclosing branch's on the way out -- both exits below
    uptr snn = ph_narrow_name;
    i64 snt = ph_narrow_ty;
    ph_narrow_name = 0;
    ph_narrow_ty = 0;
    if (ph_tid != T_IDENT) ph_todo(fl, line, "an anonymous function or closure");
    uptr name = ph_ns_decl(ph_tname);                // `ns\name` inside a namespace
    uptr xab = ph_ext_ab;
    ph_ext_ab = 0;
    ph_next();
    // a call earlier in the file already made the row (php hoists the
    // declaration): take it over rather than refusing it as a duplicate, and
    // keep the zval signature it was called with
    i64 fi = ph_fn_find0(name);
    i64 fwd = 0;
    if (fi >= 0) {
        if (!ld64(ph_ffwd + fi * 8)) err_at2(fl, line, "mc-php: this php function is declared twice", name);
        fwd = 1;
        st64(ph_ffwd + fi * 8, 0);
    }
    if (fi < 0) {
        if (ph_nfn >= PH_MAXFN) err_at(fl, line, "mc-php: too many php functions");
        fi = ph_nfn;
        ph_nfn = ph_nfn + 1;
    }
    ph_last_fn = fi;
    // the #[Extern] path returns here, before the normal end's restore: put the
    // enclosing state back on this exit too (ph_fn_pushes was reset at the top)
    if (xab) { ph_ext_ab = xab; ph_fn_pushes = sfp; ph_narrow_name = snn; ph_narrow_ty = snt; return ph_extern_fn(name, fi, fwd, fl, line); }
    st64(ph_fname + fi * 8, name);
    st64(ph_fret + fi * 8, PT_MIXED);
    st64(ph_fnp + fi * 8, 0);
    st64(ph_fvar + fi * 8, 0);
    st64(ph_fvpc + fi * 8, 0);
    st64(ph_fpr + fi * 8, 0);
    st64(ph_frr + fi * 8, retref);

    ph_opt_scan();                                // which ?int parameters stay native
    ph_want("(", 1, "expected ( in a php function");
    uptr save = ph_scope_save();
    i64 scp = ph_ncp;
    i64 scz = ph_cpzv;
    uptr snl = ph_nargs_local;
    ph_ncp = 0;
    ph_cpzv = 1;
    i64 head = 0;
    i64 tail = 0;
    i64 np = 0;
    i64 pre = 0;
    i64 pret = 0;
    // a mixed parameter's by-value copy node and its mc name, one slot per
    // parameter: after the body is parsed, a parameter the body only READS
    // drops the copy and borrows the caller's zval (see below)
    u8 bvn[96];
    u8 bvm[96];
    i64 nbv = 0;
    loop {
        if (ph_at(")", 1)) break;
        i64 variadic = 0;
        if (ph_at("...", 3)) { ph_next(); variadic = 1; }
        i64 byref = 0;
        if (ph_at("&", 1)) { ph_next(); byref = 1; }
        i64 pt = -1;
        ph_lt_k = BK_ANY;
        ph_lt_n = 0;
        ph_lt_null = 0;
        if (!ph_at("$", 1) && !ph_at("...", 3)) pt = ph_type_word(0);
        ph_bnd_set(fi, np, pt);
        // The DECLARED primitive, kept for the coercion below: a parameter
        // with a default -- or one a forward call already fixed -- is forced
        // to PT_MIXED so that "not passed" is expressible, and with it went
        // the type check php still performs. `function f(int $x = 1)` then
        // `f([])` was accepted as a zval and ran the body where php raises a
        // TypeError. php_param_coerce returns its argument unchanged when it
        // is 0, so the same call composes with "not passed".
        i64 pcw = 0;
        if (pt == PT_INT)    pcw = 1;
        if (pt == PT_FLOAT)  pcw = 2;
        if (pt == PT_STRING) pcw = 3;
        if (pt == PT_BOOL)   pcw = 4;
        if (pt == PT_ARR)    pcw = 5;
        // `int ...$n`: the type comes first and the ... after it
        if (ph_at("...", 3)) { ph_next(); variadic = 1; }
        if (!ph_at("$", 1)) ph_todo2(fl, line, "a php parameter", ph_tname);
        ph_next();
        uptr d = p_cat("$", ph_tname, 0, cstrlen(ph_tname));
        ph_next();
        i64 dflt = 0;
        // the default's value when it is an int LITERAL (`= 0`, `= 2`): the
        // one shape a native parameter can be filled with in its prologue
        i64 dint = 0;
        i64 dlit = 0;
        i64 dnul = 0;
        if (ph_accept("=", 1)) {
            i64 dv = ph_expr(0);
            if (ph_ety == PT_INT && nd_kind(dv) == N_INT) { dlit = 1; dint = nd_val(dv); }
            if (ph_ety == PT_NULL) dnul = 1;
            dflt = ph_to_mixed(dv, ph_ety);
        }
        // a NULLABLE SCALAR parameter (?int/?float/?string/?bool, with or
        // without a default): carried as the native value plus a u8 null flag,
        // not a heap zval. ph_lt_k is 10 + the scalar type (src/types.mc).
        // Not for a by-reference, a variadic, or a forward-widened row -- those
        // keep the zval. "Not passed" and "null" are the flag; the value local
        // is 0 when null, which is php's null in every arithmetic the body does
        // after the `=== null` guard the idiom requires.
        i64 isopt = 0;
        i64 optst = 0;
        // int only: a value type the handler reads call-free with no ownership.
        // ?string would borrow an engine zend_string (an escape question) and
        // ?float needs a reinterpret, so those keep the zval for now.
        // Only when "not passed" IS null (no default, or `= null`: the flag
        // cannot tell a `= 5` default from an explicit null) and the body scan
        // proved every use of it (ph_opt_scan).
        if (pt == PT_MIXED && ph_lt_null && ph_lt_k == 10 + PT_INT
            && !byref && !variadic && !fwd && (!dflt || dnul) && ph_opt_safe(d)) {
            optst = PT_INT;
            isopt = 1;
            pt = optst;
        }
        // a parameter with no declared type IS mixed (D4 (c)); so is one with
        // a default, because "not passed" has to be expressible -- but a native
        // nullable scalar expresses "not passed / null" in its flag, so it keeps
        // its scalar type
        // A plain `int $x = <int literal>` keeps its native int too: it takes
        // the same value + u8 flag slots, but the flag means "not passed" only
        // (php_param_coerce / phx_chk2 refuse a null: the declaration is not
        // nullable) and the prologue below fills the literal. The variable
        // itself is never null, so it is NOT bound as an opt one.
        i64 dfill = 0;
        if (!isopt && pt == PT_INT && dlit && !ph_lt_null && !byref && !variadic && !fwd) {
            isopt = 2;
            dfill = 1;
        }
        if (!isopt && (pt < 0 || dflt)) pt = PT_MIXED;
        if (variadic) pt = PT_ARR;
        // reached by a call before the declaration: the row the call was
        // built against says zval, so the definition has to agree
        if (fwd && !variadic) {
            i64 rowt = PT_MIXED;
            if (np < PH_MAXP) rowt = ld64(ph_fpt + (fi * PH_MAXP + np) * 8);
            if (rowt != PT_MIXED) {
                // the scan typed this parameter from the same text: it is the
                // native one the calls were built against (src/tables.mc)
                if (rowt != pt || isopt || byref)
                    err_at2(fl, line, "mc-php: internal error: a call before this declaration was built with another parameter type", name);
            } else {
                if (pt != PT_MIXED) st64(ph_fwid + fi * 8, 1);
                pt = PT_MIXED;
            }
        }
        // a by-reference parameter IS the caller's zval: the callee writes
        // through it (php_zv_store), which is the same mechanism `$a = &$b`
        // and `global $x` already use
        if (byref) pt = PT_MIXED;
        if (np >= PH_MAXP) ph_todo(fl, line, "more than 12 parameters");
        ph_var_bind_raw(d, pt);
        if (isopt == 1) ph_set_opt(d);
        if (byref) { ph_set_ref(d); st64(ph_fpr + fi * 8, ld64(ph_fpr + fi * 8) | (1 << np)); }
        if (np < PH_MAXCP) st64(ph_cpn + np * 8, d);
        if (pt != PT_MIXED) ph_cpzv = 0;
        st64(ph_fpt + (fi * PH_MAXP + np) * 8, pt);
        st64(ph_fopt + (fi * PH_MAXP + np) * 8, isopt);
        st64(ph_fpn + (fi * PH_MAXP + np) * 8, d + 1);
        st64(ph_fpd + (fi * PH_MAXP + np) * 8, dflt);
        np = np + 1;
        i64 pn = param_new(ph_mcty(pt), ph_mangle(d, "v_"));
        if (tail) set_nd_next(tail, pn);
        if (!tail) head = pn;
        tail = pn;
        // a native nullable scalar's null flag is a second mc parameter right
        // after its value, so the body, the handler and every caller agree on
        // the slot order
        if (isopt) {
            i64 fnp = param_new(TY_U8, ph_vflag(d));
            set_nd_next(pn, fnp);
            tail = fnp;
        }
        if (dfill) {
            // not passed: the literal, before the body reads it
            i64 fr = node_new(N_IDENT, line, fl);
            set_nd_name(fr, ph_vflag(d));
            set_nd_type(fr, TY_U8);
            i64 iff2 = node_new(N_IF, line, fl);
            set_nd_a(iff2, fr);
            set_nd_b(iff2, ph_set(ph_mangle(d, "v_"), ph_int(dint)));
            if (pret) set_nd_next(pret, iff2);
            if (!pret) pre = iff2;
            pret = iff2;
        }
        if (pt == PT_MIXED) {
            if (!byref) {
                i64 bv = ph_byval(d, line, fl);
                if (nbv < 12) { st64(bvn + nbv * 8, bv); st64(bvm + nbv * 8, ph_mangle(d, "v_")); nbv = nbv + 1; }
                if (pret) set_nd_next(pret, bv);
                if (!pret) pre = bv;
                pret = bv;
            }
            // the declared type, on the parameters that lost it. BEFORE the
            // fill below, so a parameter that was not passed is still 0 and
            // php_param_coerce leaves it for the default.
            if (pcw && !byref && !variadic) {
                uptr bare3 = d + 1;
                i64 pv4 = node_new(N_IDENT, line, fl);
                set_nd_name(pv4, ph_mangle(d, "v_"));
                set_nd_type(pv4, ty_pzv);
                u8 pcb[64];
                st64(pcb, pv4);
                st64(pcb + 8, ph_int(pcw));
                st64(pcb + 16, ph_strlit("", 0));
                st64(pcb + 24, ph_strlit(name, cstrlen(name)));
                st64(pcb + 32, ph_int(np + 1));
                st64(pcb + 40, ph_strlit(bare3, cstrlen(bare3)));
                i64 cz2 = ph_set(ph_mangle(d, "v_"),
                                 ph_calln("php_param_coerce", pcb, 6, ty_pzv));
                if (pret) set_nd_next(pret, cz2);
                if (!pret) pre = cz2;
                pret = cz2;
            }
            // a zval parameter that was not passed arrives as 0
            i64 miss = node_new(N_UNARY, line, fl);
            set_nd_op(miss, ph_tok("!", 1));
            i64 pr = node_new(N_IDENT, line, fl);
            set_nd_name(pr, ph_mangle(d, "v_"));
            set_nd_type(pr, ty_pzv);
            set_nd_a(miss, pr);
            set_nd_type(miss, TY_U8);
            i64 fill = 0;
            if (dflt) fill = ph_set(ph_mangle(d, "v_"), dflt);
            if (!dflt) fill = ph_stmt_of(ph_c2("php_argcount", ph_strlit("", 0),
                                               ph_strlit(name, cstrlen(name)), TY_VOID));
            i64 iff = node_new(N_IF, line, fl);
            set_nd_a(iff, miss);
            set_nd_b(iff, fill);
            if (pret) set_nd_next(pret, iff);
            if (!pret) pre = iff;
            pret = iff;
        }
        if (variadic) {
            st64(ph_fvar + fi * 8, 1);
            // `int ...$xs` is an array of ints to the callee, so the declared
            // type is erased above. php still checks it, per ARGUMENT, at the
            // call -- and only the CALLER has the arguments, so the element
            // type travels here and the packing loop coerces with it. A
            // by-reference variadic is left alone: coercing there would write
            // a new zval where the caller's own cell has to stay.
            if (!byref) st64(ph_fvpc + fi * 8, pcw);
            break;
        }
        if (!ph_accept(",", 1)) break;
    }
    ph_want(")", 1, "expected ) in a php function");
    ph_ncp = np;
    if (np > PH_MAXCP) ph_ncp = PH_MAXCP;
    st64(ph_fnp + fi * 8, np);
    i64 rt = PT_MIXED;
    ph_lt_k = BK_ANY;
    ph_lt_n = 0;
    ph_lt_null = 0;
    i64 drt = -1;
    if (ph_at(":", 1)) { ph_next(); rt = ph_type_word(1); drt = rt; }
    ph_bnd_set(fi, PH_MAXP, drt);
    if (fwd && rt != PT_VOID && rt != PT_MIXED) st64(ph_fwid + fi * 8, 1);
    if (fwd && rt != PT_VOID) rt = PT_MIXED;
    st64(ph_fret + fi * 8, rt);
    uptr mn = ph_mangle(name, "f_");
    p_set_decl_name(mn);
    uptr savefn = ph_cur_fn;
    ph_cur_fn = name;
    i64 sret = ph_fn_ret;
    ph_fn_ret = rt;
    i64 srr = ph_fn_retref;
    ph_fn_retref = retref;
    i64 stl2 = ph_toplevel;
    ph_toplevel = 0;
    i64 sls2 = ph_nls;
    ph_nls = 0;
    i64 hh = ph_hoist_head;
    i64 ht = ph_hoist_tail;
    ph_hoist_head = 0;
    ph_hoist_tail = 0;
    i64 nap = ph_nargs_prologue(fl, line);
    // a missing required argument makes `php_argcount` raise, and the body
    // must not run after it (docs/review-backlog.md section 2). The check is
    // the one every statement uses; `ph_in_try` is cleared around a body for
    // the same reason -- a `function` declared inside a try block would
    // otherwise emit that try's `break`.
    i64 sit = ph_in_try;
    ph_in_try = 0;
    uptr sfv = ph_frv;
    uptr sff = ph_frf;
    ph_frv = 0;
    ph_frf = 0;
    if (pre) pre = ph_prefix_stmts(pre, ph_check(line, fl));
    // src/packed.mc: which arrays of this body are provably packed ints --
    // scanned before the body is compiled, and put back after it for the
    // body a nested declaration interrupted
    uptr spk = pkx_names;
    uptr spf = pkx_fixed;
    if (ph_at("{", 1)) ph_pk_scan();
    i64 body = ph_block();
    // a write to a native ?int clears its null flag (ph_opt_scan's proof
    // admits writes on that condition)
    i64 oj = 0;
    loop {
        if (oj >= ph_nvar) break;
        if (ld64(ph_vopt + oj * 8)) {
            uptr od = ld64(ph_vname + oj * 8);
            ph_opt_wflag(nd_a(body), ph_mangle(od, "v_"), ph_vflag(od));
        }
        oj = oj + 1;
    }
    pkx_names = spk;
    pkx_fixed = spf;
    ph_in_try = sit;
    ph_frv = sfv;
    ph_frf = sff;
    // A mixed parameter the body only READS needs no by-value copy: it can
    // borrow the caller's zval for the whole call, which the caller holds like
    // php holds an argument. ph_pin_used (src/rc.mc) is the same "is this name
    // ever written or escaped" walk the global/static pin uses -- it is 1 for
    // any occurrence of v_x that is not the first argument of a known READ
    // accessor: a write (through a write accessor), a return, a mixed argument,
    // a container store, a by-reference pass, a by-ref closure capture. When it
    // is 0 the body cannot mutate the caller's value through $x and cannot keep
    // it past the call, so php_zv_val is pure cost and the copy is dropped.
    // Default = keep: a missed write would be a use-after-free, so the walk
    // errs toward binding; a plain rebind `$x = ...` rebinds the pointer and
    // never touches the caller, which is why it is not a blocking use. Scanned
    // over the REAL body only (nd_a(body)); the copy node's own `if (truthy
    // ($x))` would otherwise read as a use of $x.
    i64 bj = 0;
    loop {
        if (bj >= nbv) break;
        if (ph_pin_used(nd_a(body), ld64(bvm + bj * 8))) st64(bvn + bj * 8, 0);  // keep: body writes/escapes
        bj = bj + 1;
    }
    i64 ndrp = 0;
    bj = 0;
    loop { if (bj >= nbv) break; if (ld64(bvn + bj * 8)) ndrp = ndrp + 1; bj = bj + 1; }
    if (ndrp) {
        i64 nh = 0;
        i64 nt = 0;
        i64 s = pre;
        loop {
            if (!s) break;
            i64 nx = nd_next(s);
            i64 drop = 0;
            i64 j = 0;
            loop { if (j >= nbv) break; if (ld64(bvn + j * 8) == s) drop = 1; j = j + 1; }
            if (!drop) {
                set_nd_next(s, 0);
                if (nt) set_nd_next(nt, s);
                if (!nt) nh = s;
                nt = s;
            }
            s = nx;
        }
        pre = nh;
    }
    if (pre) {
        i64 t = pre;
        loop { if (!nd_next(t)) break; t = nd_next(t); }
        set_nd_next(t, nd_a(body));
        set_nd_a(body, pre);
    }
    if (nap) {
        i64 t = nap;
        loop { if (!nd_next(t)) break; t = nd_next(t); }
        set_nd_next(t, nd_a(body));
        set_nd_a(body, nap);
    }
    if (ph_hoist_head) {
        set_nd_next(ph_hoist_tail, nd_a(body));
        set_nd_a(body, ph_hoist_head);
    }
    // A function declared int, float, string or bool that falls off its end
    // is php's TypeError, `f(): Return value must be of type int, none
    // returned`, reported at the closing brace -- not the zero the native
    // return would otherwise carry (found by the review of #19). A body
    // whose every path returns never reaches it.
    i64 rw = 0;
    if (rt == PT_INT)    rw = 1;
    if (rt == PT_FLOAT)  rw = 2;
    if (rt == PT_STRING) rw = 3;
    if (rt == PT_BOOL)   rw = 4;
    // The guard (and the name literal it hoists into a callee-saved register
    // for the whole call) is dead when the body's last statement already
    // leaves the function -- then the fall-off path does not exist. Every
    // ctype predicate ends in `return false;`, so this drops a per-call
    // register across the string path.
    i64 blast = nd_a(body);
    if (blast) { loop { if (!nd_next(blast)) break; blast = nd_next(blast); } }
    if (ph_always_returns(blast)) rw = 0;
    if (rw) {
        i64 cl = ph_close_line;
        i64 ps = ph_posstmt(fl, cl);
        i64 nr = ph_stmt_of(ph_c2("php_ret_none", ph_strlit(name, cstrlen(name)), ph_int(rw), TY_VOID));
        set_nd_next(ps, nr);
        i64 zr = node_new(N_RETURN, cl, fl);
        i64 zv = ph_int(0);
        if (rw == 2) zv = ph_cast(ty_f64, ph_int(0));
        if (rw == 3) zv = ph_strlit("", 0);
        if (rw == 4) zv = ph_cast(TY_U8, ph_int(0));
        set_nd_a(zr, zv);
        set_nd_next(nr, zr);
        i64 t3 = nd_a(body);
        if (!t3) set_nd_a(body, ps);
        if (t3) { loop { if (!nd_next(t3)) break; t3 = nd_next(t3); } set_nd_next(t3, ps); }
    }
    // a php function that falls off the end answers null
    if (rt == PT_MIXED) {
        i64 t2 = nd_a(body);
        if (!t2) set_nd_a(body, ph_ret_null(line, fl));
        if (t2) { loop { if (!nd_next(t2)) break; t2 = nd_next(t2); } set_nd_next(t2, ph_ret_null(line, fl)); }
    }
    ph_hoist_head = hh;
    ph_hoist_tail = ht;
    // AFTER the body: a `function` nested in it went through here too and
    // left ph_last_fn pointing at ITS row, so ph_program would export the
    // nested declaration and lose this one. Measured: `function outer() {
    // function nested() {} }` published `nested` and not `outer`.
    ph_last_fn = fi;
    ph_scope_restore(save);
    ph_ncp = scp;
    ph_cpzv = scz;
    ph_nargs_local = snl;
    ph_cur_fn = savefn;
    ph_fn_ret = sret;
    ph_fn_retref = srr;
    ph_toplevel = stl2;
    ph_nls = sls2;
    i64 f = node_new(N_FUNC, line, fl);
    set_nd_name(f, mn);
    set_nd_type(f, ph_mcty(rt));
    set_nd_a(f, head);
    set_nd_b(f, body);
    // src/opt.mc: calls to smaller functions declared earlier are copied in,
    // and this one may be copied into later ones -- only a plain signature
    i64 inl = !retref && !fwd && !nap && !ld64(ph_fpr + fi * 8) && !ld64(ph_fvar + fi * 8);
    i64 kd = 0;
    loop {
        if (kd >= np) break;
        if (ld64(ph_fpd + (fi * PH_MAXP + kd) * 8)) inl = 0;
        kd = kd + 1;
    }
    ph_inl_fn(f, inl);
    ph_view_fn(f);
    ph_rope_fn(f);
    ph_rc_fn(f);
    ph_opt_fn(f);
    ph_fn_pushes = sfp;
    ph_narrow_name = snn;
    ph_narrow_ty = snt;
    return f;
}

void ph_lib_init() {
    ph_lib("str_rot13", "php_f_str_rot13", 1, 1, PT_STRING);
    ph_lib("quotemeta", "php_f_quotemeta", 1, 1, PT_STRING);
    ph_lib("strpbrk", "php_f_strpbrk", 2, 2, PT_MIXED);
    ph_lib("substr_compare", "php_f_substr_compare", 3, 5, PT_INT);
    ph_lib("levenshtein", "php_f_levenshtein", 2, 2, PT_INT);
    ph_lib("similar_text", "php_f_similar_text", 2, 3, PT_INT);
    ph_lib("soundex", "php_f_soundex", 1, 1, PT_STRING);
    ph_lib("count_chars", "php_f_count_chars", 1, 2, PT_MIXED);
    ph_lib("str_word_count", "php_f_str_word_count", 1, 3, PT_ARR);
    ph_lib("basename", "php_f_basename", 1, 2, PT_STRING);
    ph_lib("dirname", "php_f_dirname", 1, 2, PT_STRING);
    ph_lib("crc32", "php_f_crc32", 1, 1, PT_INT);
    ph_lib("urlencode", "php_f_urlencode0", 1, 1, PT_STRING);
    ph_lib("rawurlencode", "php_f_rawurlencode", 1, 1, PT_STRING);
    ph_lib("urldecode", "php_f_urldecode", 1, 1, PT_STRING);
    ph_lib("rawurldecode", "php_f_urldecode", 1, 1, PT_STRING);
    ph_lib("htmlspecialchars_decode", "php_f_hsd2", 1, 2, PT_STRING);
    ph_lib("html_entity_decode", "php_f_htmlspecialchars_decode", 1, 3, PT_STRING);
    ph_lib("str_increment", "php_f_str_increment", 1, 1, PT_STRING);
    ph_lib("unpack", "php_f_unpack", 2, 3, PT_MIXED);
    ph_lib("get_html_translation_table", "php_f_get_html_translation_table", 0, 3, PT_ARR);
    ph_lib("serialize", "php_f_serialize", 1, 1, PT_STRING);
    ph_lib("unserialize", "php_f_unserialize", 1, 2, PT_MIXED);
    ph_lib("str_getcsv", "php_f_str_getcsv", 1, 4, PT_ARR);
    ph_lib("quoted_printable_encode", "php_f_quoted_printable_encode", 1, 1, PT_STRING);
    ph_lib("quoted_printable_decode", "php_f_quoted_printable_decode", 1, 1, PT_STRING);
    ph_lib("convert_uuencode", "php_f_convert_uuencode", 1, 1, PT_STRING);
    ph_lib("convert_uudecode", "php_f_convert_uudecode", 1, 1, PT_STRING);
    ph_lib("mb_internal_encoding", "php_f_mb_internal_encoding", 0, 1, PT_MIXED);
    ph_lib("settype", "php_f_settype", 2, 2, PT_BOOL);
    ph_lib("str_decrement", "php_f_str_decrement_n", 1, 1, PT_MIXED);
    ph_lib("array_splice", "php_f_array_splice", 2, 4, PT_MIXED);
    ph_lib("parse_str", "php_f_parse_str", 2, 2, PT_BOOL);
    ph_lib("uniqid", "php_f_uniqid", 0, 2, PT_MIXED);
    // T8: files and streams
    ph_lib("fopen", "php_f_fopen", 2, 4, PT_MIXED);
    ph_lib("fclose", "php_f_fclose", 1, 1, PT_BOOL);
    ph_lib("fwrite", "php_f_fwrite", 2, 3, PT_MIXED);
    ph_lib("fputs", "php_f_fwrite", 2, 3, PT_MIXED);
    ph_lib("fread", "php_f_fread", 2, 2, PT_MIXED);
    ph_lib("fgets", "php_f_fgets", 1, 2, PT_MIXED);
    ph_lib("fgetc", "php_f_fgetc", 1, 1, PT_MIXED);
    ph_lib("feof", "php_f_feof", 1, 1, PT_BOOL);
    ph_lib("fseek", "php_f_fseek", 2, 3, PT_INT);
    ph_lib("ftell", "php_f_ftell", 1, 1, PT_MIXED);
    ph_lib("rewind", "php_f_rewind", 1, 1, PT_BOOL);
    ph_lib("fflush", "php_f_fflush", 1, 1, PT_BOOL);
    ph_lib("flock", "php_f_flock", 2, 2, PT_BOOL);
    ph_lib("is_resource", "php_f_is_resource", 1, 1, PT_BOOL);
    ph_lib("file_get_contents", "php_f_file_get_contents", 1, 1, PT_MIXED);
    ph_lib("file_put_contents", "php_f_file_put_contents", 2, 3, PT_MIXED);
    ph_lib("file", "php_f_file", 1, 2, PT_MIXED);
    ph_lib("readfile", "php_f_readfile", 1, 1, PT_MIXED);
    ph_lib("unlink", "php_f_unlink", 1, 1, PT_BOOL);
    ph_lib("rename", "php_f_rename", 2, 2, PT_BOOL);
    ph_lib("copy", "php_f_copy", 2, 2, PT_BOOL);
    ph_lib("file_exists", "php_f_file_exists", 1, 1, PT_BOOL);
    ph_lib("is_file", "php_f_is_file", 1, 1, PT_BOOL);
    ph_lib("is_dir", "php_f_is_dir", 1, 1, PT_BOOL);
    ph_lib("is_readable", "php_f_is_readable", 1, 1, PT_BOOL);
    ph_lib("is_writable", "php_f_is_writable", 1, 1, PT_BOOL);
    ph_lib("is_writeable", "php_f_is_writable", 1, 1, PT_BOOL);
    ph_lib("is_executable", "php_f_is_executable", 1, 1, PT_BOOL);
    ph_lib("filesize", "php_f_filesize", 1, 1, PT_MIXED);
    ph_lib("mkdir", "php_f_mkdir", 1, 3, PT_BOOL);
    ph_lib("rmdir", "php_f_rmdir", 1, 1, PT_BOOL);
    ph_lib("touch", "php_f_touch", 1, 1, PT_BOOL);
    ph_lib("clearstatcache", "php_f_clearstatcache", 0, 2, PT_BOOL);
    ph_lib("sys_get_temp_dir", "php_f_sys_get_temp_dir", 0, 0, PT_STRING);
    ph_lib("tempnam", "php_f_tempnam", 2, 2, PT_MIXED);
    ph_lib("tmpfile", "php_f_tmpfile", 0, 0, PT_MIXED);
    ph_lib("getenv", "php_f_getenv", 0, 1, PT_MIXED);
    ph_lib("realpath", "php_f_realpath", 1, 1, PT_MIXED);
    ph_lib("stream_get_contents", "php_f_stream_get_contents", 1, 1, PT_MIXED);
    ph_lib("array_is_list", "php_f_array_is_list", 1, 1, PT_BOOL);
    ph_lib("getcwd", "php_f_getcwd", 0, 0, PT_MIXED);
    ph_lib("chdir", "php_f_chdir", 1, 1, PT_BOOL);
    ph_lib("chmod", "php_f_chmod", 2, 2, PT_BOOL);
    ph_lib("putenv", "php_f_putenv", 1, 1, PT_BOOL);
    // ext/json is D2(a): it IS php and is written in mc
    ph_lib("json_encode", "php_f_json_encode", 1, 3, PT_MIXED);
    ph_lib("json_decode", "php_f_json_decode", 1, 4, PT_MIXED);
    ph_lib("json_last_error", "php_f_json_last_error", 0, 0, PT_INT);
    ph_lib("json_last_error_msg", "php_f_json_last_error_msg", 0, 0, PT_MIXED);
    ph_lib("array_push", "php_f_array_push", 2, 4, PT_INT);
    ph_lib("array_column", "php_f_array_column", 2, 3, PT_ARR);
    ph_lib("array_diff", "php_f_array_diff", 2, 2, PT_ARR);
    ph_lib("array_diff_key", "php_f_array_diff_key", 2, 2, PT_ARR);
    ph_lib("array_intersect", "php_f_array_intersect", 2, 2, PT_ARR);
    ph_lib("array_intersect_key", "php_f_array_intersect_key", 2, 2, PT_ARR);
    ph_lib("array_pad", "php_f_array_pad", 3, 3, PT_ARR);
    ph_lib("array_chunk", "php_f_array_chunk", 2, 3, PT_ARR);
    ph_lib("current", "php_f_current", 1, 1, PT_MIXED);
    ph_lib("reset", "php_f_current", 1, 1, PT_MIXED);
    ph_lib("end", "php_f_end", 1, 1, PT_MIXED);
    ph_lib("key", "php_f_key", 1, 1, PT_MIXED);
    ph_lib("md5", "php_f_md5", 1, 2, PT_STRING);
    ph_lib("sha1", "php_f_sha1", 1, 2, PT_STRING);
    ph_lib("ucfirst", "php_f_ucfirst", 1, 1, PT_STRING);
    ph_lib("class_alias", "php_f_class_alias", 2, 3, PT_BOOL);
    ph_lib("register_shutdown_function", "php_f_reg_shutdown", 1, 4, PT_BOOL);
    ph_lib("strtok", "php_f_strtok", 1, 2, PT_MIXED);
    ph_lib("strnatcmp", "php_f_strnatcmp", 2, 2, PT_INT);
    ph_lib("strnatcasecmp", "php_f_strnatcasecmp", 2, 2, PT_INT);
    ph_lib("addcslashes", "php_f_addcslashes", 2, 2, PT_STRING);
    ph_lib("iterator_to_array", "php_f_iterator", 1, 2, PT_MIXED);
    ph_lib("lcg_value", "php_f_pi", 0, 0, PT_FLOAT);
    ph_lib("microtime", "php_f_noop", 0, 1, PT_INT);
    ph_lib("time", "php_f_zero", 0, 0, PT_INT);
    ph_lib("php_sapi_name", "php_f_sapi", 0, 0, PT_STRING);
    ph_lib("phpversion", "php_f_phpversion", 0, 1, PT_STRING);
    ph_lib("zend_version", "php_f_ver0", 0, 0, PT_STRING);
    ph_lib("func_num_args", "php_f_zero", 0, 0, PT_INT);
    ph_lib("trigger_error", "php_f_trigger", 1, 2, PT_BOOL);
    ph_lib("set_time_limit", "php_f_noop", 0, 1, PT_BOOL);
    ph_lib("date_default_timezone_set", "php_f_noop", 0, 1, PT_BOOL);
    ph_lib("assert_options", "php_f_null2", 0, 2, PT_MIXED);
    ph_lib("constant", "php_f_constant", 1, 1, PT_MIXED);
    ph_lib("str_contains", "php_f_contains", 2, 2, PT_BOOL);
    ph_lib("ctype_digit", "php_f_ctype", 1, 1, PT_BOOL);
    ph_lib("ctype_alpha", "php_f_ctype_a", 1, 1, PT_BOOL);
    ph_lib("ctype_alnum", "php_f_ctype_an", 1, 1, PT_BOOL);
    ph_lib("ctype_space", "php_f_ctype_sp", 1, 1, PT_BOOL);
    ph_lib("ctype_upper", "php_f_ctype_up", 1, 1, PT_BOOL);
    ph_lib("ctype_lower", "php_f_ctype_lo", 1, 1, PT_BOOL);
    ph_lib("ctype_punct", "php_f_ctype_pu", 1, 1, PT_BOOL);
    ph_lib("ctype_xdigit", "php_f_ctype_xd", 1, 1, PT_BOOL);
    ph_lib("get_class", "php_f_get_class", 0, 1, PT_MIXED);
    ph_lib("get_parent_class", "php_f_get_parent_class", 0, 1, PT_MIXED);
    ph_lib("class_exists", "php_f_class_exists", 1, 2, PT_BOOL);
    ph_lib("interface_exists", "php_f_class_exists", 1, 2, PT_BOOL);
    ph_lib("enum_exists", "php_f_class_exists", 1, 2, PT_BOOL);
    ph_lib("method_exists", "php_f_method_exists", 2, 2, PT_BOOL);
    ph_lib("property_exists", "php_f_property_exists", 2, 2, PT_BOOL);
    ph_lib("is_callable", "php_f_is_callable", 1, 3, PT_BOOL);
    ph_lib("array_map", "php_f_array_map", 2, 2, PT_ARR);
    ph_lib("array_filter", "php_f_array_filter", 1, 3, PT_ARR);
    ph_lib("array_reduce", "php_f_array_reduce", 2, 3, PT_MIXED);
    ph_lib("usort", "php_f_usort_a", 2, 2, PT_BOOL);
    ph_lib("uasort", "php_f_uasort", 2, 2, PT_BOOL);
    ph_lib("uksort", "php_f_uksort", 2, 2, PT_BOOL);
    ph_lib("spl_object_id", "php_f_obj_id", 1, 1, PT_INT);
    ph_lib("spl_object_hash", "php_f_spl_object_hash", 1, 1, PT_STRING);
    ph_lib("array_key_exists", "php_f_array_key_exists", 2, 2, PT_BOOL);
    ph_lib("key_exists", "php_f_array_key_exists", 2, 2, PT_BOOL);
    ph_lib("array_keys", "php_f_array_keys", 1, 1, PT_ARR);
    ph_lib("array_values", "php_f_array_values", 1, 1, PT_ARR);
    ph_lib("in_array", "php_f_in_array", 2, 3, PT_BOOL);
    ph_lib("array_search", "php_f_array_search", 2, 3, PT_MIXED);
    ph_lib("array_merge", "php_f_array_merge", 1, 4, PT_ARR);
    ph_lib("array_pop", "php_f_array_pop", 1, 1, PT_MIXED);
    ph_lib("array_shift", "php_f_array_shift", 1, 1, PT_MIXED);
    ph_lib("array_unshift", "php_f_array_unshift", 2, 2, PT_INT);
    ph_lib("array_slice", "php_f_array_slice", 2, 4, PT_ARR);
    ph_lib("array_reverse", "php_f_array_reverse", 1, 2, PT_ARR);
    ph_lib("array_sum", "php_f_array_sum", 1, 1, PT_MIXED);
    ph_lib("array_product", "php_f_array_product", 1, 1, PT_MIXED);
    ph_lib("array_flip", "php_f_array_flip", 1, 1, PT_ARR);
    ph_lib("array_unique", "php_f_array_unique", 1, 2, PT_ARR);
    ph_lib("array_combine", "php_f_array_combine", 2, 2, PT_ARR);
    ph_lib("array_fill", "php_f_array_fill", 3, 3, PT_ARR);
    ph_lib("array_fill_keys", "php_f_array_fill_keys", 2, 2, PT_ARR);
    ph_lib("array_key_first", "php_f_array_key_first", 1, 1, PT_MIXED);
    ph_lib("array_key_last", "php_f_array_key_last", 1, 1, PT_MIXED);
    ph_lib("range", "php_f_range", 2, 3, PT_ARR);
    ph_lib("sort", "php_f_sort_a", 1, 2, PT_BOOL);
    ph_lib("rsort", "php_f_rsort", 1, 2, PT_BOOL);
    ph_lib("asort", "php_f_asort", 1, 2, PT_BOOL);
    ph_lib("arsort", "php_f_arsort", 1, 2, PT_BOOL);
    ph_lib("ksort", "php_f_ksort", 1, 2, PT_BOOL);
    ph_lib("krsort", "php_f_krsort", 1, 2, PT_BOOL);
    ph_lib("bin2hex", "php_f_bin2hex", 1, 1, PT_STRING);
    ph_lib("hex2bin", "php_f_hex2bin", 1, 1, PT_STRING);
    ph_lib("base64_encode", "php_f_base64_encode", 1, 1, PT_STRING);
    ph_lib("base64_decode", "php_f_base64_decode", 1, 2, PT_STRING);
    ph_lib("strspn", "php_f_strspn", 2, 4, PT_INT);
    ph_lib("strcspn", "php_f_strcspn", 2, 4, PT_INT);
    ph_lib("chunk_split", "php_f_chunk_split", 1, 3, PT_STRING);
    ph_lib("substr_replace", "php_f_substr_replace", 3, 4, PT_STRING);
    ph_lib("substr_count", "php_f_substr_count", 2, 4, PT_INT);
    ph_lib("strrpos", "php_f_strrpos", 2, 3, PT_IFALSE);
    ph_lib("stripos", "php_f_stripos", 2, 3, PT_IFALSE);
    ph_lib("strripos", "php_f_strripos", 2, 3, PT_IFALSE);
    ph_lib("strstr", "php_f_strstr", 2, 3, PT_MIXED);
    ph_lib("stristr", "php_f_stristr", 2, 3, PT_MIXED);
    ph_lib("strchr", "php_f_strstr", 2, 3, PT_MIXED);
    ph_lib("strrchr", "php_f_strrchr", 2, 2, PT_MIXED);
    ph_lib("strncmp", "php_f_strncmp", 3, 3, PT_INT);
    ph_lib("strncasecmp", "php_f_strncasecmp", 3, 3, PT_INT);
    ph_lib("str_ireplace", "php_f_str_ireplace", 3, 3, PT_STRING);
    ph_lib("str_split", "php_f_str_split", 1, 2, PT_ARR);
    ph_lib("ucwords", "php_f_ucwords", 1, 2, PT_STRING);
    ph_lib("nl2br", "php_f_nl2br", 1, 2, PT_STRING);
    ph_lib("strip_tags", "php_f_strip_tags", 1, 2, PT_STRING);
    ph_lib("addslashes", "php_f_addslashes", 1, 1, PT_STRING);
    ph_lib("stripslashes", "php_f_stripslashes", 1, 1, PT_STRING);
    ph_lib("htmlspecialchars", "php_f_htmlspecialchars", 1, 4, PT_STRING);
    ph_lib("htmlentities", "php_f_htmlspecialchars", 1, 4, PT_STRING);
    ph_lib("wordwrap", "php_f_wordwrap", 1, 4, PT_STRING);
    ph_lib("strtr", "php_f_strtr", 2, 3, PT_STRING);
    ph_lib("number_format", "php_f_number_format", 1, 4, PT_STRING);
    ph_lib("dechex", "php_f_dechex", 1, 1, PT_STRING);
    ph_lib("decbin", "php_f_decbin", 1, 1, PT_STRING);
    ph_lib("decoct", "php_f_decoct", 1, 1, PT_STRING);
    ph_lib("hexdec", "php_f_hexdec", 1, 1, PT_INT);
    ph_lib("bindec", "php_f_bindec", 1, 1, PT_INT);
    ph_lib("octdec", "php_f_octdec", 1, 1, PT_INT);
    ph_lib("base_convert", "php_f_base_convert", 3, 3, PT_STRING);
    ph_lib("floor", "php_f_floor", 1, 1, PT_FLOAT);
    ph_lib("ceil", "php_f_ceil", 1, 1, PT_FLOAT);
    ph_lib("round", "php_f_round", 1, 3, PT_FLOAT);
    ph_lib("sqrt", "php_f_sqrt", 1, 1, PT_FLOAT);
    ph_lib("fmod", "php_f_fmod", 2, 2, PT_FLOAT);
    ph_lib("exp", "php_f_exp", 1, 1, PT_FLOAT);
    ph_lib("log", "php_f_log", 1, 2, PT_FLOAT);
    ph_lib("sin", "php_f_sin", 1, 1, PT_FLOAT);
    ph_lib("cos", "php_f_cos", 1, 1, PT_FLOAT);
    ph_lib("tan", "php_f_tan", 1, 1, PT_FLOAT);
    ph_lib("asin", "php_f_asin", 1, 1, PT_FLOAT);
    ph_lib("acos", "php_f_acos", 1, 1, PT_FLOAT);
    ph_lib("atan", "php_f_atan", 1, 1, PT_FLOAT);
    ph_lib("sinh", "php_f_sinh", 1, 1, PT_FLOAT);
    ph_lib("cosh", "php_f_cosh", 1, 1, PT_FLOAT);
    ph_lib("tanh", "php_f_tanh", 1, 1, PT_FLOAT);
    ph_lib("asinh", "php_f_asinh", 1, 1, PT_FLOAT);
    ph_lib("acosh", "php_f_acosh", 1, 1, PT_FLOAT);
    ph_lib("atanh", "php_f_atanh", 1, 1, PT_FLOAT);
    ph_lib("expm1", "php_f_expm1", 1, 1, PT_FLOAT);
    ph_lib("log1p", "php_f_log1p", 1, 1, PT_FLOAT);
    ph_lib("atan2", "php_f_atan2", 2, 2, PT_FLOAT);
    ph_lib("hypot", "php_f_hypot", 2, 2, PT_FLOAT);
    ph_lib("deg2rad", "php_f_deg2rad", 1, 1, PT_FLOAT);
    ph_lib("rad2deg", "php_f_rad2deg", 1, 1, PT_FLOAT);
    ph_lib("fdiv", "php_f_fdiv", 2, 2, PT_FLOAT);
    ph_lib("log10", "php_f_log10", 1, 1, PT_FLOAT);
    ph_lib("pi", "php_f_pi", 0, 0, PT_FLOAT);
    ph_lib("is_nan", "php_f_is_nan", 1, 1, PT_BOOL);
    ph_lib("is_infinite", "php_f_is_infinite", 1, 1, PT_BOOL);
    ph_lib("is_finite", "php_f_is_finite", 1, 1, PT_BOOL);
    ph_lib("pow", "php_f_pow", 2, 2, PT_MIXED);
    ph_lib("mt_rand", "php_f_mt_rand", 0, 2, PT_INT);
    ph_lib("rand", "php_f_mt_rand", 0, 2, PT_INT);
    ph_lib("random_int", "php_f_mt_rand", 2, 2, PT_INT);
    ph_lib("mt_srand", "php_f_srand", 0, 2, PT_VOID);
    ph_lib("srand", "php_f_srand", 0, 2, PT_VOID);
    ph_lib("mt_getrandmax", "php_f_mt_getrandmax", 0, 0, PT_INT);
    ph_lib("getrandmax", "php_f_mt_getrandmax", 0, 0, PT_INT);
    ph_lib("gettype", "php_f_gettype", 1, 1, PT_STRING);
    ph_lib("get_debug_type", "php_f_get_debug_type", 1, 1, PT_STRING);
    ph_lib("print_r", "php_f_print_r", 1, 2, PT_STRING);
    ph_lib("var_export", "php_f_var_export", 1, 2, PT_STRING);
    ph_lib("ob_start", "php_f_ob_start", 0, 3, PT_BOOL);
    ph_lib("ob_get_clean", "php_f_ob_get_clean", 0, 0, PT_MIXED);
    ph_lib("ob_get_contents", "php_f_ob_get_contents", 0, 0, PT_MIXED);
    ph_lib("ob_get_length", "php_f_ob_get_length", 0, 0, PT_MIXED);
    ph_lib("ob_get_level", "php_f_ob_get_level", 0, 0, PT_INT);
    ph_lib("ob_end_clean", "php_f_ob_end_clean", 0, 0, PT_BOOL);
    ph_lib("ob_end_flush", "php_f_ob_end_flush", 0, 0, PT_BOOL);
    ph_lib("ob_get_flush", "php_f_ob_get_flush", 0, 0, PT_MIXED);
    ph_lib("ob_flush", "php_f_ob_flush", 0, 0, PT_BOOL);
    ph_lib("ob_implicit_flush", "php_f_ob_implicit_flush", 0, 1, PT_BOOL);
    // php declares `flush(): void`, and this row used to be shadowed: a second
    // `flush` was registered 145 rows earlier as php_f_zero, a no-op, and
    // ph_lib_find returns the FIRST match -- so flush() flushed nothing. The
    // duplicate is gone and this row carries php's own return type.
    ph_lib("flush", "php_f_flush", 0, 0, PT_VOID);
    ph_lib("error_reporting", "php_f_error_reporting", 0, 1, PT_INT);
    ph_lib("ini_set", "php_f_nullf", 0, 3, PT_MIXED);
    ph_lib("ini_get", "php_f_null1", 0, 1, PT_MIXED);
    ph_lib("set_error_handler", "php_f_set_error_handler", 1, 2, PT_MIXED);
    ph_lib("restore_error_handler", "php_f_restore_error_handler", 0, 0, PT_BOOL);
    ph_lib("set_exception_handler", "php_f_set_exception_handler", 1, 1, PT_MIXED);
    ph_lib("restore_exception_handler", "php_f_restore_exception_handler", 0, 0, PT_BOOL);
    ph_lib("setlocale", "php_f_setlocale", 1, 6, PT_MIXED);
    ph_lib("sscanf", "php_f_sscanf", 2, 8, PT_MIXED);
    ph_lib("gc_collect_cycles", "php_f_noop", 0, 1, PT_INT);
    ph_lib("error_log", "php_f_false1", 0, 1, PT_BOOL);
    ph_lib("usleep", "php_f_noop", 0, 1, PT_INT);
}


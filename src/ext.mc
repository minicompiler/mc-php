// ext.mc -- the extension back end: get_module(), the module entry, the
// zend_function_entry table and one handler per php function.
//
// The PROGRAM road is unchanged and is still the default: with no
// [extension] table in the project file this whole file emits nothing and the
// compiler writes `main` exactly as it did. That is the switch and there is
// no flag -- docs/mcphp-toml.md's rule that an extension is described by a
// FILE, kept.
//
// What it emits, for `function addone(int $n): int { ... }`:
//
//     void x_h_addone(uptr ex, uptr rv) {        // the Zend handler
//         phx_enter();
//         if (phx_arity(ex, 1, "addone")) {
//             if (phx_chk(ex, 0, 0, "addone", "n")) {
//                 st64(rv, f_addone(ld64(ex + 80))); st32(rv + 8, 4);
//             }
//         }
//         phx_leave();
//     }
//
//     uptr get_module() {
//         phx_fn("addone", &x_h_addone, 1, 0);
//         phx_arg("n", 0);
//         return phx_module("hello", "0.1.0", api, "API...,NTS", zts, dbg,
//                           &mc_php_minit, 0);
//     }
//
// and `main` becomes `mc_php_minit`, the module's MINIT, so the top-level
// statement stream (php_bootstrap, the class entries, a `declare`, a
// `require`) runs when php loads the module.
//
// Every byte layout is lib/php_ext.mc's, which is where the measurements are.
// This file knows no Zend offset at all.

// ---- the [extension] and [php] tables --------------------------------------
// ph_ext itself is in decls.mc: src/lvalue.mc reads it (a namespace in an
// extension source is a refusal there) and mc is single pass.
uptr ph_ext_name;
uptr ph_ext_ver;
uptr ph_ext_bid;
i64  ph_ext_api;
i64  ph_ext_zts;                // the module header's zts: 1 for the ZTS output
i64  ph_ext_dbg;
i64  ph_ts_both;                // [php].thread_safety = "both" (src/build.mc)

// the top-level php functions, in source order: what get_module registers
#define PH_MAXEXP 256
i64 ph_expi[PH_MAXEXP];
uptr ph_expf[PH_MAXEXP];        // the declaration's own file and line, so a
i64  ph_expl[PH_MAXEXP];        // refusal points at the function and not at <?php
i64 ph_nexp;

// A TOML boolean is TEXT in mc's parser (the table is flat and every value is
// a string), so "true" is what `debug = true` reads as.
i64 ph_ext_bool(uptr path, uptr what) {
    uptr v = toml_get(path);
    if (!v) err_at2("mcphp.toml", 1, "mc-php: this extension needs it", what);
    if (str_eq(v, "true")) return 1;
    if (str_eq(v, "false")) return 0;
    err_at2("mcphp.toml", 1, "mc-php: expected true or false", what);
    return 0;
}

// Read once, before the entry is parsed. There is no [php].bin: reading the
// four values out of a php binary means spawning one and parsing `php -i`,
// which belongs to the driver and not to a Tier 3 module -- so the four are
// stated, which is also what makes a cross-build need no php on the machine
// (docs/mcphp-toml.md § [php]).
// Is there an [extension] table at all? toml_get answers for a KEY and the
// switch is the TABLE, so the two questions are asked separately: a file with
// `[extension]` and a misspelt `name` must be an error and not a silent
// program build. mc's flat (path, value) table is walked the way [libs] and
// [externs] are walked in mc's own driver.
i64 ph_ext_has_table() {
    i64 n = toml_entries();
    i64 i = 0;
    loop {
        if (i >= n) break;
        uptr p = toml_path_at(i);
        if (ld8(p) == 101 && ld8(p + 1) == 120 && ld8(p + 2) == 116) {   // "ext"
            if (str_eq(xstrdup(p, 10), "extension.")) return 1;
        }
        i = i + 1;
    }
    return 0;
}

// [php].thread_safety: "nts" (the default), "zts" or "both" -- which php the
// OUTPUT is for, stated and never read off a php on this machine: the bytes
// depend on the file alone. "both" builds two outputs from one project
// (src/build.mc); this process then builds the NTS one. The key describes an
// extension's module header; the program road has none and ignores it, but a
// value it cannot mean is refused on either road, at its own position.
// The TOML booleans this key took before are refused with the word that
// replaces them.
void ph_ts_config() {
    uptr v = toml_get("php.thread_safety");
    if (!v) return;
    if (str_eq(v, "nts")) return;
    if (str_eq(v, "zts")) { ph_ext_zts = 1; return; }
    if (str_eq(v, "both")) { ph_ts_both = 1; return; }
    if (str_eq(v, "false") || str_eq(v, "true"))
        toml_err_key("php.thread_safety", "mc-php: thread_safety is \"nts\", \"zts\" or \"both\" (false is \"nts\", true is \"zts\")");
    toml_err_key("php.thread_safety", "mc-php: thread_safety must be \"nts\", \"zts\" or \"both\"");
}

// The build id php compares is the stated one with its thread-safety word
// made this output's: `API20250925,NTS` becomes `API20250925,TS` for the ZTS
// output (`,NTS,VS17` on Windows becomes `,TS,VS17`) -- which is what lets
// "both" name one build id for two outputs. A build id that names neither
// word is refused rather than guessed at.
uptr ph_ts_word(uptr b, i64 i) {
    // ",NTS" or ",TS" starting at i, ending at a ',' or the end: its length, 0
    if (ld8(b + i) != 44) return 0;
    i64 k = i + 1;
    if (ld8(b + k) == 78) k = k + 1;                          // N
    if (ld8(b + k) != 84 || ld8(b + k + 1) != 83) return 0;   // TS
    k = k + 2;
    if (ld8(b + k) != 0 && ld8(b + k) != 44) return 0;
    return k - i;
}
uptr ph_ts_bid(uptr b) {
    i64 n = cstrlen(b);
    i64 i = 0;
    loop {
        if (i >= n) break;
        i64 w = ph_ts_word(b, i);
        if (w) {
            uptr t = ",NTS";
            if (ph_ext_zts) t = ",TS";
            return p_cat(p_cat(xstrdup(b, i), t, 0, cstrlen(t)), b + i + w, 0, n - i - w);
        }
        i = i + 1;
    }
    toml_err_key("php.build_id", "mc-php: the build id names no thread safety (,NTS or ,TS)");
    return b;
}

void ph_ext_config() {
    ph_ts_config();
    uptr name = toml_get("extension.name");
    if (!name && !ph_ext_has_table()) return;   // the program road
    if (!name) err_at2("mcphp.toml", 1, "mc-php: this extension needs it", "extension.name");
    ph_ext = 1;
    ph_ext_name = name;
    ph_ext_ver = toml_get("extension.version");
    if (!ph_ext_ver) ph_ext_ver = "0.0.0";
    if (toml_get("php.bin")) {
        err_at("mcphp.toml", 1,
               "mc-php: [php].bin is not implemented: state php.api, php.build_id and php.debug, and php.thread_safety unless it is nts (php -i prints all four)");
    }
    ph_ext_bid = toml_get("php.build_id");
    if (!ph_ext_bid) err_at2("mcphp.toml", 1, "mc-php: this extension needs it", "php.build_id");
    ph_ext_api = toml_int("php.api", 0);
    if (!ph_ext_api) err_at2("mcphp.toml", 1, "mc-php: this extension needs it", "php.api");
    ph_ext_bid = ph_ts_bid(ph_ext_bid);
    ph_ext_dbg = ph_ext_bool("php.debug", "php.debug");
}

// A function whose name begins with `_` is MODULE-PRIVATE: it compiles, the
// module's own code calls it, and it is not published -- no handler, no
// function-table row, so `function_exists` is false from php. php has no
// private function of its own; the leading underscore is php's established
// spelling for "internal", it needs no second list to keep in sync, and the
// source stays php that runs unchanged (docs/php-extension.md § What is
// published). Unpublished, its signature is not the boundary's either: it
// may take and return anything the language does.
void ph_ext_export(i64 fi, uptr fl, i64 line) {
    if (!ph_ext) return;
    if (ld64(ph_fext + fi * 8)) return;                             // a C function
    if (ld8(ph_ns_last(ld64(ph_fname + fi * 8))) == 95) return;    // `ns\_name` too
    if (ph_nexp >= PH_MAXEXP) err_at("mcphp.toml", 1, "mc-php: too many exported functions");
    st64(ph_expi + ph_nexp * 8, fi);
    st64(ph_expf + ph_nexp * 8, fl);
    st64(ph_expl + ph_nexp * 8, line);
    ph_nexp = ph_nexp + 1;
}

// ---- what this back end takes ----------------------------------------------
// A declared scalar, and nothing else. Everything a php signature may say
// beyond that is a NAMED refusal with the reason, never a silent lowering:
// `mixed`, `array`, an object, a union, a nullable, a default, a variadic and
// a by-reference parameter each need a zval crossing the boundary, which is
// the next step and not this one.
i64 ph_ext_scalar(i64 t) {
    if (t == PT_INT) return 1;
    if (t == PT_FLOAT) return 1;
    if (t == PT_STRING) return 1;
    if (t == PT_BOOL) return 1;
    return 0;
}

void ph_ext_check(i64 fi, uptr fl, i64 line) {
    uptr name = ld64(ph_fname + fi * 8);
    // php HOISTS a global function, so calling one declared further down the
    // file is ordinary php -- but D4 builds that call against a zval
    // signature and the declaration is then widened to match it. The refusal
    // below would name the declared type, which is not what is wrong, so this
    // one comes first and says what to do.
    if (ld64(ph_fwid + fi * 8))
        ph_todo2(fl, line, "an exported function called before it is declared (move it above its first call)", name);
    if (ld64(ph_fpr + fi * 8))
        ph_todo2(fl, line, "a by-reference parameter in an exported function", name);
    if (ld64(ph_frr + fi * 8))
        ph_todo2(fl, line, "a by-reference return in an exported function", name);
}

// the declaration of slot k of row fi (tables.mc; PH_MAXP is the return)
i64  ph_bd_pt(i64 fi, i64 k)  { return ld64(ph_fdpt + (fi * (PH_MAXP + 1) + k) * 8); }
i64  ph_bd_k(i64 fi, i64 k)   { return ld64(ph_fbk + (fi * (PH_MAXP + 1) + k) * 8); }
uptr ph_bd_n(i64 fi, i64 k)   { uptr n = ld64(ph_fbn + (fi * (PH_MAXP + 1) + k) * 8); if (!n) n = ""; return n; }
i64  ph_bd_nul(i64 fi, i64 k) { return ld64(ph_fbnul + (fi * (PH_MAXP + 1) + k) * 8); }

// is parameter k checked and read the scalar way (phx_chk, one tag)?
i64 ph_ext_plain(i64 fi, i64 k) {
    i64 np = ld64(ph_fnp + fi * 8);
    if (ld64(ph_fvar + fi * 8) && k == np - 1) return 0;
    // a native nullable scalar admits null, which phx_chk's one-tag test does
    // not: it keeps the phx_chk2 guard (null allowed) and the value+flag read
    if (ld64(ph_fopt + (fi * PH_MAXP + k) * 8)) return 0;
    return ph_ext_scalar(ld64(ph_fpt + (fi * PH_MAXP + k) * 8));
}

// is parameter k a plain, unconstrained `mixed` -- declared `mixed`, no default,
// not by-reference, not variadic? Such a parameter has NOTHING for phx_chk2 to
// do: there is no type to reject (mixed accepts every value), and phx_zarg
// already dereferences a reference, maps undef to null, and proxies arrays and
// objects on the way in (lib/php_ext.mc phx_e2r_into). The arity guard has
// already ensured the argument was passed. So the per-parameter phx_chk2 call
// is pure overhead and the handler may omit it. A `?int`/`int`/array/object/
// nullable parameter is NOT this (ph_bd_pt carries the constraint), so it keeps
// its check. Default is keep the check -- this fires only for a bare `mixed`.
i64 ph_ext_anymixed(i64 fi, i64 k) {
    i64 np = ld64(ph_fnp + fi * 8);
    if (ld64(ph_fvar + fi * 8) && k == np - 1) return 0;          // variadic
    if (ld64(ph_fpr + fi * 8) & (1 << k)) return 0;               // by-reference
    if (ld64(ph_fpd + (fi * PH_MAXP + k) * 8)) return 0;          // has a default
    if (ld64(ph_fpt + (fi * PH_MAXP + k) * 8) != PT_MIXED) return 0;
    if (ph_bd_pt(fi, k) != PT_MIXED) return 0;                    // declared mixed, not ?int
    if (ph_bd_k(fi, k) != BK_ANY) return 0;                       // no class/callable bound
    // nul is 1 for `mixed` (it admits null); phx_chk2 with dpt == PT_MIXED and
    // bk == BK_ANY returns 1 for every value, null included, so nul is moot
    return 1;
}

// the count of arguments a call must pass: every parameter before the first
// with a default, the variadic one not counted
i64 ph_ext_nreq(i64 fi) {
    i64 np = ld64(ph_fnp + fi * 8);
    if (ld64(ph_fvar + fi * 8)) np = np - 1;
    i64 k = 0;
    loop {
        if (k >= np) break;
        if (ld64(ph_fpd + (fi * PH_MAXP + k) * 8)) break;
        k = k + 1;
    }
    return k;
}

// ---- the handler -----------------------------------------------------------
uptr ph_ext_hname(uptr name) { return ph_mangle(name, "x_h_"); }

i64 ph_ext_ident(uptr n, i64 ty) {
    i64 v = node_new(N_IDENT, ph_tline, ph_tfile);
    set_nd_name(v, n);
    set_nd_type(v, ty);
    return v;
}

i64 ph_ext_addr(uptr n) {
    i64 a = node_new(N_ADDR, ph_tline, ph_tfile);
    set_nd_name(a, n);
    set_nd_type(a, TY_UPTR);
    return a;
}

i64 ph_ext_block(i64 stmts) {
    i64 b = node_new(N_BLOCK, ph_tline, ph_tfile);
    set_nd_a(b, stmts);
    return b;
}

i64 ph_ext_if(i64 cond, i64 then) {
    i64 f = node_new(N_IF, ph_tline, ph_tfile);
    set_nd_a(f, cond);
    set_nd_b(f, ph_ext_block(then));
    return f;
}

// The handler's fast path, written in place: argument k's zval is at
// ex + EXX_ARG1 (80) + k * ZVX_SIZE (16), its value in the first eight bytes
// and its type in the low byte of the u32 at +8 (lib/php_ext.mc, whose ABI
// gate checks the same offsets); the argument count is the u32 at
// EXX_NUM_ARGS (44). An int and a string are read and checked there; the
// runtime's phx_chk/phx_arity run only when the check fails, to raise php's
// own error. Measured on examples/decimal: the reading and checking calls were
// 5% of the module's time.
i64 ph_ext_argz(i64 k, i64 off) {
    return ph_bin(ph_tok("+", 1), ph_ext_ident("ex", TY_UPTR), ph_int(80 + k * 16 + off), TY_UPTR);
}

i64 ph_ext_or(i64 fast, i64 slow) {
    i64 n = ph_bin(ph_tok("||", 2), fast, slow, TY_U8);
    return n;
}

// the reader that turns argument k into the mc value the php function takes
i64 ph_ext_read(i64 fi, i64 k) {
    i64 pt = ld64(ph_fpt + (fi * PH_MAXP + k) * 8);
    i64 ex = ph_ext_ident("ex", TY_UPTR);
    if (ld64(ph_fvar + fi * 8) && k == ld64(ph_fnp + fi * 8) - 1)
        return ph_c2("phx_rest", ex, ph_int(k), ty_parr);
    if (pt == PT_ARR)    return ph_c2("phx_aarg", ex, ph_int(k), ty_parr);
    if (pt == PT_MIXED)  return ph_c2("phx_zarg", ex, ph_int(k), ty_pzv);
    if (pt == PT_INT)    return ph_quiet("ld64", 1, ph_ext_argz(k, 0), 0, 0, 0, TY_I64);
    if (pt == PT_STRING) return ph_quiet("ld64", 1, ph_ext_argz(k, 0), 0, 0, 0, ty_pstr);
    if (pt == PT_FLOAT)  return ph_c2("phx_f", ex, ph_int(k), ty_f64);
    return ph_c2("phx_b", ex, ph_int(k), TY_U8);              // bool
}

// and the writer that puts the answer into return_value
i64 ph_ext_write(i64 rt, i64 call) {
    i64 rv = ph_ext_ident("rv", TY_UPTR);
    if (rt == PT_VOID)   return ph_stmt_of(call);
    if (rt == PT_INT) {
        // RETURN_LONG in place: the value, then IS_LONG in its type word
        i64 sv = ph_stmt_of(ph_c2("st64", rv, call, TY_VOID));
        set_nd_next(sv, ph_stmt_of(ph_c2("st32", ph_bin(ph_tok("+", 1), ph_ext_ident("rv", TY_UPTR), ph_int(8), TY_UPTR),
                                         ph_int(4), TY_VOID)));
        return ph_ext_block(sv);
    }
    if (rt == PT_FLOAT)  return ph_stmt_of(ph_c2("phx_ret_float", rv, call, TY_VOID));
    if (rt == PT_STRING) return ph_stmt_of(ph_c2("phx_ret_str", rv, call, TY_VOID));
    if (rt == PT_ARR)    return ph_stmt_of(ph_c2("phx_ret_arr", rv, call, TY_VOID));
    if (rt == PT_MIXED)  return ph_stmt_of(ph_c2("phx_ret_zv", rv, call, TY_VOID));
    // RETURN_BOOL in place, like RETURN_LONG above: IZ_FALSE is 2 and IZ_TRUE 3,
    // so the type word is 2 + (answer != 0) (normalised, since php's bool is 0/1
    // but a truthy byte must still map to IZ_TRUE) and the value word is 0. This
    // is exactly phx_ret_bool, without the call.
    i64 tw = ph_bin(ph_tok("+", 1), ph_int(2), ph_bin(ph_tok("!=", 2), call, ph_int(0), TY_U8), TY_I64);
    i64 bt = ph_stmt_of(ph_c2("st32", ph_bin(ph_tok("+", 1), ph_ext_ident("rv", TY_UPTR), ph_int(8), TY_UPTR),
                              tw, TY_VOID));
    set_nd_next(bt, ph_stmt_of(ph_c2("st64", ph_ext_ident("rv", TY_UPTR), ph_int(0), TY_VOID)));
    return ph_ext_block(bt);
}

// ---- the bare road ------------------------------------------------------
// A php function whose body, copied into its handler, calls NOTHING -- mc's
// loads and the return writer only -- needs none of the runtime: no string
// is built, nothing is echoed, nothing can throw. Its handler is then what a
// C extension's is: the count and the tags tested in place, the body, the
// answer written, returned -- and phx_enter/phx_leave run only on the road
// where a check fails and php's own error has to be raised
// (examples/two-extensions: `a_add` is `return $a + $b;`).
i64 ph_ext_lazy;
i64 ph_ext_pure(i64 n) {
    loop {
        if (!n) break;
        if (nd_kind(n) == N_CALL) {
            uptr c = nd_name(n);
            // a call through the function table whose answer is an int
            // needs a context only on its slow side, and takes one there
            // (lib/php_ext.mc's phx_enter_lz): marked LAZY, its last
            // argument, and the road gives the context back at its end
            if (str_eq(c, "phx_fcall_l") || str_eq(c, "phx_fcall_l2")) {
                i64 w = nd_a(n);
                loop { if (!nd_next(w)) break; w = nd_next(w); }
                set_nd_val(w, 1);
                ph_ext_lazy = 1;
            } else if (!phi_intrinsic(c) && !str_eq(c, "phx_ret_int") && !str_eq(c, "phx_ret_bool")
                && !str_eq(c, "phx_ret_float") && !str_eq(c, "phx_leave_lz")) return 0;
        }
        if (!ph_ext_pure(nd_a(n)) || !ph_ext_pure(nd_b(n)) || !ph_ext_pure(nd_c(n)) || !ph_ext_pure(nd_d(n))) return 0;
        n = nd_next(n);
    }
    return 1;
}

// the statement list s without the position announcements
// (ph_dfile/ph_dline), inside the blocks and ifs it holds too
i64 ph_ext_noann(i64 s) {
    i64 h = 0;
    i64 t = 0;
    loop {
        if (!s) break;
        i64 nx = nd_next(s);
        i64 k = nd_kind(s);
        if (k == N_ASSIGN && (str_eq(nd_name(s), "ph_dfile") || str_eq(nd_name(s), "ph_dline"))) { s = nx; continue; }
        if (k == N_BLOCK) set_nd_a(s, ph_ext_noann(nd_a(s)));
        if (k == N_IF) { set_nd_b(s, ph_ext_noann(nd_b(s))); set_nd_c(s, ph_ext_noann(nd_c(s))); }
        if (t) set_nd_next(t, s);
        if (!t) h = s;
        t = s;
        s = nx;
    }
    if (t) set_nd_next(t, 0);
    return h;
}

// A native nullable-scalar argument k, read CALL-FREE after phx_chk2 validated
// it (null / absent allowed, else int). The null flag is 1 when the argument
// was not passed (NUM_ARGS <= k) or is IS_NULL -- the `||` reads the type byte
// only when it was passed. The value is the int word of the engine arg; the
// pointer is ex when absent (a valid in-bounds read whose value the flag then
// discards) and the real slot otherwise, so no out-of-range read happens.
i64 ph_ext_optflag(i64 k) {
    i64 ck = 80 + k * 16;
    i64 na = ph_quiet("ld32", 1, ph_bin(ph_tok("+", 1), ph_ext_ident("ex", TY_UPTR), ph_int(44), TY_UPTR), 0, 0, 0, TY_I64);
    i64 absent = ph_bin(ph_tok("<=", 2), na, ph_int(k), TY_U8);
    i64 ty = ph_quiet("ld8", 1, ph_bin(ph_tok("+", 1), ph_ext_ident("ex", TY_UPTR), ph_int(ck + 8), TY_UPTR), 0, 0, 0, TY_I64);
    i64 isnull = ph_bin(ph_tok("==", 2), ty, ph_int(1), TY_U8);         // IS_NULL
    return ph_bin(ph_tok("||", 2), absent, isnull, TY_U8);
}
i64 ph_ext_optval(i64 k) {
    i64 ck = 80 + k * 16;
    i64 na = ph_quiet("ld32", 1, ph_bin(ph_tok("+", 1), ph_ext_ident("ex", TY_UPTR), ph_int(44), TY_UPTR), 0, 0, 0, TY_I64);
    i64 present = ph_bin(ph_tok(">", 1), na, ph_int(k), TY_U8);
    i64 ptr = ph_bin(ph_tok("+", 1), ph_ext_ident("ex", TY_UPTR), ph_bin(ph_tok("*", 1), ph_int(ck), present, TY_I64), TY_UPTR);
    return ph_quiet("ld64", 1, ptr, 0, 0, 0, TY_I64);
}

// the call to the php function, with every argument already checked. A native
// nullable-scalar parameter contributes TWO arguments, value then flag, in the
// slot order src/decl.mc and src/builtin.mc agree on.
i64 ph_ext_body(i64 fi, uptr name, i64 np, i64 rt) {
    u8 av[200];
    i64 k = 0;
    i64 m = 0;
    loop {
        if (k >= np) break;
        if (ld64(ph_fopt + (fi * PH_MAXP + k) * 8)) {
            st64(av + m * 8, ph_ext_optval(k));  m = m + 1;
            st64(av + m * 8, ph_ext_optflag(k)); m = m + 1;
        } else {
            st64(av + m * 8, ph_ext_read(fi, k));
            m = m + 1;
        }
        k = k + 1;
    }
    return ph_ext_write(rt, ph_calln(ph_mangle(name, "f_"), av, m, ph_mcty(rt)));
}

// 1 iff every occurrence of `v` in `s` is the base of an ld32/ld64 field read
// (v or v + const). A bare occurrence, or v as any other call's argument, or
// an array/object access, returns 0 -- so v's zval is only ever inspected
// (type and value word), never carried out as a value, array-accessed or
// object-accessed. That is exactly what phx_zarg_ro (lib/php_ext.mc) needs to
// borrow the engine zval in place instead of copying it.
i64 ph_borrow_scan(i64 s, uptr v) {
    loop {
        if (!s) break;
        i64 k = nd_kind(s);
        if (k == N_IDENT) {
            if (str_eq(nd_name(s), v)) return 0;
            s = nd_next(s);
            continue;
        }
        // `!v` is mc's pointer-nullness test (node.mc ph_truthy's `!!x`): it
        // reads whether the zval pointer is 0, never the zval's memory, so a
        // borrowed engine zval is as safe here as a copied one. Only `!` -- a
        // `-`/`~` would read the value word.
        if (k == N_UNARY && nd_op(s) == ph_tok("!", 1) && nd_a(s) && nd_kind(nd_a(s)) == N_IDENT && str_eq(nd_name(nd_a(s)), v)) {
            s = nd_next(s);
            continue;
        }
        if (k == N_CALL && (str_eq(nd_name(s), "ld32") || str_eq(nd_name(s), "ld64")) && ph_pin_fieldarg(nd_a(s), v)) {
            // the field-read base (nd_a) is v or v + const: do not descend into
            // it (a bare v there is the allowed read, not an escape)
            if (!ph_borrow_scan(nd_next(nd_a(s)), v)) return 0;
            if (!ph_borrow_scan(nd_b(s), v)) return 0;
            if (!ph_borrow_scan(nd_c(s), v)) return 0;
            if (!ph_borrow_scan(nd_d(s), v)) return 0;
            s = nd_next(s);
            continue;
        }
        if (!ph_borrow_scan(nd_a(s), v)) return 0;
        if (!ph_borrow_scan(nd_b(s), v)) return 0;
        if (!ph_borrow_scan(nd_c(s), v)) return 0;
        if (!ph_borrow_scan(nd_d(s), v)) return 0;
        s = nd_next(s);
    }
    return 1;
}

// Over the handler's final (inlined, pinned) body: a `vn = phx_zarg(ex, k)`
// binding whose parameter is a plain mixed (ph_ext_anymixed) and whose temp vn
// is only field-read (ph_borrow_scan) becomes a borrow, phx_zarg_ro. Every
// other binding keeps the full marshalling phx_zarg. The two body copies (bare
// and slow) carry their own vn, so each is judged on its own.
void ph_borrow_rewrite(i64 s, i64 fi, i64 root) {
    loop {
        if (!s) break;
        if (nd_kind(s) == N_ASSIGN) {
            i64 r = nd_a(s);
            if (r && nd_kind(r) == N_CALL && str_eq(nd_name(r), "phx_zarg")) {
                i64 a0 = nd_a(r);
                i64 a1 = 0;
                if (a0) a1 = nd_next(a0);
                if (a1 && nd_kind(a1) == N_INT) {
                    i64 k = nd_val(a1);
                    if (ph_ext_anymixed(fi, k) && ph_borrow_scan(root, nd_name(s)))
                        set_nd_name(r, "phx_zarg_ro");
                }
            }
        }
        ph_borrow_rewrite(nd_a(s), fi, root);
        ph_borrow_rewrite(nd_b(s), fi, root);
        ph_borrow_rewrite(nd_c(s), fi, root);
        ph_borrow_rewrite(nd_d(s), fi, root);
        s = nd_next(s);
    }
}

void ph_ext_handler(i64 fi, uptr fl, i64 line) {
    uptr name = ld64(ph_fname + fi * 8);
    i64 np = ld64(ph_fnp + fi * 8);
    i64 rt = ld64(ph_fret + fi * 8);

    i64 body = ph_ext_body(fi, name, np, rt);
    i64 k = 0;

    // one guard per parameter, innermost last, then the arity guard around
    // them all: php checks the COUNT before it looks at any argument
    k = np;
    loop {
        if (k == 0) break;
        k = k - 1;
        uptr pn = ld64(ph_fpn + (fi * PH_MAXP + k) * 8);
        if (!pn) pn = "";                      // ph_fpn already holds the bare name
        // a plain `mixed` parameter needs no guard: phx_zarg in the body does
        // the whole conversion and the arity guard already required it
        if (ph_ext_anymixed(fi, k)) continue;
        if (!ph_ext_plain(fi, k)) {
            // declared beyond a scalar, or with a default, or variadic
            u8 dv[64];
            st64(dv, ph_ext_ident("ex", TY_UPTR));
            st64(dv + 8, ph_int(k));
            st64(dv + 16, ph_int(ph_bd_pt(fi, k)));
            st64(dv + 24, ph_int(ph_bd_k(fi, k)));
            st64(dv + 32, ph_raw(ph_bd_n(fi, k), cstrlen(ph_bd_n(fi, k))));
            st64(dv + 40, ph_int(ph_bd_nul(fi, k)));
            st64(dv + 48, ph_raw(name, cstrlen(name)));
            st64(dv + 56, ph_raw(pn, cstrlen(pn)));
            uptr cf = "phx_chk2";
            if (ld64(ph_fvar + fi * 8) && k == np - 1) cf = "phx_chk_rest";
            body = ph_ext_if(ph_calln(cf, dv, 8, TY_I64), body);
            continue;
        }
        u8 cv[48];
        st64(cv, ph_ext_ident("ex", TY_UPTR));
        st64(cv + 8, ph_int(k));
        st64(cv + 16, ph_int(ld64(ph_fpt + (fi * PH_MAXP + k) * 8)));
        st64(cv + 24, ph_raw(name, cstrlen(name)));
        st64(cv + 32, ph_raw(pn, cstrlen(pn)));
        i64 chk = ph_calln("phx_chk", cv, 5, TY_I64);
        i64 pk = ld64(ph_fpt + (fi * PH_MAXP + k) * 8);
        i64 tag = 0;
        if (pk == PT_INT) tag = 4;                    // IS_LONG
        if (pk == PT_STRING) tag = 6;                 // IS_STRING
        if (tag) {
            i64 ty = ph_quiet("ld8", 1, ph_ext_argz(k, 8), 0, 0, 0, TY_I64);
            chk = ph_ext_or(ph_bin(ph_tok("==", 2), ty, ph_int(tag), TY_U8), chk);
        }
        body = ph_ext_if(chk, body);
    }
    i64 nreq = ph_ext_nreq(fi);
    i64 nmax = np;
    if (ld64(ph_fvar + fi * 8)) nmax = 0 - 1;
    if (nreq == nmax) {
        i64 nar = ph_quiet("ld32", 1, ph_bin(ph_tok("+", 1), ph_ext_ident("ex", TY_UPTR), ph_int(44), TY_UPTR),
                           0, 0, 0, TY_I64);
        body = ph_ext_if(ph_ext_or(ph_bin(ph_tok("==", 2), nar, ph_int(np), TY_U8),
                                   ph_c3("phx_arity", ph_ext_ident("ex", TY_UPTR), ph_int(np),
                                         ph_raw(name, cstrlen(name)), TY_I64)), body);
    } else {
        body = ph_ext_if(ph_c4("phx_arity2", ph_ext_ident("ex", TY_UPTR), ph_int(nreq), ph_int(nmax),
                               ph_raw(name, cstrlen(name)), TY_I64), body);
    }

    i64 pre = ph_stmt_of(ph_call("phx_enter", 0, 0, 0, 0, 0, TY_VOID));
    set_nd_next(pre, body);
    i64 post = ph_stmt_of(ph_call("phx_leave", 0, 0, 0, 0, 0, TY_VOID));
    set_nd_next(body, post);

    // the bare road, in front: taken when the count and every tag are what
    // the signature says, and kept only if the body turns out to call
    // nothing once it is copied in (below). A float or bool parameter has no
    // one-tag test (an int widens to a float), so it is not offered one.
    i64 bare = 0;
    if (rt == PT_INT || rt == PT_FLOAT || rt == PT_BOOL || rt == PT_VOID) {
        i64 cond = ph_bin(ph_tok("==", 2), ph_quiet("ld32", 1, ph_bin(ph_tok("+", 1), ph_ext_ident("ex", TY_UPTR),
                          ph_int(44), TY_UPTR), 0, 0, 0, TY_I64), ph_int(np), TY_U8);
        k = 0;
        loop {
            if (k >= np) break;
            i64 pk = ld64(ph_fpt + (fi * PH_MAXP + k) * 8);
            i64 tag = 0;
            if (pk == PT_INT) tag = 4;                    // IS_LONG
            if (pk == PT_STRING) tag = 6;                 // IS_STRING
            if (!ph_ext_plain(fi, k)) tag = 0;
            if (!tag) { cond = 0; break; }
            i64 ty = ph_quiet("ld8", 1, ph_ext_argz(k, 8), 0, 0, 0, TY_I64);
            cond = ph_bin(ph_tok("&&", 2), cond, ph_bin(ph_tok("==", 2), ty, ph_int(tag), TY_U8), TY_U8);
            k = k + 1;
        }
        if (cond) {
            i64 fast = ph_ext_body(fi, name, np, rt);
            set_nd_next(fast, node_new(N_RETURN, line, fl));
            bare = ph_ext_if(cond, fast);
            set_nd_next(bare, pre);
            pre = bare;
        }
    }

    i64 p0 = param_new(TY_UPTR, "ex");
    i64 p1 = param_new(TY_UPTR, "rv");
    set_nd_next(p0, p1);
    i64 f = node_new(N_FUNC, line, fl);
    set_nd_name(f, ph_ext_hname(name));
    set_nd_type(f, TY_VOID);
    set_nd_a(f, p0);
    set_nd_b(f, ph_ext_block(pre));
    // the php function it wraps copied in when it is small and loop-free
    // (src/opt.mc's inliner: `dec_add` is a forwarder), then phx_enter/
    // phx_leave's fast paths written in place (src/opt.mc)
    ph_inl_fn(f, 0);
    // The body copied in here is the php function's PRE-rewrite copy (the
    // inline registry stored it before ph_rc_fn/ph_pin_fn ran on the internal
    // f_ function), so the global/static read-only pin pass has to run again
    // on the handler's own final body -- both the bare and the slow copy,
    // which are still one chain here, before the split below.
    ph_pin_fn(f);
    // a plain mixed parameter whose temp is only ever field-read borrows the
    // engine zval in place (phx_zarg -> phx_zarg_ro) rather than copying it
    ph_borrow_rewrite(nd_a(nd_b(f)), fi, nd_a(nd_b(f)));
    // the copy may have put declarations in front of it: unlinked where it is
    ph_ext_lazy = 0;
    if (bare && ph_ext_pure(nd_b(bare)) && ph_ext_lazy) {
        // the context a lazy call took is given back before the return
        i64 lb = phi_blist(nd_b(bare));
        i64 lp = 0;
        loop { if (!nd_next(lb)) break; lp = lb; lb = nd_next(lb); }
        i64 gv = node_new(N_IDENT, line, fl);
        set_nd_name(gv, "phx_lz");
        set_nd_type(gv, TY_I64);
        i64 give = ph_ext_if(ph_truthy(gv), ph_stmt_of(ph_call("phx_leave_lz", 0, 0, 0, 0, 0, TY_VOID)));
        set_nd_next(give, lb);
        if (lp) set_nd_next(lp, give);
        if (!lp) set_nd_a(nd_b(bare), give);
    }
    // Out of the list, whichever way it goes: the declarations the copy put
    // in front of it stay where they are.
    i64 keep = bare && ph_ext_pure(nd_b(bare));
    i64 dh = 0;
    i64 dt = 0;
    if (bare) {
        i64 hb = nd_b(f);
        i64 sb = nd_a(hb);
        if (sb == bare) set_nd_a(hb, nd_next(bare));
        loop {
            if (!sb || sb == bare) break;
            if (keep && nd_kind(sb) == N_VAR) {
                i64 dc = phi_copy1(sb);
                if (dt) set_nd_next(dt, dc);
                if (!dt) dh = dc;
                dt = dc;
            }
            if (nd_next(sb) == bare) { set_nd_next(sb, nd_next(bare)); break; }
            sb = nd_next(sb);
        }
        set_nd_next(bare, 0);
    }
    if (!keep) {
        phr_fn(f);
        top_add(f);
        return;
    }
    // The position a statement announces is for an exception the source
    // could catch; on the bare road there is no catch (it would be a call),
    // and whatever is raised crosses into php at the road's end, where php
    // says where. The announcements go.
    set_nd_a(nd_b(bare), ph_ext_noann(nd_a(nd_b(bare))));
    // Kept: the handler IS the bare road, and everything else -- the
    // context, the checks that raise php's errors, the body again -- is a
    // second function it tail-calls. A handler that calls nothing else is
    // then a leaf (src/mach.mc's P11): no register of the slow road's saved
    // on the way in, as a C handler's.
    uptr sname = ph_mangle(name, "x_s_");
    set_nd_name(f, sname);
    phr_fn(f);
    top_add(f);
    i64 tc = ph_stmt_of(ph_call(sname, 2, ph_ext_ident("ex", TY_UPTR), ph_ext_ident("rv", TY_UPTR), 0, 0, TY_VOID));
    set_nd_next(bare, tc);
    if (dt) set_nd_next(dt, bare);
    if (!dt) dh = bare;
    i64 q0 = param_new(TY_UPTR, "ex");
    i64 q1 = param_new(TY_UPTR, "rv");
    set_nd_next(q0, q1);
    i64 h = node_new(N_FUNC, line, fl);
    set_nd_name(h, ph_ext_hname(name));
    set_nd_type(h, TY_VOID);
    set_nd_a(h, q0);
    set_nd_b(h, ph_ext_block(dh));
    phr_fn(h);
    top_add(h);
}

// ---- get_module ------------------------------------------------------------
// The one symbol outside every naming rule: php's dl.c fetches `get_module`
// and then `_get_module` and nothing else, so the mc function is called
// exactly that -- mc's Mach-O writer prefixes the underscore and its ELF
// writer does not, which is the pair php tries.
void ph_ext_get_module(uptr fl, i64 line) {
    i64 head = 0;
    i64 tail = 0;
    i64 i = 0;
    loop {
        if (i >= ph_nexp) break;
        i64 fi = ld64(ph_expi + i * 8);
        uptr name = ld64(ph_fname + fi * 8);
        i64 np = ld64(ph_fnp + fi * 8);
        u8 fv[32];
        st64(fv, ph_raw(name, cstrlen(name)));
        st64(fv + 8, ph_ext_addr(ph_ext_hname(name)));
        st64(fv + 16, ph_int(ph_ext_nreq(fi)));
        st64(fv + 24, ph_int(ld64(ph_fret + fi * 8)));
        i64 s = ph_stmt_of(ph_calln("phx_fn", fv, 4, TY_VOID));
        if (tail) set_nd_next(tail, s);
        if (!tail) head = s;
        tail = s;
        i64 rtk = ld64(ph_fret + fi * 8);
        if (rtk == PT_MIXED || rtk == PT_ARR) {
            u8 rv4[32];
            st64(rv4, ph_int(ph_bd_pt(fi, PH_MAXP)));
            st64(rv4 + 8, ph_int(ph_bd_k(fi, PH_MAXP)));
            st64(rv4 + 16, ph_raw(ph_bd_n(fi, PH_MAXP), cstrlen(ph_bd_n(fi, PH_MAXP))));
            st64(rv4 + 24, ph_int(ph_bd_nul(fi, PH_MAXP)));
            i64 r2 = ph_stmt_of(ph_calln("phx_ret2", rv4, 4, TY_VOID));
            set_nd_next(tail, r2);
            tail = r2;
        }
        i64 k = 0;
        loop {
            if (k >= np) break;
            uptr pn = ld64(ph_fpn + (fi * PH_MAXP + k) * 8);
            if (!pn) pn = "";
            i64 a = 0;
            if (ph_ext_plain(fi, k)) {
                a = ph_stmt_of(ph_c2("phx_arg", ph_raw(pn, cstrlen(pn)),
                                     ph_int(ld64(ph_fpt + (fi * PH_MAXP + k) * 8)), TY_VOID));
            } else {
                u8 av6[48];
                st64(av6, ph_raw(pn, cstrlen(pn)));
                st64(av6 + 8, ph_int(ph_bd_pt(fi, k)));
                st64(av6 + 16, ph_int(ph_bd_k(fi, k)));
                st64(av6 + 24, ph_raw(ph_bd_n(fi, k), cstrlen(ph_bd_n(fi, k))));
                st64(av6 + 32, ph_int(ph_bd_nul(fi, k)));
                st64(av6 + 40, ph_int(ld64(ph_fvar + fi * 8) && k == np - 1));
                a = ph_stmt_of(ph_calln("phx_arg2", av6, 6, TY_VOID));
            }
            set_nd_next(tail, a);
            tail = a;
            k = k + 1;
        }
        i = i + 1;
    }
    u8 mv[64];
    st64(mv,      ph_raw(ph_ext_name, cstrlen(ph_ext_name)));
    st64(mv + 8,  ph_raw(ph_ext_ver, cstrlen(ph_ext_ver)));
    st64(mv + 16, ph_int(ph_ext_api));
    st64(mv + 24, ph_raw(ph_ext_bid, cstrlen(ph_ext_bid)));
    st64(mv + 32, ph_int(ph_ext_zts));
    st64(mv + 40, ph_int(ph_ext_dbg));
    st64(mv + 48, ph_ext_addr("mc_php_minit"));
    // no MSHUTDOWN: D7 frees nothing and the scope here has no object, so a
    // module shutdown would run php_shutdown's destructors into a stdout the
    // SAPI is already tearing down. The slot is there when it is earned.
    st64(mv + 56, ph_int(0));
    i64 r = node_new(N_RETURN, line, fl);
    i64 mcall = ph_calln("phx_module", mv, 8, TY_UPTR);
    // a ZTS output ends with lib/php_zts.mc's step; the NTS one is unchanged
    if (ph_ext_zts) mcall = ph_c1("phx_ts_module", mcall, TY_UPTR);
    set_nd_a(r, mcall);
    if (tail) set_nd_next(tail, r);
    if (!tail) head = r;
    i64 f = node_new(N_FUNC, line, fl);
    set_nd_name(f, "get_module");
    set_nd_type(f, TY_UPTR);
    set_nd_a(f, 0);
    set_nd_b(f, ph_ext_block(head));
    top_add(f);
}

// Called by ph_program instead of naming its function `main`: every exported
// function's handler, then get_module.
void ph_ext_emit(uptr fl, i64 line) {
    i64 i = 0;
    loop {
        if (i >= ph_nexp) break;
        i64 fi = ld64(ph_expi + i * 8);
        ph_ext_check(fi, ld64(ph_expf + i * 8), ld64(ph_expl + i * 8));
        ph_ext_handler(fi, ld64(ph_expf + i * 8), ld64(ph_expl + i * 8));
        i = i + 1;
    }
    ph_ext_get_module(fl, line);
}

#embed ph_ext_rt "../lib/php_ext.mc"
#embed ph_zts_rt "../lib/php_zts.mc"

// ---- a published class -------------------------------------------------------
// Called by src/class.mc when a class the extension publishes ends: one handler
// per method -- the engine's object as $this, the compiled body
// (lib/php_ext.mc's phx_mh) -- and, where the class's own entries are filled
// at MINIT, its method table and the call that registers it with the engine
// (phx_cls_end), after its properties and methods are in the runtime's class.
void ph_ext_publish(uptr cname, uptr ceg, i64 flags, uptr fl, i64 line) {
    ph_cfill(ph_stmt_of(ph_call("phx_cls_begin", 0, 0, 0, 0, 0, TY_VOID)));
    i64 i = 0;
    loop {
        if (i >= ph_npm) break;
        uptr mname = ld64(ph_pm_name + i * 8);
        uptr mfn = ld64(ph_pm_fn + i * 8);
        uptr hname = p_cat("x_", mfn, 0, cstrlen(mfn));
        uptr full = p_cat(cname, "::", 0, 2);
        full = p_cat(full, mname, 0, cstrlen(mname));
        u8 hv[32];
        st64(hv, ph_ext_ident("ex", TY_UPTR));
        st64(hv + 8, ph_ext_ident("rv", TY_UPTR));
        st64(hv + 16, ph_ext_addr(mfn));
        st64(hv + 24, ph_raw(full, cstrlen(full)));
        i64 p0 = param_new(TY_UPTR, "ex");
        i64 p1 = param_new(TY_UPTR, "rv");
        set_nd_next(p0, p1);
        i64 h = node_new(N_FUNC, line, fl);
        set_nd_name(h, hname);
        set_nd_type(h, TY_VOID);
        set_nd_a(h, p0);
        set_nd_b(h, ph_ext_block(ph_stmt_of(ph_calln("phx_mh", hv, 4, TY_VOID))));
        top_add(h);
        u8 mv[32];
        st64(mv, ph_raw(mname, cstrlen(mname)));
        st64(mv + 8, ph_ext_addr(hname));
        st64(mv + 16, ph_int(ld64(ph_pm_nreq + i * 8)));
        st64(mv + 24, ph_int(ld64(ph_pm_vis + i * 8)));
        ph_cfill(ph_stmt_of(ph_calln("phx_meth", mv, 4, TY_VOID)));
        i64 k = 0;
        loop {
            if (k >= ld64(ph_pm_np + i * 8)) break;
            uptr pn = ld64(ph_pm_pn + (i * 6 + k) * 8);
            ph_cfill(ph_stmt_of(ph_c1("phx_marg", ph_raw(pn, cstrlen(pn)), TY_VOID)));
            k = k + 1;
        }
        i = i + 1;
    }
    ph_cfill(ph_stmt_of(ph_c3("phx_cls_end", ph_ceref(ceg), ph_raw(cname, cstrlen(cname)), ph_int(flags), TY_VOID)));
}

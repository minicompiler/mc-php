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
//                 phx_ret_int(rv, f_addone(phx_i(ex, 0)));
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
i64  ph_ext_zts;
i64  ph_ext_dbg;

// the top-level php functions, in source order: what get_module registers
#define PH_MAXEXP 256
i64 ph_expi[PH_MAXEXP];
uptr ph_expf[PH_MAXEXP];        // the declaration's own file and line, so a
i64  ph_expl[PH_MAXEXP];        // refusal points at the function and not at <?php
i64 ph_nexp;

// A TOML boolean is TEXT in mc's parser (the table is flat and every value is
// a string), so "true" is what `thread_safety = true` reads as.
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

void ph_ext_config() {
    uptr name = toml_get("extension.name");
    if (!name && !ph_ext_has_table()) return;   // the program road
    if (!name) err_at2("mcphp.toml", 1, "mc-php: this extension needs it", "extension.name");
    ph_ext = 1;
    ph_ext_name = name;
    ph_ext_ver = toml_get("extension.version");
    if (!ph_ext_ver) ph_ext_ver = "0.0.0";
    if (toml_get("php.bin")) {
        err_at("mcphp.toml", 1,
               "mc-php: [php].bin is not implemented: state php.api, php.build_id, php.thread_safety and php.debug (php -i prints all four)");
    }
    ph_ext_bid = toml_get("php.build_id");
    if (!ph_ext_bid) err_at2("mcphp.toml", 1, "mc-php: this extension needs it", "php.build_id");
    ph_ext_api = toml_int("php.api", 0);
    if (!ph_ext_api) err_at2("mcphp.toml", 1, "mc-php: this extension needs it", "php.api");
    ph_ext_zts = ph_ext_bool("php.thread_safety", "php.thread_safety");
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
    if (ld8(ld64(ph_fname + fi * 8)) == 95) return;
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
    if (ld64(ph_fvar + fi * 8))
        ph_todo2(fl, line, "a variadic parameter in an exported function", name);
    if (ld64(ph_fpr + fi * 8))
        ph_todo2(fl, line, "a by-reference parameter in an exported function", name);
    if (ld64(ph_frr + fi * 8))
        ph_todo2(fl, line, "a by-reference return in an exported function", name);
    i64 rt = ld64(ph_fret + fi * 8);
    if (rt != PT_VOID && !ph_ext_scalar(rt))
        ph_todo2(fl, line, "an exported function whose return type is not a declared scalar", name);
    i64 np = ld64(ph_fnp + fi * 8);
    i64 k = 0;
    loop {
        if (k >= np) break;
        if (!ph_ext_scalar(ld64(ph_fpt + (fi * PH_MAXP + k) * 8)))
            ph_todo2(fl, line, "an exported parameter whose type is not a declared scalar", name);
        if (ld64(ph_fpd + (fi * PH_MAXP + k) * 8))
            ph_todo2(fl, line, "a default value in an exported function", name);
        k = k + 1;
    }
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

// the reader that turns argument k into the mc value the php function takes
i64 ph_ext_read(i64 pt, i64 k) {
    i64 ex = ph_ext_ident("ex", TY_UPTR);
    if (pt == PT_INT)    return ph_c2("phx_i", ex, ph_int(k), TY_I64);
    if (pt == PT_FLOAT)  return ph_c2("phx_f", ex, ph_int(k), ty_f64);
    if (pt == PT_STRING) return ph_c2("phx_s", ex, ph_int(k), ty_pstr);
    return ph_c2("phx_b", ex, ph_int(k), TY_U8);              // bool
}

// and the writer that puts the answer into return_value
i64 ph_ext_write(i64 rt, i64 call) {
    i64 rv = ph_ext_ident("rv", TY_UPTR);
    if (rt == PT_VOID)   return ph_stmt_of(call);
    if (rt == PT_INT)    return ph_stmt_of(ph_c2("phx_ret_int", rv, call, TY_VOID));
    if (rt == PT_FLOAT)  return ph_stmt_of(ph_c2("phx_ret_float", rv, call, TY_VOID));
    if (rt == PT_STRING) return ph_stmt_of(ph_c2("phx_ret_str", rv, call, TY_VOID));
    return ph_stmt_of(ph_c2("phx_ret_bool", rv, call, TY_VOID));
}

void ph_ext_handler(i64 fi, uptr fl, i64 line) {
    uptr name = ld64(ph_fname + fi * 8);
    i64 np = ld64(ph_fnp + fi * 8);
    i64 rt = ld64(ph_fret + fi * 8);

    // the call to the php function, with every argument already checked
    u8 av[96];
    i64 k = 0;
    loop {
        if (k >= np) break;
        st64(av + k * 8, ph_ext_read(ld64(ph_fpt + (fi * PH_MAXP + k) * 8), k));
        k = k + 1;
    }
    i64 body = ph_ext_write(rt, ph_calln(ph_mangle(name, "f_"), av, np, ph_mcty(rt)));

    // one guard per parameter, innermost last, then the arity guard around
    // them all: php checks the COUNT before it looks at any argument
    k = np;
    loop {
        if (k == 0) break;
        k = k - 1;
        uptr pn = ld64(ph_fpn + (fi * PH_MAXP + k) * 8);
        if (!pn) pn = "";                      // ph_fpn already holds the bare name
        u8 cv[48];
        st64(cv, ph_ext_ident("ex", TY_UPTR));
        st64(cv + 8, ph_int(k));
        st64(cv + 16, ph_int(ld64(ph_fpt + (fi * PH_MAXP + k) * 8)));
        st64(cv + 24, ph_raw(name, cstrlen(name)));
        st64(cv + 32, ph_raw(pn, cstrlen(pn)));
        body = ph_ext_if(ph_calln("phx_chk", cv, 5, TY_I64), body);
    }
    body = ph_ext_if(ph_c3("phx_arity", ph_ext_ident("ex", TY_UPTR), ph_int(np),
                           ph_raw(name, cstrlen(name)), TY_I64), body);

    i64 pre = ph_stmt_of(ph_call("phx_enter", 0, 0, 0, 0, 0, TY_VOID));
    set_nd_next(pre, body);
    i64 post = ph_stmt_of(ph_call("phx_leave", 0, 0, 0, 0, 0, TY_VOID));
    set_nd_next(body, post);

    i64 p0 = param_new(TY_UPTR, "ex");
    i64 p1 = param_new(TY_UPTR, "rv");
    set_nd_next(p0, p1);
    i64 f = node_new(N_FUNC, line, fl);
    set_nd_name(f, ph_ext_hname(name));
    set_nd_type(f, TY_VOID);
    set_nd_a(f, p0);
    set_nd_b(f, ph_ext_block(pre));
    top_add(f);
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
        st64(fv + 16, ph_int(np));
        st64(fv + 24, ph_int(ld64(ph_fret + fi * 8)));
        i64 s = ph_stmt_of(ph_calln("phx_fn", fv, 4, TY_VOID));
        if (tail) set_nd_next(tail, s);
        if (!tail) head = s;
        tail = s;
        i64 k = 0;
        loop {
            if (k >= np) break;
            uptr pn = ld64(ph_fpn + (fi * PH_MAXP + k) * 8);
            if (!pn) pn = "";
            i64 a = ph_stmt_of(ph_c2("phx_arg", ph_raw(pn, cstrlen(pn)),
                                     ph_int(ld64(ph_fpt + (fi * PH_MAXP + k) * 8)), TY_VOID));
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
    set_nd_a(r, ph_calln("phx_module", mv, 8, TY_UPTR));
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

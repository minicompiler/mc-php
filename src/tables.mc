// tables.mc -- the library table and the function table.
// 
// One row per php library function: its name, the runtime function in
// lib/php_rt.mc that implements it, and its arity. tests/aritycheck.py checks
// the invariant that every row's callee exists with that many parameters.
// The function table is the program's own functions, which php HOISTS -- a
// call may precede the declaration, so the declarations are collected first.

// ---- the library table -----------------------------------------------------
// Every row is one php function whose arguments are zvals and whose result is
// a native value of `ret`. Missing optional arguments are php_znull(), so the
// runtime sees a fixed arity and does its own ZPP.
#define PH_MAXLIB 384

uptr ph_ln[PH_MAXLIB];
uptr ph_lf[PH_MAXLIB];
i64  ph_lmin[PH_MAXLIB];
i64  ph_lmax[PH_MAXLIB];
i64  ph_lret[PH_MAXLIB];
i64  ph_nlib;

void ph_lib(uptr name, uptr fn, i64 mn, i64 mx, i64 ret) {
    if (ph_nlib >= PH_MAXLIB) err_at("php.mc", 1, "mc-php: too many library rows");
    st64(ph_ln + ph_nlib * 8, name);
    st64(ph_lf + ph_nlib * 8, fn);
    st64(ph_lmin + ph_nlib * 8, mn);
    st64(ph_lmax + ph_nlib * 8, mx);
    st64(ph_lret + ph_nlib * 8, ret);
    ph_nlib = ph_nlib + 1;
}

i64 ph_lib_find(uptr n) {
    i64 i = 0;
    loop {
        if (i >= ph_nlib) break;
        if (str_eq(ld64(ph_ln + i * 8), n)) return i;
        i = i + 1;
    }
    return -1;
}

// ---- the function table ----------------------------------------------------
#define PH_MAXFN  256
#define PH_MAXP   12

uptr ph_fname[PH_MAXFN];
i64  ph_fret[PH_MAXFN];
i64  ph_fnp[PH_MAXFN];
i64  ph_fpt[PH_MAXFN * PH_MAXP];
i64  ph_fpd[PH_MAXFN * PH_MAXP];        // the default value node, 0 = none
i64  ph_fpl[PH_MAXFN * PH_MAXP];        // the line the parameter is declared on (0 = not yet)
uptr ph_fpn[PH_MAXFN * PH_MAXP];        // the bare parameter name, for a message
i64  ph_fvar[PH_MAXFN];                 // 1 when the last parameter is ...$rest
i64  ph_fvpc[PH_MAXFN];                 // the DECLARED element type of ...$rest
i64  ph_fpr[PH_MAXFN];                  // bit i: parameter i is `&$x`
// 1 when parameter i is a NULLABLE SCALAR (`?int $s`, with or without a
// default) carried natively: the value in ph_fpt's scalar type plus a u8
// null flag as a second mc parameter (vn_<name>), not a heap zval. Its
// `=== null` reads the flag; a call passes the pair. src/decl.mc builds it,
// src/ext.mc reads it from the engine arg, src/builtin.mc marshals the pair.
i64  ph_fopt[PH_MAXFN * PH_MAXP];
i64  ph_frr[PH_MAXFN];                  // 1 when declared `function &f()`
uptr ph_fdfile[PH_MAXFN];               // where it is declared: the file ...
i64  ph_fdline[PH_MAXFN];               // ... and the line (0 until it is)
// 1 when a CALL came before the declaration, so the declared types were
// widened to mixed to match the signature that call was built against. The
// extension back end reads it: the refusal it would otherwise print names the
// declared type, which is not what is wrong.
i64  ph_fwid[PH_MAXFN];
// What each parameter and the return DECLARED, for the extension boundary
// (src/ext.mc checks an argument against it): the declared primitive (-1 for
// none), types.mc's BK_* kind, the class name for BK_CLASS, and 1 when null
// is allowed. Slot PH_MAXP of a row is the return.
i64  ph_fdpt[PH_MAXFN * (PH_MAXP + 1)];
i64  ph_fbk[PH_MAXFN * (PH_MAXP + 1)];
uptr ph_fbn[PH_MAXFN * (PH_MAXP + 1)];
i64  ph_fbnul[PH_MAXFN * (PH_MAXP + 1)];
i64  ph_nfn;
// the row ph_function() last defined, so ph_program can hand a TOP-LEVEL
// declaration to the extension back end (a `function` nested in another one
// is php's to register when the outer runs, and is not exported)
i64  ph_last_fn;

i64 ph_fn_find0(uptr n) {
    i64 i = 0;
    loop {
        if (i >= ph_nfn) break;
        if (str_eq(ld64(ph_fname + i * 8), n)) return i;
        i = i + 1;
    }
    return -1;
}

// ---- php HOISTS a global function declaration -----------------------------
// `f(); function f(){}` is valid php and so is any call to a function
// declared later in the file, which the table above cannot answer because it
// is filled as the declarations are PARSED (docs/review-backlog.md section 2).
// The source scan already walks every `function NAME (...)` header for the
// by-reference pass; this records the SHAPE of each one -- how many
// parameters, which are `&$x`, whether the last is variadic -- so a call that
// arrives first can be built against it.
//
// A function reached this way is compiled with a ZVAL signature for its
// return, and for every parameter the scan cannot type exactly: a zval holds
// any php value, so the call is correct, and a native `int $n` costs a box.
// The scan types a parameter only where the text leaves no doubt -- a bare
// `int $x`, `float $x`, `string $x` or `bool $x`, with no `?`, union,
// namespace, default, `&` or `...` -- and only for a name that heads ONE
// declaration in the source (a method of the same name would be a second),
// so the parser reads the same type from the same text; src/decl.mc refuses
// a definition that does not agree.
#define PH_MAXDECL 256
uptr ph_dn[PH_MAXDECL];
i64  ph_dnp[PH_MAXDECL];
i64  ph_dpr[PH_MAXDECL];
i64  ph_dvar[PH_MAXDECL];
i64  ph_ndecl;
i64  ph_ffwd[PH_MAXFN];                 // 1: the row came from the scan
i64  ph_dpt[PH_MAXDECL * PH_MAXP];     // each parameter's scanned type (ph_scan_ptype)
i64  ph_ddup[PH_MAXDECL];               // 1: the name heads more than one declaration
uptr ph_dpnm[PH_MAXDECL * PH_MAXP];     // a typed parameter's name, for php's TypeError

i64 ph_decl_find(uptr n) {
    i64 i = 0;
    loop {
        if (i >= ph_ndecl) break;
        if (str_eq(ld64(ph_dn + i * 8), n)) return i;
        i = i + 1;
    }
    return -1;
}

// create the row a forward call needs, from the scan's shape
i64 ph_fwd_reg(uptr n) {
    i64 di = ph_decl_find(n);
    if (di < 0) return -1;
    if (ph_nfn >= PH_MAXFN) return -1;
    i64 fi = ph_nfn;
    ph_nfn = ph_nfn + 1;
    st64(ph_fname + fi * 8, n);
    st64(ph_fret + fi * 8, PT_MIXED);
    st64(ph_fnp + fi * 8, ld64(ph_dnp + di * 8));
    st64(ph_fvar + fi * 8, ld64(ph_dvar + di * 8));
    st64(ph_fvpc + fi * 8, 0);
    st64(ph_fpr + fi * 8, ld64(ph_dpr + di * 8));
    st64(ph_frr + fi * 8, 0);
    st64(ph_ffwd + fi * 8, 1);
    i64 j = 0;
    loop {
        if (j >= ld64(ph_dnp + di * 8)) break;
        // the scanned type where the scan could read one -- a bare `int $x`,
        // `float $x`, `string $x` or `bool $x` of a name declared once -- and
        // a zval otherwise (src/decl.mc holds the definition to it)
        i64 pt = PT_MIXED;
        if (j < PH_MAXP && !ld64(ph_ddup + di * 8)) pt = ld64(ph_dpt + (di * PH_MAXP + j) * 8);
        st64(ph_fpt + (fi * PH_MAXP + j) * 8, pt);
        st64(ph_fpd + (fi * PH_MAXP + j) * 8, 0);
        uptr pnm = "";
        if (pt != PT_MIXED) pnm = ld64(ph_dpnm + (di * PH_MAXP + j) * 8);
        st64(ph_fpn + (fi * PH_MAXP + j) * 8, pnm);
        j = j + 1;
    }
    return fi;
}

i64 ph_fn_find(uptr n) {
    i64 i = ph_fn_find0(n);
    if (i >= 0) return i;
    return ph_fwd_reg(n);
}


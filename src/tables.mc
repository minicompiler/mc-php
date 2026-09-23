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
uptr ph_fpn[PH_MAXFN * PH_MAXP];        // the bare parameter name, for a message
i64  ph_fvar[PH_MAXFN];                 // 1 when the last parameter is ...$rest
i64  ph_fvpc[PH_MAXFN];                 // the DECLARED element type of ...$rest
i64  ph_fpr[PH_MAXFN];                  // bit i: parameter i is `&$x`
i64  ph_frr[PH_MAXFN];                  // 1 when declared `function &f()`
i64  ph_nfn;

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
// A function reached this way is compiled with a ZVAL signature: every
// parameter and the return are PT_MIXED, whatever the declaration says. A
// zval holds any php value, so the call is correct; a native `int $n` on such
// a function costs a box and nothing else, and it costs it only for the
// functions a program really does call before declaring. That is what lets
// the scan record no TYPES at all -- there is no second type table to
// disagree with the parser's.
#define PH_MAXDECL 256
uptr ph_dn[PH_MAXDECL];
i64  ph_dnp[PH_MAXDECL];
i64  ph_dpr[PH_MAXDECL];
i64  ph_dvar[PH_MAXDECL];
i64  ph_ndecl;
i64  ph_ffwd[PH_MAXFN];                 // 1: the row came from the scan

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
        st64(ph_fpt + (fi * PH_MAXP + j) * 8, PT_MIXED);
        st64(ph_fpd + (fi * PH_MAXP + j) * 8, 0);
        st64(ph_fpn + (fi * PH_MAXP + j) * 8, "");
        j = j + 1;
    }
    return fi;
}

i64 ph_fn_find(uptr n) {
    i64 i = ph_fn_find0(n);
    if (i >= 0) return i;
    return ph_fwd_reg(n);
}


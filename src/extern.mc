// extern.mc -- `#[Extern('lib')] function f(int $a, string $s): int {}`: a C
// function, declared in php.
//
// php reads the attribute as inert and the empty body as the function; mc-php
// reads the declaration as a C ABI. The C symbol is the function's own name
// without its namespace. What each type means at the boundary:
//
//   int      a C `int`: passed as 64 bits (the callee reads the low 32), and a
//            returned one is sign-extended from bit 31, since the ABI leaves
//            the bits above it unspecified
//   Ptr      a pointer-sized integer -- a pointer, size_t, long on LP64 --
//            php's int to the source
//   string   a parameter is `const char *` to the string's own bytes (they
//            are NUL-terminated); a return is a NUL-terminated C string,
//            copied into a php string ("" for a null pointer)
//   bool     a parameter only: 0 or 1
//   mixed    a parameter only, decided per call by the VALUE: an int as
//            itself, a string as its bytes, a bool as 0/1, null as 0;
//            anything else is php's TypeError and the C function is not called
//   void     a return only
//
// `variadic: N` says the last N parameters are the C variadic ones
// (curl_easy_setopt's third). The only ABI where that moves an argument is
// Apple's arm64, which passes every variadic argument on the STACK, after the
// eight argument registers: there the fixed ones are padded with zeros to
// eight, so the variadic ones are mc's 9th and on, which is where mc puts them.
//
// Where the symbol comes from: on the extension road, from php's own process
// (the loader resolves it, as for every Zend name the runtime calls); on the
// program road, from the C library the program is linked against, so the
// library named there is `c` or `pthread`. Windows has neither road for a
// library the link does not name, and is refused by name.
//
// A php function stands for it: `f_NAME` with the declared php signature, whose
// body converts the arguments and calls the C symbol -- so a call to it is an
// ordinary call to a declared function, with php's argument checks.

i64  ph_fext[PH_MAXFN];         // 1: the row is a C function, never published

// ---- the attribute --------------------------------------------------------
uptr ph_xa_lib;
i64  ph_xa_var;

uptr ph_xa_skip(uptr q) {
    loop { if (q >= ph_ext_ae) break; i64 c = ld8(q); if (c != 32 && c != 9 && c != 10 && c != 13) break; q = q + 1; }
    return q;
}

void ph_xa_parse(uptr fl, i64 line) {
    ph_xa_lib = 0;
    ph_xa_var = 0;
    uptr q = ph_ext_ab;
    // past `Extern` (or `\Extern`) to its `(`
    loop { if (q >= ph_ext_ae) break; if (ld8(q) == 40) break; q = q + 1; }
    if (q >= ph_ext_ae) err_at(fl, line, "mc-php: #[Extern] needs the library: #[Extern('c')]");
    q = q + 1;
    loop {
        q = ph_xa_skip(q);
        if (q >= ph_ext_ae || ld8(q) == 41) break;
        i64 c = ld8(q);
        if (c == 39 || c == 34) {
            uptr b = q + 1;
            uptr e = b;
            loop { if (e >= ph_ext_ae || ld8(e) == c) break; e = e + 1; }
            ph_xa_lib = xstrdup(b, e - b);
            q = e + 1;
        } else {
            uptr b = q;
            loop { if (q >= ph_ext_ae || !ph_name_byte(ld8(q), 0)) break; q = q + 1; }
            uptr key = xstrdup(b, q - b);
            q = ph_xa_skip(q);
            if (q < ph_ext_ae && ld8(q) == 58) q = ph_xa_skip(q + 1);
            if (!str_eq(key, "variadic"))
                err_at2(fl, line, "mc-php: an #[Extern] argument mc-php does not read", key);
            i64 v = 0;
            loop { if (q >= ph_ext_ae) break; i64 d = ld8(q); if (d < 48 || d > 57) break; v = v * 10 + d - 48; q = q + 1; }
            ph_xa_var = v;
        }
        q = ph_xa_skip(q);
        if (q < ph_ext_ae && ld8(q) == 44) q = q + 1;
    }
    if (!ph_xa_lib) err_at(fl, line, "mc-php: #[Extern] needs the library: #[Extern('c')]");
}

// ---- the types ------------------------------------------------------------
#define XT_INT   1
#define XT_PTR   2
#define XT_STR   3
#define XT_BOOL  4
#define XT_MIXED 5
#define XT_VOID  6

i64 ph_xt(i64 ret, uptr fl, i64 line) {
    uptr w = ph_ns_lower(ph_tname);
    i64 t = 0;
    if (str_eq(w, "int")) t = XT_INT;
    if (str_eq(w, "ptr")) t = XT_PTR;
    if (str_eq(w, "string")) t = XT_STR;
    if (str_eq(w, "bool") && !ret) t = XT_BOOL;
    if (str_eq(w, "mixed") && !ret) t = XT_MIXED;
    if (str_eq(w, "void") && ret) t = XT_VOID;
    if (!t) {
        uptr m = "mc-php: a parameter type an #[Extern] function does not take (int, Ptr, string, bool, mixed)";
        if (ret) m = "mc-php: a return type an #[Extern] function does not have (int, Ptr, string, void)";
        err_at2(fl, line, m, ph_tname);
    }
    ph_next();
    return t;
}

i64 ph_xt_pt(i64 t) {
    if (t == XT_STR) return PT_STRING;
    if (t == XT_BOOL) return PT_BOOL;
    if (t == XT_MIXED) return PT_MIXED;
    if (t == XT_VOID) return PT_VOID;
    return PT_INT;
}

i64 ph_xid(uptr name, i64 ty) {
    i64 n = node_new(N_IDENT, ph_tline, ph_tfile);
    set_nd_name(n, name);
    set_nd_type(n, ty);
    return n;
}

// ---- the declaration ------------------------------------------------------
// Called by ph_function after the name, for row fi, with the attribute read.
i64 ph_extern_fn(uptr name, i64 fi, i64 fwd, uptr fl, i64 line) {
    ph_xa_parse(fl, line);
    ph_ext_ab = 0;
    if (fwd) err_at2(fl, line, "mc-php: an #[Extern] function called before it is declared (move it above its first call)", name);
    uptr os = host_os();
    st64(ph_fext + fi * 8, 1);
    uptr sym = ph_ns_last(name);
    ph_want("(", 1, "expected ( in a php function");
    u8 xt[96];                          // each parameter's XT_*
    u8 pn[96];                          // and its php name, `$x`
    i64 np = 0;
    loop {
        if (ph_at(")", 1)) break;
        if (np >= 12) err_at2(fl, line, "mc-php: an #[Extern] function with more than 12 parameters", name);
        if (ph_tid != T_IDENT) err_at2(fl, line, "mc-php: an #[Extern] parameter needs a type", name);
        i64 t = ph_xt(0, fl, line);
        if (!ph_at("$", 1)) err_at2(fl, line, "mc-php: an #[Extern] parameter the declaration cannot read", name);
        ph_next();
        st64(xt + np * 8, t);
        st64(pn + np * 8, p_cat("$", ph_tname, 0, cstrlen(ph_tname)));
        ph_next();
        np = np + 1;
        if (!ph_accept(",", 1)) break;
    }
    ph_want(")", 1, "expected ) in a php function");
    if (!ph_at(":", 1)) err_at2(fl, line, "mc-php: an #[Extern] function needs its return type", name);
    ph_next();
    i64 rt = ph_xt(1, fl, line);
    ph_want("{", 1, "expected { in a php function");
    if (!ph_at("}", 1)) err_at2(fl, line, "mc-php: an #[Extern] function's body is the library's: leave it empty", name);
    ph_next();
    if (!ph_ext && !str_eq(ph_xa_lib, "c") && !str_eq(ph_xa_lib, "pthread"))
        err_at2(fl, line, "mc-php: an #[Extern] library the program road does not link (only c and pthread; an extension resolves any from php's process)", ph_xa_lib);
    if (str_eq(os, "windows"))
        err_at2(fl, line, "mc-php: an #[Extern] function on Windows: the link names no library for it", name);
    if (ph_xa_var < 0 || ph_xa_var > np) err_at2(fl, line, "mc-php: #[Extern] variadic: is more than its parameters", name);
    // Apple arm64: the fixed arguments padded to the eight registers
    i64 pad = 0;
    if (ph_xa_var && str_eq(os, "macos") && str_eq(host_arch(), "aarch64")) {
        pad = 8 - (np - ph_xa_var);
        if (pad < 0) pad = 0;
    }
    if (np + pad > 12) err_at2(fl, line, "mc-php: an #[Extern] call that needs more than 12 argument words", name);

    // the php row: the declared php signature
    st64(ph_fname + fi * 8, name);
    i64 prt = ph_xt_pt(rt);
    st64(ph_fret + fi * 8, prt);
    st64(ph_fnp + fi * 8, np);
    st64(ph_fvar + fi * 8, 0);
    st64(ph_fvpc + fi * 8, 0);
    st64(ph_fpr + fi * 8, 0);
    st64(ph_frr + fi * 8, 0);

    // the C symbol, unless the runtime (or an earlier #[Extern]) declared it
    i64 xty = TY_I64;
    if (rt == XT_VOID) xty = TY_VOID;
    if (rt == XT_PTR || rt == XT_STR) xty = TY_UPTR;
    if (decl_find(sym) < 0) {
        i64 xh = 0;
        i64 xtl = 0;
        i64 k = 0;
        loop {
            if (k >= np + pad) break;
            i64 xp = param_new(TY_I64, p_cat("a", php_dec(k), 0, cstrlen(php_dec(k))));
            if (xtl) set_nd_next(xtl, xp);
            if (!xtl) xh = xp;
            xtl = xp;
            k = k + 1;
        }
        i64 x = node_new(N_EXTERN, line, fl);
        set_nd_name(x, sym);
        set_nd_type(x, xty);
        set_nd_a(x, xh);
        top_add(x);
    }

    // the php function: its parameters, the arguments converted, the call
    i64 head = 0;
    i64 tail = 0;
    i64 pre = 0;
    i64 pret = 0;
    i64 ah = 0;
    i64 at = 0;
    i64 i = 0;
    loop {
        if (i >= np + pad) break;
        i64 a = 0;
        if (i < np - ph_xa_var || i >= np - ph_xa_var + pad) {
            i64 j = i;
            if (i >= np - ph_xa_var + pad) j = i - pad;
            uptr d = ld64(pn + j * 8);
            i64 t = ld64(xt + j * 8);
            i64 pt = ph_xt_pt(t);
            st64(ph_fpt + (fi * PH_MAXP + j) * 8, pt);
            st64(ph_fpn + (fi * PH_MAXP + j) * 8, d + 1);
            st64(ph_fpd + (fi * PH_MAXP + j) * 8, 0);
            uptr vn = ph_mangle(d, "v_");
            i64 pp = param_new(ph_mcty(pt), vn);
            if (tail) set_nd_next(tail, pp);
            if (!tail) head = pp;
            tail = pp;
            a = ph_xid(vn, ph_mcty(pt));
            if (t == XT_STR) a = ph_bin(ph_tok("+", 1), a, ph_int(24), TY_UPTR);
            if (t == XT_BOOL) a = ph_cast(TY_I64, a);
            if (t == XT_MIXED) {
                // the value decides, into a word held in a local of its own
                uptr wn = ph_mangle(d, "w_");
                i64 v = node_new(N_VAR, line, fl);
                set_nd_name(v, wn);
                set_nd_type(v, TY_I64);
                set_nd_a(v, ph_c1("php_zv_cword", a, TY_I64));
                if (pret) set_nd_next(pret, v);
                if (!pret) pre = v;
                pret = v;
                a = ph_xid(wn, TY_I64);
            }
        } else {
            a = ph_int(0);
        }
        if (at) set_nd_next(at, a);
        if (!at) ah = a;
        at = a;
        i = i + 1;
    }
    i64 call = node_new(N_CALL, line, fl);
    set_nd_name(call, sym);
    set_nd_a(call, ah);
    set_nd_type(call, xty);
    i64 body = node_new(N_BLOCK, line, fl);
    i64 first = 0;
    // a mixed argument that is not a C value: php's TypeError, and no call
    if (pre) {
        i64 zero = 0;
        if (rt == XT_STR) zero = ph_c2("php_str_new", ph_raw("", 0), ph_int(0), ty_pstr);
        if (rt == XT_INT || rt == XT_PTR) zero = ph_int(0);
        i64 r0 = node_new(N_RETURN, line, fl);
        set_nd_a(r0, zero);
        i64 iff = node_new(N_IF, line, fl);
        set_nd_a(iff, ph_truthy(ph_xid("ph_exc", TY_UPTR)));
        set_nd_b(iff, r0);
        set_nd_next(pret, iff);
        first = pre;
        pret = iff;
    }
    i64 last = 0;
    if (rt == XT_VOID) {
        last = ph_stmt_of(call);
        set_nd_next(last, node_new(N_RETURN, line, fl));
    } else {
        i64 v = call;
        if (rt == XT_INT) {
            // C's int: the low 32 bits, sign-extended
            v = ph_bin(ph_tok("<<", 2), v, ph_int(32), TY_I64);
            v = ph_bin(ph_tok(">>", 2), v, ph_int(32), TY_I64);
        }
        if (rt == XT_STR) v = ph_c1("php_str_c", v, ty_pstr);
        last = node_new(N_RETURN, line, fl);
        set_nd_a(last, v);
    }
    if (pret) set_nd_next(pret, last);
    if (!first) first = last;
    set_nd_a(body, first);
    i64 f = node_new(N_FUNC, line, fl);
    set_nd_name(f, ph_mangle(name, "f_"));
    set_nd_type(f, ph_mcty(prt));
    set_nd_a(f, head);
    set_nd_b(f, body);
    return f;
}

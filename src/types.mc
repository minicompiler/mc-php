// types.mc -- php's type words on the surface (D9), and the conversions.
// 
// Every php type word -- array, mixed, iterable, callable, object, never,
// self, static, null, ?T, T|U, A&B and a class name -- lowers to a zval, so
// the surface takes all of them. The conversions between the static types
// are php's own rules, applied at the boundary the compiler knows statically.

// ---- the type words on the surface are PHP's (D9) --------------------------
// D9: the surface is PHP's whole type system and the LOWERING is mc's. Since
// T6 a union lowers to a zval and `mixed` IS one (D4 (c)), so every type that
// is not one of the five native ones answers PT_MIXED rather than a refusal
// -- T5's table refused them because T5 had no zval, and it was never
// re-measured after T6 built one. `?T`, `T|U`, `A&B`, a class name,
// `iterable`, `callable`, `object`, `self`, `static`, `never` and `null` are
// all a zval, which is exactly what D9 says the lowering is.
// What the last type word SAID beyond its lowering, for the extension
// boundary (src/ext.mc), which checks an argument against it: BK_ANY for no
// check (mixed, an untyped parameter, a union), a callable, an object, a class
// by its qualified name; and whether null is allowed. The caller resets it.
#define BK_ANY      0
#define BK_CALLABLE 1
#define BK_OBJECT   2
#define BK_CLASS    3
i64  ph_lt_k;
uptr ph_lt_n;
i64  ph_lt_null;

// ---- a declared type as php checks it (a return type) ----------------------
// While ph_rtr_on, every type word ph_type_word reads is RECORDED: the type
// mask php's zend_type carries (RT_*), its class names in the order written
// (resolved: self, parent, iterable's Traversable), and whether it is a shape
// the runtime does not check (an intersection). lib/php_rt.mc php_ret_check
// takes the same mask.
#define RT_INT      1
#define RT_FLOAT    2
#define RT_STRING   4
#define RT_TRUE     8
#define RT_FALSE    16
#define RT_ARRAY    32
#define RT_NULL     64
#define RT_OBJECT   128
#define RT_MIXED    256
#define RT_VOID     512
#define RT_NEVER    1024
#define RT_CALLABLE 2048
#define RT_STATIC   4096
#define RT_STRICT   8192
// bit 15 (32768) marks a recorded type in ph_fn_rtm: one of class names
// alone has no other bit set
i64  ph_rtr_on;
i64  ph_rtr_m;
uptr ph_rtr_cls;
i64  ph_rtr_bad;
void ph_rtr_begin() { ph_rtr_on = 1; ph_rtr_m = 0; ph_rtr_cls = ""; ph_rtr_bad = 0; }
void ph_rtr_bit(i64 b) { if (ph_rtr_on) ph_rtr_m = ph_rtr_m | b; }
void ph_rtr_class(uptr n) {
    if (!ph_rtr_on || !n) return;
    if (ld8(n) == 92) n = n + 1;
    if (ld8(ph_rtr_cls)) ph_rtr_cls = p_cat(ph_rtr_cls, "|", 0, 1);
    ph_rtr_cls = p_cat(ph_rtr_cls, n, 0, cstrlen(n));
}
// each class's parent, as `extends` named it: what `parent` in a type is
#define PH_MAXCPAR 1024
u8  ph_cpar[16384];
i64 ph_ncpar;
void ph_cpar_add(uptr cls, uptr par) {
    if (ph_ncpar >= PH_MAXCPAR) return;
    st64(ph_cpar + ph_ncpar * 16, cls);
    st64(ph_cpar + ph_ncpar * 16 + 8, par);
    ph_ncpar = ph_ncpar + 1;
}
uptr ph_parent_name(uptr cls) {
    i64 i = 0;
    loop {
        if (i >= ph_ncpar) break;
        if (str_eq(ld64(ph_cpar + i * 16), cls)) return ld64(ph_cpar + i * 16 + 8);
        i = i + 1;
    }
    return 0;
}

// php's own spelling of the recorded type (zend_type_to_string): its class
// names, then static, callable, object, array, string, int, float, bool (or
// false or true), void, never -- and null as `?T` when one type is left, else
// `|null` last
uptr ph_rtr_disp(i64 m, uptr cls) {
    if (m & RT_MIXED) return "mixed";
    uptr s = cls;
    if (m & RT_STATIC) {
        uptr sc = ph_cur_cls;
        if (!sc) sc = "static";
        if (ld8(s)) s = p_cat(s, "|", 0, 1);
        s = p_cat(s, sc, 0, cstrlen(sc));
    }
    u8 w[96];
    st64(w, RT_CALLABLE); st64(w + 8, "callable");
    st64(w + 16, RT_OBJECT); st64(w + 24, "object");
    st64(w + 32, RT_ARRAY); st64(w + 40, "array");
    st64(w + 48, RT_STRING); st64(w + 56, "string");
    st64(w + 64, RT_INT); st64(w + 72, "int");
    st64(w + 80, RT_FLOAT); st64(w + 88, "float");
    i64 i = 0;
    loop {
        if (i >= 6) break;
        if (m & ld64(w + i * 16)) {
            uptr nm = ld64(w + i * 16 + 8);
            if (ld8(s)) s = p_cat(s, "|", 0, 1);
            s = p_cat(s, nm, 0, cstrlen(nm));
        }
        i = i + 1;
    }
    uptr b = 0;
    if ((m & (RT_TRUE | RT_FALSE)) == (RT_TRUE | RT_FALSE)) b = "bool";
    else if (m & RT_FALSE) b = "false";
    else if (m & RT_TRUE) b = "true";
    if (m & RT_VOID) { if (b) { if (ld8(s)) s = p_cat(s, "|", 0, 1); s = p_cat(s, b, 0, cstrlen(b)); } b = "void"; }
    if (m & RT_NEVER) { if (b) { if (ld8(s)) s = p_cat(s, "|", 0, 1); s = p_cat(s, b, 0, cstrlen(b)); } b = "never"; }
    if (b) { if (ld8(s)) s = p_cat(s, "|", 0, 1); s = p_cat(s, b, 0, cstrlen(b)); }
    if (m & RT_NULL) {
        i64 un = 0;
        uptr z = s;
        loop { if (!ld8(z)) break; if (ld8(z) == '|') un = 1; z = z + 1; }
        if (ld8(s) && !un) return p_cat("?", s, 0, cstrlen(s));
        if (ld8(s)) s = p_cat(s, "|", 0, 1);
        s = p_cat(s, "null", 0, 4);
    }
    return s;
}

// read a declared return type: ph_type_word with the recorder on. Answers
// the type's lowering; the recording is left in ph_rtr_*.
i64 ph_type_word(i64 must);
i64 ph_rtype_read() {
    ph_rtr_begin();
    i64 t = ph_type_word(1);
    ph_rtr_on = 0;
    if (ph_rtr_bad) ph_rtr_m = 0;
    return t;
}

// the function state a return is checked against, saved around a nested
// declaration and restored after it
uptr ph_rt_save() {
    uptr r = xalloc(40);
    st64(r, ph_fn_rtm);
    st64(r + 8, ph_fn_rtc);
    st64(r + 16, ph_fn_rtn);
    st64(r + 24, ph_fn_rtq);
    st64(r + 32, ph_fn_meth);
    return r;
}
void ph_rt_restore(uptr r) {
    ph_fn_rtm = ld64(r);
    ph_fn_rtc = ld64(r + 8);
    ph_fn_rtn = ld64(r + 16);
    ph_fn_rtq = ld64(r + 24);
    ph_fn_meth = ld64(r + 32);
}
// the recorded type (or none) becomes the current function's, named q
void ph_rt_set(i64 rec, uptr q) {
    ph_fn_rtm = 0;
    ph_fn_rtc = "";
    ph_fn_rtn = "";
    ph_fn_rtq = q;
    ph_fn_meth = ph_cur_cls != 0;
    if (!rec || ph_rtr_bad || (!ph_rtr_m && !ld8(ph_rtr_cls))) return;
    // a mask of 0 is a type of class names alone: RT_OBJECT's absence says
    // the object must be one of them
    ph_fn_rtm = ph_rtr_m | 32768;
    ph_fn_rtc = ph_rtr_cls;
    ph_fn_rtn = ph_rtr_disp(ph_rtr_m, ph_rtr_cls);
    // `static` is checked as the class it is written in (the called class
    // is that class or a child of it)
    if ((ph_rtr_m & RT_STATIC) && ph_cur_cls) {
        if (ld8(ph_fn_rtc)) ph_fn_rtc = p_cat(ph_fn_rtc, "|", 0, 1);
        ph_fn_rtc = p_cat(ph_fn_rtc, ph_cur_cls, 0, cstrlen(ph_cur_cls));
    }
}

i64 ph_type_tail(i64 t) {
    // `?T` and `T|U` and `A&B` are all one thing here: a zval. An `&` before
    // a `$` is a by-reference parameter and NOT an intersection.
    i64 un = 0;
    loop {
        if (ph_accept("|", 1)) { un = 1; ph_accept("?", 1); ph_type_word(0); continue; }
        if (ph_at("&", 1)) {
            uptr q = p_cp();
            uptr e = p_src_end();
            loop { if (q >= e) break; i64 c = ld8(q); if (c == 32 || c == 9 || c == 10 || c == 13) { q = q + 1; continue; } break; }
            if (q < e) { if (ld8(q) == 36) break; }          // &$x: by reference
            ph_next();
            if (ph_rtr_on) ph_rtr_bad = 1;                   // an intersection
            un = 1;
            ph_accept("?", 1);
            ph_type_word(0);
            continue;
        }
        break;
    }
    if (un) { ph_lt_k = BK_ANY; ph_lt_n = 0; ph_lt_null = 1; return PT_MIXED; }
    return t;
}

// a PARAMETER's declared type, read with the recorder on so the caller also
// gets its RT_* bits (ph_ptm, 32768 = a type was written): whether a `= null`
// default makes it implicitly nullable is a question about the whole type
i64 ph_ptm;
uptr ph_ptc;                // and its class names, "A|B" (ph_rtr_cls)
i64  ph_ptbad;              // 1 when the recorder could not follow it
i64 ph_param_type() {
    i64 so = ph_rtr_on;
    i64 sm = ph_rtr_m;
    uptr sc = ph_rtr_cls;
    i64 sb = ph_rtr_bad;
    ph_rtr_begin();
    i64 t = ph_type_word(0);
    ph_ptm = ph_rtr_m | 32768;
    ph_ptc = ph_rtr_cls;
    ph_ptbad = ph_rtr_bad;
    ph_rtr_on = so;
    ph_rtr_m = sm;
    ph_rtr_cls = sc;
    ph_rtr_bad = sb;
    return t;
}

i64 ph_type_word(i64 must) {
    if (ph_at("(", 1)) {                                    // a DNF type, (A&B)|C
        if (ph_rtr_on) ph_rtr_bad = 1;
        ph_next();
        ph_type_word(1);
        loop { if (ph_at(")", 1)) break; if (ph_tid == T_EOF) break; ph_next(); }
        ph_next();
        ph_type_tail(PT_MIXED);
        return PT_MIXED;
    }
    if (ph_accept("?", 1)) {
        ph_rtr_bit(RT_NULL);
        i64 qt = ph_type_word(1);
        ph_type_tail(PT_MIXED);
        ph_lt_null = 1;
        // `?int`: the scalar, and null allowed -- the boundary checks it as
        // declared, the body sees a zval
        if (qt <= PT_BOOL || qt == PT_ARR) ph_lt_k = 10 + qt;
        return PT_MIXED;
    }
    ph_accept("\\", 1);
    if (ph_is("int"))      { ph_rtr_bit(RT_INT); ph_next(); return ph_type_tail(PT_INT); }
    if (ph_is("float"))    { ph_rtr_bit(RT_FLOAT); ph_next(); return ph_type_tail(PT_FLOAT); }
    if (ph_is("string"))   { ph_rtr_bit(RT_STRING); ph_next(); return ph_type_tail(PT_STRING); }
    if (ph_is("bool"))     { ph_rtr_bit(RT_TRUE | RT_FALSE); ph_next(); return ph_type_tail(PT_BOOL); }
    if (ph_is("void"))     { ph_rtr_bit(RT_VOID); ph_next(); return PT_VOID; }
    if (ph_is("array"))    { ph_rtr_bit(RT_ARRAY); ph_next(); return ph_type_tail(PT_ARR); }
    if (ph_is("mixed") || ph_is("iterable") || ph_is("callable") || ph_is("object")
        || ph_is("null") || ph_is("static") || ph_is("self") || ph_is("parent")
        || ph_is("never") || ph_is("true") || ph_is("false")) {
        if (ph_is("mixed")) ph_rtr_bit(RT_MIXED);
        if (ph_is("iterable")) { ph_rtr_class("Traversable"); ph_rtr_bit(RT_ARRAY); }
        if (ph_is("callable")) ph_rtr_bit(RT_CALLABLE);
        if (ph_is("object")) ph_rtr_bit(RT_OBJECT);
        if (ph_is("null")) ph_rtr_bit(RT_NULL);
        if (ph_is("static")) ph_rtr_bit(RT_STATIC);
        if (ph_is("self")) ph_rtr_class(ph_cur_cls);
        if (ph_is("parent")) {
            uptr pp = 0;
            if (ph_cur_cls) pp = ph_parent_name(ph_cur_cls);
            if (pp) ph_rtr_class(pp);
            if (!pp && ph_rtr_on) ph_rtr_bad = 1;
        }
        if (ph_is("never")) ph_rtr_bit(RT_NEVER);
        if (ph_is("true")) ph_rtr_bit(RT_TRUE);
        if (ph_is("false")) ph_rtr_bit(RT_FALSE);
        if (ph_is("callable")) ph_lt_k = BK_CALLABLE;
        if (ph_is("object")) ph_lt_k = BK_OBJECT;
        if (ph_is("mixed") || ph_is("null")) ph_lt_null = 1;
        ph_next();
        ph_type_tail(PT_MIXED);
        return PT_MIXED;
    }
    // a class name is an object, and an object is a zval
    if (ph_tid == T_IDENT) {
        ph_lt_k = BK_CLASS;
        ph_lt_n = ph_ns_class(ph_tname);
        ph_rtr_class(ph_lt_n);
        ph_next();
        loop { if (!ph_accept("\\", 1)) break; if (ph_tid == T_IDENT) ph_next(); }
        ph_type_tail(PT_MIXED);
        return PT_MIXED;
    }
    if (must) ph_refuse2(ph_tfile, ph_tline, "a php type this compiler does not have", ph_tname, "D9");
    return -1;
}

// A parameter declared with something php checks that the scalar road
// (php_param_coerce: int, float, string, bool, array) does not cover -- a
// nullable, a union, a class, iterable, object, `int $x = null` -- gets
// php_param_tcheck_at: the RT_* bits and class names the return check uses.
// v is the parameter's zval, tm its recorded type (ph_ptm), tc its class
// names (ph_ptc), dnul the `= null` default that makes it implicitly
// nullable. 0 when there is nothing to check: no type, mixed, a type the
// recorder could not follow, or callable (D6: a callable string or array is
// not a value this compiler can test).
i64 ph_ptcheck(i64 v, i64 tm, uptr tc, i64 bad, i64 dnul, uptr ccls, uptr fname, i64 argno, uptr bare, uptr dfile, i64 dline, uptr fl) {
    if (bad) return 0;
    i64 m = tm & 32767;
    if (!m && !ld8(tc)) return 0;
    if (m & (RT_MIXED | RT_CALLABLE | RT_STATIC | RT_VOID | RT_NEVER)) return 0;
    if (dnul) m = m | RT_NULL;
    uptr disp = ph_rtr_disp(m, tc);
    if (ph_strict_bit(fl)) m = m | RT_STRICT;
    u8 a[80];
    st64(a, v);
    st64(a + 8, ph_int(m));
    st64(a + 16, ph_strlit(tc, cstrlen(tc)));
    st64(a + 24, ph_strlit(ccls, cstrlen(ccls)));
    st64(a + 32, ph_strlit(fname, cstrlen(fname)));
    st64(a + 40, ph_int(argno));
    st64(a + 48, ph_strlit(bare, cstrlen(bare)));
    st64(a + 56, ph_strlit(disp, cstrlen(disp)));
    st64(a + 64, ph_strlit(dfile, cstrlen(dfile)));
    st64(a + 72, ph_int(dline));
    return ph_calln("php_param_tcheck_at", a, 10, ty_pzv);
}

// the declaration is exactly one of the scalars php_param_coerce takes (or
// array), with nothing else: the scalar road (pcw) is its check
i64 ph_ptscalar(i64 tm, uptr tc) {
    if (ld8(tc)) return 0;
    i64 m = tm & 32767;
    return m == RT_INT || m == RT_FLOAT || m == RT_STRING || m == (RT_TRUE | RT_FALSE) || m == RT_ARRAY;
}

// ---- type narrowing in a guarded branch ------------------------------------
// Inside `if (is_string($v)) { ... }` (and is_int), $v IS that type on the
// taken branch. mc-php's D4 gives each variable ONE static type, so it does
// not narrow -- a mixed $v stays mixed, and strlen($v)/strspn($v, ...) coerce
// it with php_zv_str, which MIGHT push a pool temporary for a non-string
// argument (it builds a string from an int/float/array). That possibility is
// the whole reason the refcount-drain machinery exists on the return path.
//
// But in the taken branch $v is provably a string, so the coercion is a
// BORROW: php_zv_str for a string returns the embedded zend_string, ld64(z),
// with no allocation and no push. ph_narrow_name/ph_narrow_ty record the one
// variable a guard narrowed, active only on the branch (ph_if saves/restores
// it). The coercions below consult it by the var's own v_NAME: a bare
// occurrence of the narrowed variable lowers to ld64(z) -- the embedded value,
// exactly what php_zv_str/php_zv_long return for that type -- so no call, no
// push. The IDENTIFIER's own lowering is untouched (it stays the zval), so
// every OTHER use of $v in the branch -- echo, assignment, a zval argument --
// is unchanged and correct. Only a coercion of the bare variable narrows.
// Conservative: default is no narrowing; only a bare N_IDENT of the recorded
// name and type is narrowed, and only `is_string`/`is_int` set it.
uptr ph_narrow_name;
i64  ph_narrow_ty;

// Drop the narrowing when the narrowed variable is written -- reassigned,
// mutated, aliased or bound by reference. `vname` is the mc name (v_NAME) of
// the variable being written; after the write its value (hence its type) can
// be anything, so a later bare coercion of it must NOT take the ld64 string/
// int borrow. Called from ph_set (every value write) and ph_set_ref (an
// alias/by-ref binding), so every write form routes through it.
void ph_narrow_clear(uptr vname) {
    if (ph_narrow_name && str_eq(vname, ph_narrow_name)) ph_narrow_name = 0;
}

// c is a type guard `is_string($v)`/`is_int($v)` on a mixed variable iff it is
// the exact shape ph_isof lowers. Two shapes, both `cast(u8, ...)`: the inlined
// tag compare `(ld32(IDENT + 8) & 255) == k` (ph_isof's fast path) and the
// `php_zv_is(IDENT, k)` call it keeps for other tags. k = 6 (string) or 4
// (long). Returns the variable's v_NAME and sets *pty to PT_STRING/PT_INT; 0
// otherwise. A compound condition (&&, ||, anything else) is a different top
// node, so it does not narrow.
uptr ph_guard_ret(i64 kv, i64 vnode, uptr pty) {
    if (!vnode || nd_kind(vnode) != N_IDENT) return 0;
    if (kv == 6) { st64(pty, PT_STRING); return nd_name(vnode); }
    if (kv == 4) { st64(pty, PT_INT); return nd_name(vnode); }
    return 0;
}
uptr ph_guard_of(i64 c, uptr pty) {
    if (!c || nd_kind(c) != N_CAST) return 0;
    i64 inner = nd_a(c);
    if (!inner) return 0;
    // inlined: (ld32(v + 8) & 255) == k
    if (nd_kind(inner) == N_BINARY && nd_op(inner) == ph_tok("==", 2)) {
        i64 lo = nd_a(inner);
        i64 kn = nd_b(inner);
        if (!lo || !kn || nd_kind(kn) != N_INT) return 0;
        if (nd_kind(lo) != N_BINARY || nd_op(lo) != ph_tok("&", 1)) return 0;
        i64 call = nd_a(lo);
        if (!call || nd_kind(call) != N_CALL || !str_eq(nd_name(call), "ld32")) return 0;
        i64 sum = nd_a(call);
        if (!sum || nd_kind(sum) != N_BINARY || nd_op(sum) != ph_tok("+", 1)) return 0;
        return ph_guard_ret(nd_val(kn), nd_a(sum), pty);
    }
    // call: php_zv_is(IDENT, k)
    if (nd_kind(inner) == N_CALL && str_eq(nd_name(inner), "php_zv_is")) {
        i64 v = nd_a(inner);
        i64 k = 0;
        if (v) k = nd_next(v);
        if (!k || nd_kind(k) != N_INT) return 0;
        return ph_guard_ret(nd_val(k), v, pty);
    }
    return 0;
}

// is n a bare occurrence of the narrowed variable, at the narrowed type?
i64 ph_is_narrowed(i64 n, i64 want) {
    if (!ph_narrow_name) return 0;
    if (ph_narrow_ty != want) return 0;
    if (nd_kind(n) != N_IDENT) return 0;
    return str_eq(nd_name(n), ph_narrow_name);
}

// ---- conversions between the static types ----------------------------------
// mixed is a zval: the one type every other one converts into, which is what
// makes an array element, an untyped parameter and `int / int` expressible.
// the null flag of a native nullable-scalar value node, or 0
i64 ph_opt_flagnode(i64 n) {
    if (nd_kind(n) != N_IDENT) return 0;
    uptr ofl = ph_opt_flag_of(nd_name(n));
    if (!ofl) return 0;
    i64 fr = node_new(N_IDENT, ph_tline, ph_tfile);
    set_nd_name(fr, ofl);
    set_nd_type(fr, TY_U8);
    return fr;
}

i64 ph_to_mixed(i64 n, i64 t) {
    // a builtin with no value (var_dump) answers null as a bare 0: a statement
    // drops it, and a use of it gets the zval
    if (t == PT_NULL && nd_kind(n) == N_INT) return ph_call("php_znull", 0, 0, 0, 0, 0, ty_pzv);
    if (t == PT_MIXED || t == PT_NULL) return n;
    // a native nullable scalar (src/decl.mc) made into a zval: null when its
    // flag is set, else the int -- not php_zlong of the value, which would box
    // a null as int(0)
    if (t == PT_INT) { i64 f = ph_opt_flagnode(n); if (f) return ph_c2("php_opt_box", n, f, ty_pzv); }
    if (t == PT_PK)     ph_pk_disagree(ph_tfile, ph_tline, "a packed array used as a value");
    if (t == PT_INT)    return ph_c1("php_zlong", n, ty_pzv);
    if (t == PT_IFALSE) return ph_c1("php_zifalse", n, ty_pzv);
    if (t == PT_FLOAT)  return ph_c1("php_zdouble", n, ty_pzv);
    if (t == PT_STRING) return ph_c1("php_zstr", n, ty_pzv);
    if (t == PT_BOOL)   return ph_c1("php_zbool", n, ty_pzv);
    if (t == PT_ARR)    return ph_c1("php_zarr", n, ty_pzv);
    if (t == PT_OBJ)    return ph_c1("php_zobj", n, ty_pzv);
    ph_refuse2(ph_tfile, ph_tline, "converting to mixed", ph_tyname(t), "D4");
    return 0;
}

// an array subscript: php's own key rules live in the runtime, so a key is
// just a zval and the runtime decides int vs string vs numeric-string.
i64 ph_zkey(i64 n, i64 t) { return ph_to_mixed(n, t); }

i64 ph_to_str(i64 n, i64 t) {
    if (t == PT_STRING) return n;
    // a native nullable scalar cast to string: php's (string)null is "", not
    // the "0" that php_itos of the value-0 would give
    if (t == PT_INT) { i64 f = ph_opt_flagnode(n); if (f) return ph_c2("php_opt_str", n, f, ty_pstr); }
    // a narrowed string: the zval's embedded zend_string, borrowed (ld64(z)),
    // which is exactly what php_zv_str returns for a string -- no call, no push
    if ((t == PT_MIXED || t == PT_NULL) && ph_is_narrowed(n, PT_STRING))
        return ph_quiet("ld64", 1, n, 0, 0, 0, ty_pstr);
    // quiet: an int's digits raise nothing
    if (t == PT_INT)    return ph_quiet("php_itos", 1, n, 0, 0, 0, ty_pstr);
    if (t == PT_IFALSE) return ph_quiet("php_itos", 1, n, 0, 0, 0, ty_pstr);
    if (t == PT_FLOAT)  return ph_c1("php_ftos", n, ty_pstr);
    if (t == PT_BOOL)   return ph_c1("php_btos", n, ty_pstr);
    if (t == PT_MIXED || t == PT_NULL) return ph_c1("php_zv_str", n, ty_pstr);
    if (t == PT_ARR || t == PT_OBJ) return ph_c1("php_zv_str", ph_to_mixed(n, t), ty_pstr);
    ph_refuse2(ph_tfile, ph_tline, "converting to string", ph_tyname(t), "D4");
    return 0;
}

i64 ph_to_int(i64 n, i64 t) {
    if (t == PT_INT || t == PT_IFALSE) return n;
    // a narrowed int: the zval's embedded long (ld64(z)), what php_zv_long
    // returns for a long -- no call (php_zv_long never pushes, but this is the
    // cheaper load and keeps the narrowed shape uniform with ph_to_str)
    if ((t == PT_MIXED || t == PT_NULL) && ph_is_narrowed(n, PT_INT))
        return ph_quiet("ld64", 1, n, 0, 0, 0, TY_I64);
    if (t == PT_BOOL)   return ph_cast(TY_I64, n);
    if (t == PT_FLOAT)  return ph_cast(TY_I64, n);
    if (t == PT_STRING) return ph_c1("php_stoi", n, TY_I64);
    if (t == PT_MIXED || t == PT_NULL) return ph_c1("php_zv_long", n, TY_I64);
    if (t == PT_ARR || t == PT_OBJ) return ph_c1("php_zv_long", ph_to_mixed(n, t), TY_I64);
    ph_refuse2(ph_tfile, ph_tline, "converting to int", ph_tyname(t), "D4");
    return 0;
}

i64 ph_to_float(i64 n, i64 t) {
    if (t == PT_FLOAT) return n;
    if (t == PT_INT || t == PT_IFALSE || t == PT_BOOL) return ph_cast(ty_f64, n);
    if (t == PT_STRING) return ph_c1("php_stof", n, ty_f64);
    if (t == PT_MIXED || t == PT_NULL) return ph_c1("php_zv_double", n, ty_f64);
    ph_refuse2(ph_tfile, ph_tline, "converting to float", ph_tyname(t), "D4");
    return 0;
}

i64 ph_to_bool(i64 n, i64 t) {
    if (t == PT_BOOL) return n;
    if (t == PT_INT || t == PT_IFALSE)
        return ph_cast(TY_U8, ph_bin(ph_tok("!=", 2), n, ph_int(0), TY_U8));
    if (t == PT_FLOAT)  return ph_cast(TY_U8, ph_c1("php_truthy_f", n, TY_I64));
    if (t == PT_STRING) return ph_cast(TY_U8, ph_c1("php_truthy_s", n, TY_I64));
    if (ph_is_arr(t))   return ph_cast(TY_U8, ph_bin(ph_tok("!=", 2), ph_c1("php_count", n, TY_I64), ph_int(0), TY_U8));
    if (t == PT_MIXED)  return ph_cast(TY_U8, ph_c1("php_zv_bool", n, TY_I64));
    if (t == PT_NULL)   return ph_bool(0);
    if (t == PT_OBJ)    return ph_bool(1);
    ph_refuse2(ph_tfile, ph_tline, "converting to bool", ph_tyname(t), "D4");
    return 0;
}


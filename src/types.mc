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

i64 ph_type_word(i64 must) {
    if (ph_at("(", 1)) {                                    // a DNF type, (A&B)|C
        ph_next();
        ph_type_word(1);
        loop { if (ph_at(")", 1)) break; if (ph_tid == T_EOF) break; ph_next(); }
        ph_next();
        ph_type_tail(PT_MIXED);
        return PT_MIXED;
    }
    if (ph_accept("?", 1)) {
        i64 qt = ph_type_word(1);
        ph_type_tail(PT_MIXED);
        ph_lt_null = 1;
        // `?int`: the scalar, and null allowed -- the boundary checks it as
        // declared, the body sees a zval
        if (qt <= PT_BOOL || qt == PT_ARR) ph_lt_k = 10 + qt;
        return PT_MIXED;
    }
    ph_accept("\\", 1);
    if (ph_is("int"))      { ph_next(); return ph_type_tail(PT_INT); }
    if (ph_is("float"))    { ph_next(); return ph_type_tail(PT_FLOAT); }
    if (ph_is("string"))   { ph_next(); return ph_type_tail(PT_STRING); }
    if (ph_is("bool"))     { ph_next(); return ph_type_tail(PT_BOOL); }
    if (ph_is("void"))     { ph_next(); return PT_VOID; }
    if (ph_is("array"))    { ph_next(); return ph_type_tail(PT_ARR); }
    if (ph_is("mixed") || ph_is("iterable") || ph_is("callable") || ph_is("object")
        || ph_is("null") || ph_is("static") || ph_is("self") || ph_is("parent")
        || ph_is("never") || ph_is("true") || ph_is("false")) {
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
        ph_next();
        loop { if (!ph_accept("\\", 1)) break; if (ph_tid == T_IDENT) ph_next(); }
        ph_type_tail(PT_MIXED);
        return PT_MIXED;
    }
    if (must) ph_refuse2(ph_tfile, ph_tline, "a php type this compiler does not have", ph_tname, "D9");
    return -1;
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
i64 ph_to_mixed(i64 n, i64 t) {
    if (t == PT_MIXED || t == PT_NULL) return n;
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


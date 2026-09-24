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
    if (un) return PT_MIXED;
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
    if (ph_accept("?", 1)) { ph_type_word(1); ph_type_tail(PT_MIXED); return PT_MIXED; }
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
        ph_next();
        ph_type_tail(PT_MIXED);
        return PT_MIXED;
    }
    // a class name is an object, and an object is a zval
    if (ph_tid == T_IDENT) {
        ph_next();
        loop { if (!ph_accept("\\", 1)) break; if (ph_tid == T_IDENT) ph_next(); }
        ph_type_tail(PT_MIXED);
        return PT_MIXED;
    }
    if (must) ph_refuse2(ph_tfile, ph_tline, "a php type this compiler does not have", ph_tname, "D9");
    return -1;
}

// ---- conversions between the static types ----------------------------------
// mixed is a zval: the one type every other one converts into, which is what
// makes an array element, an untyped parameter and `int / int` expressible.
i64 ph_to_mixed(i64 n, i64 t) {
    if (t == PT_MIXED || t == PT_NULL) return n;
    if (t == PT_INULL)  return ph_inull_zv(n);
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
    if (t == PT_INULL)  return ph_to_str(ph_inull_zv(n), PT_MIXED);
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
    if (t == PT_INULL)  return ph_to_int(ph_inull_zv(n), PT_MIXED);
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
    if (t == PT_INULL)  return ph_to_float(ph_inull_zv(n), PT_MIXED);
    if (t == PT_INT || t == PT_IFALSE || t == PT_BOOL) return ph_cast(ty_f64, n);
    if (t == PT_STRING) return ph_c1("php_stof", n, ty_f64);
    if (t == PT_MIXED || t == PT_NULL) return ph_c1("php_zv_double", n, ty_f64);
    ph_refuse2(ph_tfile, ph_tline, "converting to float", ph_tyname(t), "D4");
    return 0;
}

i64 ph_to_bool(i64 n, i64 t) {
    if (t == PT_BOOL) return n;
    if (t == PT_INULL)  return ph_to_bool(ph_inull_zv(n), PT_MIXED);
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


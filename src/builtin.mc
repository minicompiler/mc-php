// builtin.mc -- the builtins the COMPILER lowers, not the library.
// 
// A name here becomes instructions rather than a call into lib/php_rt.mc:
// the forms whose argument types the compiler knows statically and can
// answer without going through a zval.

// ---- the builtin functions T5 implements ----------------------------------
// Each is an mc function in php_rt.txt that the compiler calls with the static
// types it already knows, so there is no dispatch at run time. A name that is
// not here is a named compile error, never a silent miss.
// A nested call must not clobber the caller's arguments, so each frame gets
// its own buffer: node at [i*16], php type at [i*16+8].
i64 ph_nargs;

// The parameters of the body being compiled, so that `func_num_args()` and
// `func_get_arg(k)` can be answered where php answers them -- inside the
// callee, from its OWN arguments. Neither needs a run-time type table, which
// is what D6 refuses; `func_get_args` is named by D6 and stays refused
// (docs/plan.md section 3, D6).
// the parameters func_num_args()/func_get_arg() can see. It was 10 while
// PH_MAXP accepts 12, so a 12-parameter function answered 10
// (docs/review-backlog.md section 2).
#define PH_MAXCP 12
// func_get_arg()/func_get_args() marshal the parameters through one runtime
// call, and mc takes at most 12 arguments -- two of which are the index and
// the count -- so THOSE two stop at 10 and say so. func_num_args() is the
// prologue counter and has no such bound.
#define PH_MAXGA 10
uptr ph_cpn[PH_MAXCP];
i64  ph_ncp;
i64  ph_cpzv;                     // 1 when every one of them is a zval
uptr ph_nargs_local;              // the prologue counter, 0 when not emitted

// set by the source scan: no program that never writes the two names pays
// for the counter
i64 ph_uses_nargs;


// inside a `function &f()`: a returned value is the callee's own cell
i64 ph_fn_retref;

// 1 when the expression just parsed is a call to a `function &f()`. The
// caller of `$a = &EXPR` reads it to decide whether php would give the
// alias silently or keep the value and say so.
i64 ph_ref_call;

// Which argument positions of the call about to be read are by-reference
// (`function f(&$x)`). Set by the caller just before ph_read_args, consumed
// once: a nested call inside an argument must not inherit it.
i64 ph_argref;

// A by-reference argument is the caller's own zval, so an UNBOUND name is
// created here rather than read (php does not warn for one) -- which is what
// makes an output parameter work. The name is already a zval: the source scan
// (ph_scan_brf_calls) put every variable in such a call into the ref set.
i64 ph_ref_arg(uptr fl, i64 line) {
    if (!ph_at("$", 1)) return 0;
    if (ph_at("$$", 2)) ph_refuse(fl, line, "a variable variable $$name", "D6");
    ph_next();
    // the `$` is consumed: anything that is not a name has to be refused
    // here and not handed back to the ordinary expression road, which would
    // start one token late
    if (ph_at("$", 1)) ph_refuse(fl, line, "a variable variable $$name", "D6");
    if (ph_tid != T_IDENT) err_at2(fl, line, "mc-php: a php variable needs a name", ph_tname);
    uptr d = p_cat("$", ph_tname, 0, cstrlen(ph_tname));
    ph_next();
    // only a bare $name: `$a[0]` and `$o->p` keep the ordinary road
    if (!ph_at(",", 1) && !ph_at(")", 1)) {
        i64 b = ph_var_ref(d);
        return ph_postfix(b, ph_ety);
    }
    if (ph_var_find(d) < 0) {
        ph_var_bind(d, PT_MIXED);
        ph_set_ref(d);
        ph_pending_stmt(ph_set(ph_mangle(d, "v_"),
                               ph_c1("php_zv_val", ph_call("php_znull", 0, 0, 0, 0, 0, ty_pzv), ty_pzv)));
    }
    if (ph_var_type(d) != PT_MIXED) { ph_ety = ph_var_type(d); return ph_var_ref(d); }
    i64 n = node_new(N_IDENT, line, fl);
    set_nd_name(n, ph_mangle(d, "v_"));
    set_nd_type(n, ty_pzv);
    ph_ety = PT_MIXED;
    return n;
}

// `f(...$args)`: how many parameter slots the spread is expanded into. The
// callee's arity is fixed and the array's length is not, so one slot per
// parameter the callee could take is the answer, and php_unpack_at says
// "not passed" for the ones the array does not reach. MAXPARAMS is 12 and
// two are spent on `this` and the count in a method, so 10 covers every
// callee this compiler can declare.
// As many slots as the WIDEST call ph_read_args is asked for (maxn 16 on
// the library and variadic paths). At 10 a spread carrying 11 to 16 values
// was silently truncated before dispatch -- `sprintf(...$a)` with twelve of
// them dropped two and said nothing.
#define PH_SPREADN 16
i64 ph_had_spread;

uptr ph_read_args(i64 maxn, uptr fl, i64 line, uptr pn) {
    // 24 bytes per argument: the node, its php type, and -- when the
    // argument is a string LITERAL -- its bytes, which is what a
    // compile-time answer like function_exists('f') needs (D6). The node
    // alone cannot say: an argument is hoisted into a temporary whenever it
    // can throw, and ph_strlit's own call sets that flag.
    uptr buf = xalloc(maxn * 24 + 24 + PH_SPREADN * 24);
    i64 mask = ph_argref;
    ph_argref = 0;
    i64 n = 0;
    // THIS call's own answer, and nothing else. It used to be a save of the
    // enclosing value and a restore of it when this call had no spread,
    // which made the flag STICKY: once any call in the unit carried a `...`
    // every later one read 1. Measured -- `u(7, 8, 9)` on a one-parameter
    // function is `the wrong number of arguments for: u` on its own and
    // compiled silently after a `v(...[1,2])` earlier in the file. `mine`
    // is re-established after every argument, because a NESTED call's
    // ph_read_args writes the same global.
    i64 mine = 0;
    ph_had_spread = 0;
    ph_want("(", 1, "expected ( in a php call");
    loop {
        if (ph_at(")", 1)) break;
        if (ph_at("...", 3)) {
            ph_next();
            // The same compute-then-check boundary the ordinary argument
            // below has. Without it a spread expression that THROWS --
            // `f(...boom())` -- left the pending exception uninspected and
            // ran php_unpack_at and then the callee's body, so what the
            // catch saw was whatever those raised instead of the throw.
            i64 spct = ph_can_throw;
            ph_can_throw = 0;
            i64 sp = ph_expr(0);
            i64 spt = ph_ety;
            i64 tmp = ph_temp(ph_to_mixed(sp, spt), ty_pzv, "phu_");
            if (ph_can_throw) ph_pending_stmt(ph_check(ph_tline, ph_tfile));
            ph_can_throw = ph_can_throw | spct;
            i64 nsp = PH_SPREADN;
            if (maxn < nsp) nsp = maxn;
            // what php checks before it enters the callee, and what this
            // compiler's fixed slot count cannot: a non-array operand is a
            // TypeError there and was silently no arguments here, and an
            // array longer than the slots was silently truncated.
            // The COUNT is only mine to complain about when the ceiling is
            // this compiler's buffer. When nsp is the callee's own arity,
            // the values past it are the ones php ignores for a
            // non-variadic callee -- `$m->m(...[1..7])` on a six-parameter
            // method prints php's answer and must keep printing it. 0 asks
            // for the operand check alone.
            i64 scap = 0;
            if (nsp == PH_SPREADN) scap = nsp;
            ph_pending_stmt(ph_stmt_of(ph_c2("php_unpack_check", ph_tref(tmp),
                                             ph_int(scap), TY_VOID)));
            ph_pending_stmt(ph_check(ph_tline, ph_tfile));
            i64 k = 0;
            loop {
                if (k >= nsp) break;
                // The buffer holds maxn + 1 + PH_SPREADN slots and a spread
                // appends up to nsp of them WITHOUT looking at n, so a
                // second or a third `...` wrote past the end and corrupted
                // the compiler instead of reaching the too-many-arguments
                // diagnostic the ordinary path raises below.
                if (n >= maxn + PH_SPREADN)
                    ph_todo(fl, line, "too many arguments for this builtin");
                st64(buf + n * 24, ph_c2("php_unpack_at", ph_tref(tmp), ph_int(k), ty_pzv));
                st64(buf + n * 24 + 8, PT_MIXED);
                st64(buf + n * 24 + 16, 0);
                n = n + 1;
                k = k + 1;
            }
            mine = 1;
            ph_had_spread = mine;
            if (ph_accept(",", 1)) continue;
            break;
        }
        i64 sct = ph_can_throw;
        ph_can_throw = 0;
        i64 a = 0;
        if ((mask >> n) & 1) a = ph_ref_arg(fl, line);
        if (!a) a = ph_expr(0);
        i64 t = ph_ety;
        // a string LITERAL, recognised the way `define` already does it --
        // before the hoist below can replace the node with a temporary
        uptr lb = 0;
        if (t == PT_STRING && nd_kind(a) == N_CALL && str_eq(nd_name(a), "php_str_lit"))
            lb = nd_name(nd_next(nd_a(a)));
        // An argument that can throw is computed into a temporary with the
        // unwinding check BETWEEN computing it and the call, exactly as the
        // echo path already does: php stops at the throwing argument, and
        // `var_dump("65" / "0")` must print nothing before the catch runs
        // (T6 printed NULL first).
        if (ph_can_throw) {
            i64 tmp = ph_temp(a, ph_mcty(t), "phg_");
            ph_pending_stmt(ph_check(ph_tline, ph_tfile));
            a = ph_tref(tmp);
        }
        ph_can_throw = ph_can_throw | sct;
        if (n >= maxn) ph_todo(fl, line, "too many arguments for this builtin");
        st64(buf + n * 24, a);
        st64(buf + n * 24 + 8, t);
        st64(buf + n * 24 + 16, lb);
        n = n + 1;
        ph_had_spread = mine;          // an argument may have been a call
        if (!ph_accept(",", 1)) break;
    }
    ph_want(")", 1, "expected ) in a php call");
    st64(pn, n);
    ph_had_spread = mine;
    return buf;
}

i64 ph_a(uptr av, i64 i) { return ld64(av + i * 24); }
i64 ph_aty(uptr av, i64 i) { return ld64(av + i * 24 + 8); }
// the bytes of argument i when it was written as a string literal, else 0
uptr ph_alit(uptr av, i64 i) { return ld64(av + i * 24 + 16); }

// is_int/is_string/...: a compile-time answer when the type is static (D4),
// a runtime one when the value is a zval
i64 ph_isof(i64 na, i64 t0, i64 a0, i64 want, i64 ztype, uptr fl, i64 line, uptr name) {
    if (na != 1) ph_todo2(fl, line, "the wrong number of arguments for", name);
    ph_ety = PT_BOOL;
    if (t0 == PT_MIXED || t0 == PT_NULL) return ph_cast(TY_U8, ph_c2("php_zv_is", a0, ph_int(ztype), TY_I64));
    if (t0 == want) return ph_bool(1);
    if (want == PT_INT && t0 == PT_IFALSE) return ph_bool(1);
    return ph_bool(0);
}

void ph_need(i64 have, i64 n, uptr name, uptr fl, i64 line) {
    if (have != n) ph_todo2(fl, line, "the wrong number of arguments for", name);
}

// var_dump of one value, by its static type
i64 ph_vd(i64 v, i64 t, uptr fl, i64 line) {
    if (t == PT_INT)    return ph_c1("php_vd_int", v, TY_VOID);
    if (t == PT_IFALSE) return ph_c1("php_vd_ifalse", v, TY_VOID);
    if (t == PT_BOOL)   return ph_c1("php_vd_bool", v, TY_VOID);
    if (t == PT_FLOAT)  return ph_c1("php_vd_float", v, TY_VOID);
    if (t == PT_STRING) return ph_c1("php_vd_str", v, TY_VOID);
    if (t == PT_NULL)   return ph_c2("php_vd_zv", v, ph_int(0), TY_VOID);
    if (t == PT_MIXED)  return ph_c2("php_vd_zv", v, ph_int(0), TY_VOID);
    if (t == PT_ARR)    return ph_c2("php_vd_arr", v, ph_int(0), TY_VOID);
    if (t == PT_OBJ)    return ph_c2("php_vd_obj", v, ph_int(0), TY_VOID);
    ph_todo2(fl, line, "var_dump of", ph_tyname(t));
    return 0;
}

i64 ph_echo_of(i64 v, i64 t, uptr fl, i64 line) {
    if (t == PT_INT || t == PT_IFALSE) return ph_c1("php_echo_int", v, TY_I64);
    if (t == PT_BOOL)   return ph_c1("php_echo_bool", v, TY_I64);
    if (t == PT_FLOAT)  return ph_c1("php_echo_float", v, TY_I64);
    if (t == PT_STRING) return ph_c1("php_echo_str", v, TY_I64);
    if (t == PT_MIXED || t == PT_NULL) return ph_c1("php_echo_zv", v, TY_I64);
    if (t == PT_ARR)    return ph_c1("php_echo_zv", ph_to_mixed(v, t), TY_I64);
    ph_todo2(fl, line, "echo of", ph_tyname(t));
    return 0;
}

// sprintf/printf/vsprintf/vprintf: the FORMAT must be a literal (D1), so the
// compiler walks it and emits ONE php_spf call per conversion. There is no
// run-time format walker in the binary.
i64 ph_sprintf(uptr av, i64 na, uptr fl, i64 line, i64 vec) {
    // `sprintf()` with no arguments read argument 0, which is not there
    // (docs/review-backlog.md section 2). php raises ArgumentCountError at
    // RUN time, so that is what this emits -- a compile error would take
    // the test that catches it out of the grid.
    if (na < 1) {
        ph_pending_stmt(ph_stmt_of(ph_c2("php_argcount", ph_strlit("", 0),
                                         ph_strlit("sprintf", 7), TY_VOID)));
        ph_can_throw = 1;
        return ph_strlit("", 0);
    }
    i64 f = ph_a(av, 0);
    if (nd_kind(f) != N_CALL || !str_eq(nd_name(f), "php_str_lit"))
        ph_refuse(fl, line, "a printf format that is not a literal", "D1");
    i64 raw = nd_next(nd_a(f));                     // the N_STR argument
    uptr b = nd_name(raw);
    i64 n = nd_val(raw);
    // vsprintf: every argument comes out of ONE array, by position
    i64 arr = 0;
    if (vec) {
        if (na < 2) ph_todo2(fl, line, "the wrong number of arguments for", "vsprintf");
        i64 at = ph_aty(av, 1);
        arr = ph_a(av, 1);
        if (at == PT_MIXED) arr = ph_c1("php_zv_arr_r", arr, ty_parr);
        if (at != PT_MIXED && at != PT_ARR) ph_todo(fl, line, "vsprintf without an array");
        arr = ph_temp(arr, ty_parr, "phv_");
    }
    i64 acc = 0;
    i64 seg = 0;
    i64 i = 0;
    i64 ai = 1;
    i64 vi = 0;
    loop {
        if (i >= n) break;
        if (ld8(b + i) != 37) { i = i + 1; continue; }
        if (i > seg) {
            i64 lit = ph_strlit(xstrdup(b + seg, i - seg), i - seg);
            if (acc) acc = ph_c2("php_str_concat", acc, lit, ty_pstr);
            if (!acc) acc = lit;
        }
        i64 p = i + 1;
        if (p < n && ld8(b + p) == 37) {
            i64 pc = ph_strlit("%", 1);
            if (acc) acc = ph_c2("php_str_concat", acc, pc, ty_pstr);
            if (!acc) acc = pc;
            i = p + 1;
            seg = i;
            continue;
        }
        // [argnum$][flags][width][.precision]conv
        i64 argnum = 0;
        i64 q = p;
        i64 num = 0;
        i64 any = 0;
        loop {
            if (q >= n) break;
            i64 c = ld8(b + q);
            if (c < 48 || c > 57) break;
            num = num * 10 + (c - 48);
            any = 1;
            q = q + 1;
        }
        if (any && q < n && ld8(b + q) == 36) { argnum = num; p = q + 1; }
        i64 flags = 0;
        i64 pad = 32;
        loop {
            if (p >= n) break;
            i64 c = ld8(b + p);
            if (c == 45) { flags = flags | 1; p = p + 1; continue; }
            if (c == 43) { flags = flags | 2; p = p + 1; continue; }
            if (c == 32) { flags = flags | 4; p = p + 1; continue; }
            if (c == 48) { flags = flags | 8; pad = 48; p = p + 1; continue; }
            if (c == 39 && p + 1 < n) { pad = ld8(b + p + 1); p = p + 2; continue; }
            break;
        }
        i64 width = 0;
        loop {
            if (p >= n) break;
            i64 c = ld8(b + p);
            if (c < 48 || c > 57) break;
            width = width * 10 + (c - 48);
            p = p + 1;
        }
        i64 prec = -1;
        if (p < n && ld8(b + p) == 46) {
            p = p + 1;
            prec = 0;
            loop {
                if (p >= n) break;
                i64 c = ld8(b + p);
                if (c < 48 || c > 57) break;
                prec = prec * 10 + (c - 48);
                p = p + 1;
            }
        }
        if (p >= n) err_at(fl, line, "mc-php: a printf format that ends in %");
        i64 conv = ld8(b + p);
        p = p + 1;
        i64 val = 0;
        if (vec) {
            i64 idx = vi;
            if (argnum) idx = argnum - 1;
            if (!argnum) vi = vi + 1;
            val = ph_c2("php_arr_iget", ph_tref(arr), ph_int(idx), ty_pzv);
        }
        if (!vec) {
            i64 k = ai;
            if (argnum) k = argnum;
            if (!argnum) ai = ai + 1;
            if (k >= na) ph_todo(fl, line, "a printf format with more conversions than arguments");
            val = ph_to_mixed(ph_a(av, k), ph_aty(av, k));
        }
        u8 six[8];
        st64(six, val);
        i64 piece = ph_call("php_spf", 4, val, ph_int(flags), ph_int(width), ph_int(prec), ty_pstr);
        // php_spf takes six arguments; the last two go on with set_nd_next
        i64 t5 = ph_int(conv);
        i64 t6 = ph_int(pad);
        set_nd_next(ph_int(0), 0);
        i64 lastarg = nd_a(piece);
        loop { if (!nd_next(lastarg)) break; lastarg = nd_next(lastarg); }
        set_nd_next(lastarg, t5);
        set_nd_next(t5, t6);
        if (acc) acc = ph_c2("php_str_concat", acc, piece, ty_pstr);
        if (!acc) acc = piece;
        i = p;
        seg = i;
    }
    if (n > seg) {
        i64 lit2 = ph_strlit(xstrdup(b + seg, n - seg), n - seg);
        if (acc) acc = ph_c2("php_str_concat", acc, lit2, ty_pstr);
        if (!acc) acc = lit2;
    }
    if (!acc) acc = ph_strlit("", 0);
    ph_ety = PT_STRING;
    return acc;
}

// `function_exists('f')` with a LITERAL name folds to a constant (D6): it is
// a compile-time question here, and it answered false for everything
// (docs/review-backlog.md section 2). A name is a function when the program
// declares it (now or later in the file), when the library table has a row
// for it, or when it is one of the names ph_builtin lowers itself.
i64 ph_fn_exists(uptr n) {
    if (ph_fn_find0(n) >= 0) return 1;
    if (ph_decl_find(n) >= 0) return 1;
    if (ph_lib_find(n) >= 0) return 1;
    if (str_eq(n, "abs") || str_eq(n, "array_splice") || str_eq(n, "boolval")
        || str_eq(n, "chop") || str_eq(n, "chr") || str_eq(n, "count") || str_eq(n, "define")
        || str_eq(n, "defined") || str_eq(n, "doubleval") || str_eq(n, "explode")
        || str_eq(n, "floatval") || str_eq(n, "fprintf") || str_eq(n, "func_get_arg")
        || str_eq(n, "func_get_args") || str_eq(n, "func_num_args")
        || str_eq(n, "function_exists") || str_eq(n, "get_called_class") || str_eq(n, "implode")
        || str_eq(n, "intdiv") || str_eq(n, "intval") || str_eq(n, "is_array")
        || str_eq(n, "is_bool") || str_eq(n, "is_double") || str_eq(n, "is_float")
        || str_eq(n, "is_int") || str_eq(n, "is_integer") || str_eq(n, "is_long")
        || str_eq(n, "is_null") || str_eq(n, "is_numeric") || str_eq(n, "is_object")
        || str_eq(n, "is_scalar") || str_eq(n, "is_string") || str_eq(n, "join")
        || str_eq(n, "lcfirst") || str_eq(n, "ltrim") || str_eq(n, "max") || str_eq(n, "min")
        || str_eq(n, "ord") || str_eq(n, "pack") || str_eq(n, "parse_str")
        || str_eq(n, "print_r") || str_eq(n, "printf") || str_eq(n, "rtrim")
        || str_eq(n, "serialize") || str_eq(n, "settype") || str_eq(n, "similar_text")
        || str_eq(n, "sizeof") || str_eq(n, "sprintf") || str_eq(n, "str_contains")
        || str_eq(n, "str_ends_with") || str_eq(n, "str_pad") || str_eq(n, "str_repeat")
        || str_eq(n, "str_replace") || str_eq(n, "str_starts_with") || str_eq(n, "strcasecmp")
        || str_eq(n, "strcmp") || str_eq(n, "strlen") || str_eq(n, "strpos")
        || str_eq(n, "strrev") || str_eq(n, "strtolower") || str_eq(n, "strtoupper")
        || str_eq(n, "strval") || str_eq(n, "substr") || str_eq(n, "trim")
        || str_eq(n, "ucfirst") || str_eq(n, "unpack") || str_eq(n, "unserialize")
        || str_eq(n, "var_dump") || str_eq(n, "var_export") || str_eq(n, "vfprintf")
        || str_eq(n, "vprintf") || str_eq(n, "vsprintf")) return 1;
    return 0;
}

i64 ph_builtin(uptr name, i64 line, uptr fl) {
    // D1 and D6: the named refusals, before anything else
    if (str_eq(name, "eval")) ph_refuse(fl, line, "eval", "D1");
    if (str_eq(name, "create_function")) ph_refuse(fl, line, "create_function", "D1");
    if (str_eq(name, "assert")) ph_refuse(fl, line, "assert with a string argument", "D1");
    if (str_eq(name, "extract") || str_eq(name, "compact")) ph_refuse2(fl, line, "the symbol-table function", name, "D6");
    if (str_eq(name, "get_class_methods") || str_eq(name, "get_object_vars")
        || str_eq(name, "get_class_vars")
        || str_eq(name, "debug_backtrace") || str_eq(name, "call_user_func")
        || str_eq(name, "call_user_func_array") || str_eq(name, "get_defined_vars"))
        ph_refuse2(fl, line, "the reflection function", name, "D6");
    if (cstrlen(name) > 10) {
        if (str_eq(xstrdup(name, 10), "Reflection")) ph_refuse2(fl, line, "the reflection class", name, "D6");
    }

    // the constants, before the ( is required
    if (str_eq(name, "true") || str_eq(name, "TRUE") || str_eq(name, "True"))  { ph_next(); ph_ety = PT_BOOL; return ph_bool(1); }
    if (str_eq(name, "false") || str_eq(name, "FALSE") || str_eq(name, "False")) { ph_next(); ph_ety = PT_BOOL; return ph_bool(0); }
    if (str_eq(name, "null") || str_eq(name, "NULL") || str_eq(name, "Null")) {
        ph_next();
        ph_ety = PT_NULL;
        return ph_call("php_znull", 0, 0, 0, 0, 0, ty_pzv);
    }
    if (str_eq(name, "PHP_INT_MAX"))  { ph_next(); ph_ety = PT_INT; return ph_int(9223372036854775807); }
    if (str_eq(name, "PHP_INT_MIN"))  { ph_next(); ph_ety = PT_INT; return ph_bin(ph_tok("-", 1), ph_int(-9223372036854775807), ph_int(1), TY_I64); }
    if (str_eq(name, "__LINE__")) { i64 l = ph_tline; ph_next(); ph_ety = PT_INT; return ph_int(l); }
    // php's __FILE__ is the RESOLVED path, the same one its diagnostics print
    if (str_eq(name, "__FILE__")) {
        uptr f = ph_disp(ph_absfile(ph_tfile));
        ph_next();
        ph_ety = PT_STRING;
        return ph_strlit(f, cstrlen(f));
    }
    if (str_eq(name, "__DIR__")) {
        uptr f = ph_disp(path_norm(path_join(ph_absfile(ph_tfile), ".")));
        ph_next();
        ph_ety = PT_STRING;
        return ph_strlit(f, cstrlen(f));
    }
    if (str_eq(name, "__FUNCTION__") || str_eq(name, "__METHOD__")) {
        i64 meth = str_eq(name, "__METHOD__");
        ph_next();
        ph_ety = PT_STRING;
        if (!ph_cur_fn) return ph_strlit("", 0);
        if (!meth || !ph_cur_cls) return ph_strlit(ph_cur_fn, cstrlen(ph_cur_fn));
        uptr q = p_cat(ph_cur_cls, "::", 0, 2);
        q = p_cat(q, ph_cur_fn, 0, cstrlen(ph_cur_fn));
        return ph_strlit(q, cstrlen(q));
    }
    i64 pi = ph_pre_find(name);
    if (pi >= 0) {
        ph_next();
        i64 pk = ld64(ph_prek + pi * 8);
        if (pk == 0) { ph_ety = PT_INT; return ph_int(ld64(ph_prev + pi * 8)); }
        if (pk == 1) {
            uptr sv = ld64(ph_pres + pi * 8);
            ph_ety = PT_STRING;
            return ph_strlit(sv, ld64(ph_prev + pi * 8));
        }
        uptr fv = ld64(ph_pres + pi * 8);
        ph_ety = PT_FLOAT;
        return ph_c1("php_stof", ph_strlit(fv, cstrlen(fv)), ty_f64);
    }
    if (str_eq(name, "NAN")) { ph_next(); ph_ety = PT_FLOAT; return ph_c1("php_nan", ph_int(0), ty_f64); }
    if (str_eq(name, "INF")) { ph_next(); ph_ety = PT_FLOAT; return ph_c1("php_inf", ph_int(0), ty_f64); }
    if (str_eq(name, "__CLASS__")) {
        ph_next();
        ph_ety = PT_STRING;
        if (!ph_cur_cls) return ph_strlit("", 0);
        return ph_strlit(ph_cur_cls, cstrlen(ph_cur_cls));
    }
    // a constant this program declared with `const` or define()
    i64 ci = ph_const_find(name);
    if (ci >= 0) {
        ph_next();
        i64 ct = ld64(ph_cty + ci * 8);
        if (ct < 0) { ph_ety = PT_MIXED; return ph_c1("php_const_get", ph_strlit(name, cstrlen(name)), ty_pzv); }
        ph_ety = ct;
        if (ct == PT_STRING) return ph_strlit(ld64(ph_cstr + ci * 8), ld64(ph_cval + ci * 8));
        if (ct == PT_BOOL)   return ph_bool(ld64(ph_cval + ci * 8));
        return ph_int(ld64(ph_cval + ci * 8));
    }

    if (str_eq(name, "array")) {
        ph_next();
        if (!ph_at("(", 1)) ph_todo2(fl, line, "a php constant T5 does not have", name);
        ph_next();
        return ph_array_lit(")");
    }
    // D4 makes these compile-time answers too: a variable HAS a type or it does
    // not exist, and there is no null to be unset.
    if (str_eq(name, "isset") || str_eq(name, "empty")) {
        i64 isempty = str_eq(name, "empty");
        ph_next();
        ph_want("(", 1, "expected ( in a php call");
        i64 acc = 0;
        loop {
            if (ph_at(")", 1)) break;
            if (!ph_at("$", 1)) ph_todo2(fl, line, "isset/empty of", "something that is not a $variable");
            ph_next();
            if (!ph_wordish()) err_at(fl, line, "mc-php: a php variable needs a name");
            uptr d = p_cat("$", ph_tname, 0, cstrlen(ph_tname));
            ph_next();
            i64 one = 0;
            if (ph_var_find(d) < 0) {
                // an undefined variable: isset is false, empty is true, and
                // php does not warn for either
                loop { if (!ph_at("[", 1)) break; ph_next(); ph_expr(0); ph_want("]", 1, "expected ]"); }
                one = ph_bool(0);
                if (isempty) one = ph_bool(1);
            }
            if (ph_var_find(d) >= 0) {
                i64 t = ph_var_type(d);
                i64 v = node_new(N_IDENT, line, fl);
                set_nd_name(v, ph_mangle(d, "v_"));
                set_nd_type(v, ph_mcty(t));
                // T8: the chain is `[k]` and `->p` in any order and to any
                // depth, read QUIETLY -- php warns for nothing isset() or
                // empty() touches, and a key or property that is not there
                // reads as null, which is the answer both of them want.
                loop {
                    if (ph_at("->", 2) || ph_at("?->", 3)) {
                        ph_next();
                        if (ph_at("$", 1) || ph_at("{", 1))
                            ph_refuse(fl, line, "a property name that is not a literal", "D6");
                        if (!ph_wordish()) err_at2(fl, line, "mc-php: a php property needs a name", ph_tname);
                        uptr pn = ph_tname;
                        ph_next();
                        v = ph_c3("php_zv_pget_q", ph_to_mixed(v, t), ph_strlit(pn, cstrlen(pn)), ph_scope(), ty_pzv);
                        t = PT_MIXED;
                        continue;
                    }
                    if (!ph_at("[", 1)) break;
                    if (t == PT_STRING) { ph_next(); v = ph_c2("php_str_off_q", v, ph_to_int(ph_expr(0), ph_ety), ty_pzv); ph_want("]", 1, "expected ]"); t = PT_MIXED; continue; }
                    if (t == PT_MIXED) { v = ph_c1("php_zv_arr_r", v, ty_parr); t = PT_ARR; }
                    if (t != PT_ARR) ph_refuse2(fl, line, "indexing a value that is not an array", ph_tyname(t), "D4");
                    ph_next();
                    i64 k = ph_zkey(ph_expr(0), ph_ety);
                    ph_want("]", 1, "expected ] in isset/empty");
                    v = ph_c2("php_arr_zget", v, k, ty_pzv);
                    t = PT_MIXED;
                }
                if (!isempty) {
                    if (t == PT_INT)   one = ph_cast(TY_U8, ph_bin(ph_tok("!=", 2), v, ph_int(0), TY_U8));
                    if (t == PT_MIXED) one = ph_cast(TY_U8, ph_c1("php_zv_isset", v, TY_I64));
                    if (t != PT_INT && t != PT_MIXED) one = ph_bool(1);
                }
                if (isempty) {
                    i64 b = ph_to_bool(v, t);
                    i64 nn = node_new(N_UNARY, line, fl);
                    set_nd_op(nn, ph_tok("!", 1));
                    set_nd_a(nn, b);
                    set_nd_type(nn, TY_U8);
                    one = nn;
                }
            }
            if (!acc) acc = one;
            if (acc != one) acc = ph_bin(ph_tok("&&", 2), acc, one, TY_U8);
            if (!ph_accept(",", 1)) break;
        }
        ph_want(")", 1, "expected ) in a php call");
        ph_ety = PT_BOOL;
        if (!acc) acc = ph_bool(1);
        return acc;
    }
    ph_next();
    if (ph_at("::", 2)) {
        ph_next();
        i64 ce = ph_ce_of(name, fl, line);
        if (ph_is("class")) {
            ph_next();
            ph_ety = PT_STRING;
            if (str_eq(name, "self") || str_eq(name, "static") || str_eq(name, "parent"))
                return ph_c1("php_ce_name", ce, ty_pstr);
            return ph_strlit(name, cstrlen(name));
        }
        if (ph_at("$", 1)) {
            ph_next();
            uptr sp = ph_tname;
            ph_next();
            i64 slot = ph_c3("php_ce_sslot_s", ce, ph_strlit(sp, cstrlen(sp)), ph_scope(), ty_pzv);
            ph_ety = PT_MIXED;
            // a static property is a zval SLOT, so a write is a store into it
            // and the whole thing stays an expression
            i64 op = 0;
            if (ph_at(".=", 2))  op = ph_tok(".", 1);
            if (ph_at("+=", 2))  op = ph_tok("+", 1);
            if (ph_at("-=", 2))  op = ph_tok("-", 1);
            if (ph_at("*=", 2))  op = ph_tok("*", 1);
            if (ph_at("/=", 2))  op = ph_tok("/", 1);
            if (ph_at("%=", 2))  op = ph_tok("%", 1);
            if (ph_at("++", 2) || ph_at("--", 2)) {
                uptr f = "php_zv_inc";
                if (ph_at("--", 2)) f = "php_zv_dec";
                ph_next();
                i64 t2 = ph_temp(slot, ty_pzv, "phs_");
                return ph_c2("php_zv_store", ph_tref(t2), ph_c1(f, ph_tref(t2), ty_pzv), ty_pzv);
            }
            if (op) {
                ph_next();
                i64 t3 = ph_temp(slot, ty_pzv, "phs_");
                i64 r = ph_expr(0);
                i64 rt = ph_ety;
                i64 v = 0;
                if (op == ph_tok(".", 1)) v = ph_c2("php_zv_concat", ph_tref(t3), ph_to_mixed(r, rt), ty_pzv);
                if (op != ph_tok(".", 1)) v = ph_arith_zv(op, ph_tref(t3), PT_MIXED, r, rt);
                ph_ety = PT_MIXED;
                return ph_c2("php_zv_store", ph_tref(t3), v, ty_pzv);
            }
            if (ph_at("=", 1)) {
                ph_next();
                i64 r2 = ph_expr(0);
                i64 v2 = ph_to_mixed(ph_own(r2, ph_ety), ph_ety);
                ph_ety = PT_MIXED;
                return ph_c2("php_zv_store", slot, v2, ty_pzv);
            }
            return slot;
        }
        if (ph_tid != T_IDENT) err_at2(fl, line, "mc-php: a php class member was expected", ph_tname);
        uptr mn = ph_tname;
        ph_next();
        if (ph_at("(", 1)) return ph_scall_node(ce, mn, fl, line);
        ph_ety = PT_MIXED;
        return ph_c2("php_ce_getconst", ce, ph_strlit(mn, cstrlen(mn)), ty_pzv);
    }
    if (!ph_at("(", 1)) {
        // php looks an unknown bare name up in the constant table at RUN time
        // and raises Error if it is not there
        ph_ety = PT_MIXED;
        return ph_c1("php_const_get", ph_strlit(name, cstrlen(name)), ty_pzv);
    }

    // pack(format, ...$args): variadic, so the arguments go into an array the
    // runtime walks -- the same shape a `...$rest` parameter is given
    if (str_eq(name, "pack")) {
        u8 pnp[8];
        uptr avp = ph_read_args(16, fl, line, pnp);
        i64 nap = ld64(pnp);
        if (nap < 1) ph_todo2(fl, line, "the wrong number of arguments for", "pack");
        ph_nonce = ph_nonce + 1;
        uptr rn = p_cat("phpk_", php_dec(ph_nonce), 0, cstrlen(php_dec(ph_nonce)));
        ph_local(rn, ty_parr);
        i64 mk = ph_set(rn, ph_c1("php_arr_new", ph_int(8), ty_parr));
        i64 mt = mk;
        i64 jp = 1;
        loop {
            if (jp >= nap) break;
            i64 ar = node_new(N_IDENT, line, fl);
            set_nd_name(ar, rn);
            set_nd_type(ar, ty_parr);
            i64 ps = ph_stmt_of(ph_c2("php_arr_push", ar, ph_to_mixed(ph_a(avp, jp), ph_aty(avp, jp)), TY_VOID));
            set_nd_next(mt, ps);
            mt = ps;
            jp = jp + 1;
        }
        ph_pending_stmt(mk);
        i64 ar2 = node_new(N_IDENT, line, fl);
        set_nd_name(ar2, rn);
        set_nd_type(ar2, ty_parr);
        ph_ety = PT_MIXED;
        return ph_c2("php_f_pack", ph_to_mixed(ph_a(avp, 0), ph_aty(avp, 0)), ph_c1("php_zarr", ar2, ty_pzv), ty_pzv);
    }
    // func_num_args() / func_get_arg(k): answered from the callee's OWN
    // parameters, which need no run-time table -- D6 refuses `func_get_args`
    // by name and that one stays refused (docs/plan.md section 3, D6).
    if (str_eq(name, "func_num_args") || str_eq(name, "func_get_arg")
        || str_eq(name, "func_get_args")) {
        u8 pnf[8];
        uptr avf = ph_read_args(4, fl, line, pnf);
        i64 naf = ld64(pnf);
        if (!ph_nargs_local)
            ph_todo2(fl, line, "outside a php function with zval parameters", name);
        i64 cnt = node_new(N_IDENT, line, fl);
        set_nd_name(cnt, ph_nargs_local);
        set_nd_type(cnt, TY_I64);
        if (str_eq(name, "func_num_args")) {
            if (naf) ph_todo2(fl, line, "the wrong number of arguments for", name);
            ph_ety = PT_INT;
            return cnt;
        }
        // func_get_args(): the same parameters, collected. It needs no
        // run-time table either, which is why D6 was corrected to let it in.
        i64 isall = str_eq(name, "func_get_args");
        if (isall) {
            if (naf) ph_todo2(fl, line, "the wrong number of arguments for", name);
        } else {
            if (naf != 1) ph_todo2(fl, line, "the wrong number of arguments for", name);
        }
        // the k-th parameter, chosen at run time out of the ones it has
        u8 allf[128];
        i64 base = 8;
        if (isall) {
            st64(allf, cnt);
        } else {
            st64(allf, ph_to_int(ph_a(avf, 0), ph_aty(avf, 0)));
            st64(allf + 8, cnt);
            base = 16;
        }
        if (ph_ncp > PH_MAXGA) ph_todo2(fl, line, "more than 10 parameters for", name);
        i64 kf = 0;
        loop {
            if (kf >= PH_MAXGA) break;
            i64 pv = ph_int(0);
            if (kf < ph_ncp) {
                pv = node_new(N_IDENT, line, fl);
                set_nd_name(pv, ph_mangle(ld64(ph_cpn + kf * 8), "v_"));
                set_nd_type(pv, ty_pzv);
            }
            st64(allf + base + kf * 8, pv);
            kf = kf + 1;
        }
        ph_ety = PT_MIXED;
        if (isall) return ph_calln("php_args_all", allf, 11, ty_pzv);
        ph_can_throw = 1;
        return ph_calln("php_arg_at", allf, 12, ty_pzv);
    }
    // fprintf($h, $fmt, ...) / vfprintf($h, $fmt, $args): the same formatter
    // with a stream in front of it
    if (str_eq(name, "fprintf") || str_eq(name, "vfprintf")) {
        i64 fvec = str_eq(name, "vfprintf");
        u8 pnf2[8];
        uptr avf2 = ph_read_args(16, fl, line, pnf2);
        i64 naf2 = ld64(pnf2);
        if (naf2 < 2) ph_todo2(fl, line, "the wrong number of arguments for", name);
        i64 txt = ph_sprintf(avf2 + 24, naf2 - 1, fl, line, fvec);
        ph_ety = PT_MIXED;
        return ph_c2("php_f_fput", ph_to_mixed(ph_a(avf2, 0), ph_aty(avf2, 0)), txt, ty_pzv);
    }
    if (str_eq(name, "sprintf") || str_eq(name, "printf")
        || str_eq(name, "vsprintf") || str_eq(name, "vprintf")) {
        i64 vec = 0;
        if (str_eq(name, "vsprintf") || str_eq(name, "vprintf")) vec = 1;
        u8 pn0[8];
        uptr av0 = ph_read_args(16, fl, line, pn0);
        i64 s = ph_sprintf(av0, ld64(pn0), fl, line, vec);
        if (str_eq(name, "sprintf") || str_eq(name, "vsprintf")) { ph_ety = PT_STRING; return s; }
        i64 e = ph_c1("php_echo_str", s, TY_I64);
        ph_ety = PT_INT;
        return ph_c2("php_seq_i", e, ph_int(0), TY_I64);
    }

    u8 pnb[8];
    i64 fi0 = ph_fn_find(name);
    if (fi0 >= 0) ph_argref = ld64(ph_fpr + fi0 * 8);
    // a BUILTIN with a by-reference parameter. The library table carries a
    // row's arity and its return type, not which of its arguments php
    // declares `&$x`, so the handful that have one are named here. Every
    // other by-reference builtin in this runtime (sort, array_push, end, ...)
    // takes an ARRAY, and an array handle is already a pointer.
    if (fi0 < 0) {
        if (str_eq(name, "settype")) ph_argref = 1;
        if (str_eq(name, "parse_str")) ph_argref = 2;
        if (str_eq(name, "array_splice")) ph_argref = 1;
        if (str_eq(name, "similar_text")) ph_argref = 4;
        if (str_eq(name, "str_replace")) ph_argref = 8;
        // sscanf($s, $f, &$a, &$b, ...): every argument from the third on.
        // It was missing, so the outputs were READ and the parsed values
        // had nowhere to go (docs/review-backlog.md round ten).
        if (str_eq(name, "sscanf")) ph_argref = 252;
    }
    uptr av = ph_read_args(16, fl, line, pnb);
    i64 na = ld64(pnb);
    i64 a0 = 0;
    i64 t0 = -1;
    if (na >= 1) { a0 = ph_a(av, 0); t0 = ph_aty(av, 0); }

    // array_push($a, v...) is variadic and a value may legitimately BE null,
    // which the three-slot library row could not tell from "not passed"
    // (docs/review-backlog.md section 2). One push per argument, and the
    // answer is the new count.
    if (str_eq(name, "array_push")) {
        if (na < 1) ph_todo2(fl, line, "the wrong number of arguments for", name);
        i64 arrp = a0;
        if (t0 == PT_MIXED) arrp = ph_c1("php_zv_arr_w", arrp, ty_parr);
        if (t0 != PT_MIXED && !ph_is_arr(t0)) ph_todo(fl, line, "array_push() on something that is not an array");
        i64 ap = ph_temp(arrp, ty_parr, "phap_");
        i64 i2 = 1;
        loop {
            if (i2 >= na) break;
            ph_pending_stmt(ph_stmt_of(ph_c2("php_arr_push", ph_tref(ap),
                ph_to_mixed(ph_a(av, i2), ph_aty(av, i2)), TY_VOID)));
            i2 = i2 + 1;
        }
        ph_ety = PT_INT;
        return ph_c1("php_count", ph_tref(ap), TY_I64);
    }
    // sscanf($s, $f, &$a, ...): the outputs are BY REFERENCE and the row
    // padded the ones it was not given with null, so the runtime's "was
    // anything passed" test -- `a1` is not null -- was false for the very
    // first call, `sscanf($s, $f, $w, $v)` with $w undefined. Same answer as
    // register_shutdown_function below: php_zundef() for a slot the CALL
    // SITE did not write. (ph_brf_init registers the name too, so the
    // source scan boxes the variables.)
    if (str_eq(name, "sscanf")) {
        if (na < 2) ph_todo2(fl, line, "the wrong number of arguments for", name);
        if (na > 8) ph_todo2(fl, line, "the wrong number of arguments for", name);
        u8 scall[64];
        st64(scall, ph_to_mixed(a0, t0));
        st64(scall + 8, ph_to_mixed(ph_a(av, 1), ph_aty(av, 1)));
        i64 si = 2;
        loop {
            if (si >= 8) break;
            i64 sv = ph_call("php_zundef", 0, 0, 0, 0, 0, ty_pzv);
            if (si < na) sv = ph_to_mixed(ph_a(av, si), ph_aty(av, si));
            st64(scall + si * 8, sv);
            si = si + 1;
        }
        ph_ety = PT_MIXED;
        return ph_calln("php_f_sscanf", scall, 8, ty_pzv);
    }
    // register_shutdown_function($f, ...$args): the library row pads the
    // arguments it was not given with null, so the callee could not tell
    // them from a null that was passed and php_shutdown handed the callback
    // three of them -- which func_num_args() can see. The count comes from
    // here, the only place that knows it (the array_push shape above).
    if (str_eq(name, "register_shutdown_function")) {
        if (na < 1) ph_todo2(fl, line, "the wrong number of arguments for", name);
        if (na > 4) ph_todo2(fl, line, "the wrong number of arguments for", name);
        i64 sf = ph_to_mixed(a0, t0);
        i64 sa1 = ph_call("php_zundef", 0, 0, 0, 0, 0, ty_pzv);
        i64 sa2 = ph_call("php_zundef", 0, 0, 0, 0, 0, ty_pzv);
        i64 sa3 = ph_call("php_zundef", 0, 0, 0, 0, 0, ty_pzv);
        if (na > 1) sa1 = ph_to_mixed(ph_a(av, 1), ph_aty(av, 1));
        if (na > 2) sa2 = ph_to_mixed(ph_a(av, 2), ph_aty(av, 2));
        if (na > 3) sa3 = ph_to_mixed(ph_a(av, 3), ph_aty(av, 3));
        ph_ety = PT_BOOL;
        return ph_c4("php_f_reg_shutdown", sf, sa1, sa2, sa3, TY_U8);
    }
    if (str_eq(name, "var_dump")) {
        i64 head = 0;
        i64 tail = 0;
        i64 i = 0;
        loop {
            if (i >= na) break;
            i64 c = ph_vd(ph_a(av, i), ph_aty(av, i), fl, line);
            i64 s = node_new(N_EXPRSTMT, line, fl);
            set_nd_a(s, c);
            if (tail) set_nd_next(tail, s);
            if (!tail) head = s;
            tail = s;
            i = i + 1;
        }
        ph_pending_stmt(head);
        ph_ety = PT_NULL;
        return ph_int(0);
    }
    if (str_eq(name, "strlen"))   { ph_need(na, 1, name, fl, line); ph_ety = PT_INT; return ph_c1("php_strlen", ph_to_str(a0, t0), TY_I64); }
    if (str_eq(name, "count") || str_eq(name, "sizeof")) {
        ph_need(na, 1, name, fl, line);
        if (t0 == PT_MIXED) { ph_ety = PT_INT; return ph_c1("php_count", ph_c1("php_zv_arr_r", a0, ty_parr), TY_I64); }
        if (!ph_is_arr(t0)) ph_todo2(fl, line, "count() of", ph_tyname(t0));
        ph_ety = PT_INT;
        return ph_c1("php_count", a0, TY_I64);
    }
    if (str_eq(name, "str_repeat")) {
        ph_need(na, 2, name, fl, line);
        ph_ety = PT_STRING;
        return ph_c2("php_str_repeat", ph_to_str(a0, t0), ph_to_int(ph_a(av, 1), ph_aty(av, 1)), ty_pstr);
    }
    if (str_eq(name, "substr")) {
        if (na < 2 || na > 3) ph_need(na, 2, name, fl, line);
        i64 len = ph_int(0);
        i64 has = 0;
        if (na == 3) { len = ph_to_int(ph_a(av, 2), ph_aty(av, 2)); has = 1; }
        ph_ety = PT_STRING;
        return ph_c4("php_substr", ph_to_str(a0, t0), ph_to_int(ph_a(av, 1), ph_aty(av, 1)), len, ph_int(has), ty_pstr);
    }
    if (str_eq(name, "strpos")) {
        if (na < 2 || na > 3) ph_need(na, 2, name, fl, line);
        i64 off = ph_int(0);
        if (na == 3) off = ph_to_int(ph_a(av, 2), ph_aty(av, 2));
        ph_ety = PT_IFALSE;
        return ph_c3("php_strpos", ph_to_str(a0, t0), ph_to_str(ph_a(av, 1), ph_aty(av, 1)), off, TY_I64);
    }
    if (str_eq(name, "str_replace")) {
        if (na < 3 || na > 4) ph_todo2(fl, line, "the wrong number of arguments for", name);
        ph_ety = PT_STRING;
        // the fourth argument is php's by-reference $count
        i64 cnt = ph_int(0);
        if (na == 4) cnt = ph_a(av, 3);
        return ph_c4("php_str_replace_c", ph_to_str(a0, t0), ph_to_str(ph_a(av, 1), ph_aty(av, 1)),
                     ph_to_str(ph_a(av, 2), ph_aty(av, 2)), cnt, ty_pstr);
    }
    if (str_eq(name, "implode") || str_eq(name, "join")) {
        // php 8: implode($array) with no separator
        if (na == 1) {
            i64 one = a0;
            if (t0 == PT_MIXED) one = ph_c1("php_zv_arr_r", one, ty_parr);
            if (t0 != PT_MIXED && !ph_is_arr(t0)) ph_todo(fl, line, "implode() without an array");
            ph_ety = PT_STRING;
            return ph_c2("php_implode", ph_strlit("", 0), one, ty_pstr);
        }
        ph_need(na, 2, name, fl, line);
        i64 sep = a0;
        i64 arr = ph_a(av, 1);
        i64 at = ph_aty(av, 1);
        if (at == PT_MIXED) { arr = ph_c1("php_zv_arr_r", arr, ty_parr); at = PT_ARR; }
        if (!ph_is_arr(at)) {                            // implode($arr, $sep), the legacy order
            sep = ph_a(av, 1);
            arr = a0;
            at = t0;
            if (at == PT_MIXED) { arr = ph_c1("php_zv_arr_r", arr, ty_parr); at = PT_ARR; }
            sep = ph_to_str(sep, ph_aty(av, 1));
        }
        if (!ph_is_arr(at)) ph_todo(fl, line, "implode() without an array");
        ph_ety = PT_STRING;
        return ph_c2("php_implode", ph_to_str(sep, ph_aty(av, 0)), arr, ty_pstr);
    }
    if (str_eq(name, "explode")) {
        if (na < 2 || na > 3) ph_need(na, 2, name, fl, line);
        ph_ety = PT_ARR;
        ph_efresh = 1;
        if (na == 2) return ph_c2("php_explode", ph_to_str(a0, t0), ph_to_str(ph_a(av, 1), ph_aty(av, 1)), ty_parr);
        return ph_c3("php_f_explode3", ph_to_mixed(a0, t0), ph_to_mixed(ph_a(av, 1), ph_aty(av, 1)),
                     ph_to_mixed(ph_a(av, 2), ph_aty(av, 2)), ty_parr);
    }
    if (str_eq(name, "intdiv")) {
        ph_need(na, 2, name, fl, line);
        ph_ety = PT_INT;
        return ph_c2("php_intdiv", ph_to_int(a0, t0), ph_to_int(ph_a(av, 1), ph_aty(av, 1)), TY_I64);
    }
    if (str_eq(name, "abs")) {
        ph_need(na, 1, name, fl, line);
        if (t0 == PT_FLOAT) { ph_ety = PT_FLOAT; return ph_c1("php_abs_f", a0, ty_f64); }
        ph_ety = PT_INT;
        return ph_c1("php_abs_i", ph_to_int(a0, t0), TY_I64);
    }
    if (str_eq(name, "max") || str_eq(name, "min")) {
        // the two-number shape stays native; everything else is php's own
        // comparison over zvals, which is what max("10", "9a") needs
        i64 t1 = -1;
        if (na > 1) t1 = ph_aty(av, 1);
        if (na == 2 && !ph_had_spread) {
            if ((t0 == PT_FLOAT || t0 == PT_INT) && (t1 == PT_FLOAT || t1 == PT_INT)) {
                if (t0 == PT_FLOAT || t1 == PT_FLOAT) {
                    ph_ety = PT_FLOAT;
                    uptr f = "php_max_f";
                    if (str_eq(name, "min")) f = "php_min_f";
                    return ph_c2(f, ph_to_float(a0, t0), ph_to_float(ph_a(av, 1), t1), ty_f64);
                }
                ph_ety = PT_INT;
                uptr f2 = "php_max_i";
                if (str_eq(name, "min")) f2 = "php_min_i";
                return ph_c2(f2, ph_to_int(a0, t0), ph_to_int(ph_a(av, 1), t1), TY_I64);
            }
        }
        if (na < 1) ph_todo2(fl, line, "the wrong number of arguments for", name);
        i64 want = 1;
        if (str_eq(name, "min")) want = 0 - 1;
        // php_maxmin takes ten values (MAXPARAMS is 12 and two are spent on
        // the direction and the count), and the loop used to stop there
        // WITHOUT saying so: `max(1,...,11)` answered 10, and a spread of
        // more than ten values dropped the rest. max and min are
        // associative, so a longer list folds in chunks of ten -- the same
        // answer with no new runtime entry point and no second array.
        i64 res = 0;
        i64 q = 0;
        loop {
            if (q >= na) break;
            u8 mm[96];
            i64 k = 0;
            st64(mm, ph_int(want));
            i64 first = 0;
            if (res) { st64(mm + 16, res); k = 1; first = 1; }
            loop {
                if (k >= 10) break;
                if (q >= na) break;
                st64(mm + 16 + k * 8, ph_to_mixed(ph_a(av, q), ph_aty(av, q)));
                q = q + 1;
                k = k + 1;
            }
            // ONE value and no partial result is php's own array form
            // (`max([1,2,3])`), which this must not turn into: the count
            // says how many of the ten slots carry a value.
            i64 cnt = k;
            i64 z = k;
            loop {
                if (z >= 10) break;
                st64(mm + 16 + z * 8, ph_int(0));
                z = z + 1;
            }
            st64(mm + 8, ph_int(cnt));
            ph_ety = PT_MIXED;
            ph_can_throw = 1;
            res = ph_calln("php_maxmin", mm, 12, ty_pzv);
            if (first) { }
        }
        ph_ety = PT_MIXED;
        ph_can_throw = 1;
        return res;
    }
    if (str_eq(name, "define")) {
        ph_need(na, 2, name, fl, line);
        // a literal name is ALSO a compile-time constant, which keeps the
        // typed road; the run-time table is what constant()/defined() read
        if (t0 == PT_STRING && nd_kind(a0) == N_CALL && str_eq(nd_name(a0), "php_str_lit")) {
            i64 rawn = nd_next(nd_a(a0));
            uptr cn2 = xstrdup(nd_name(rawn), nd_val(rawn));
            if (ph_const_find(cn2) < 0) ph_const_add(cn2, ph_a(av, 1), ph_aty(av, 1), fl, line);
        }
        ph_ety = PT_BOOL;
        return ph_c2("php_f_define", ph_to_mixed(a0, t0), ph_to_mixed(ph_a(av, 1), ph_aty(av, 1)), TY_U8);
    }
    if (str_eq(name, "defined")) {
        ph_need(na, 1, name, fl, line);
        ph_ety = PT_BOOL;
        if (t0 == PT_STRING && nd_kind(a0) == N_CALL && str_eq(nd_name(a0), "php_str_lit")) {
            i64 rawd = nd_next(nd_a(a0));
            if (ph_const_find(xstrdup(nd_name(rawd), nd_val(rawd))) >= 0) return ph_bool(1);
            if (ph_pre_find(xstrdup(nd_name(rawd), nd_val(rawd))) >= 0) return ph_bool(1);
        }
        return ph_cast(TY_U8, ph_c1("php_f_defined", ph_to_mixed(a0, t0), TY_I64));
    }
    if (str_eq(name, "chr")) { ph_need(na, 1, name, fl, line); ph_ety = PT_STRING; return ph_c1("php_chr", ph_to_int(a0, t0), ty_pstr); }
    if (str_eq(name, "ord")) { ph_need(na, 1, name, fl, line); ph_ety = PT_INT; return ph_c1("php_ord", ph_to_str(a0, t0), TY_I64); }
    if (str_eq(name, "strtoupper")) { ph_need(na, 1, name, fl, line); ph_ety = PT_STRING; return ph_c1("php_strtoupper", ph_to_str(a0, t0), ty_pstr); }
    if (str_eq(name, "strtolower")) { ph_need(na, 1, name, fl, line); ph_ety = PT_STRING; return ph_c1("php_strtolower", ph_to_str(a0, t0), ty_pstr); }
    if (str_eq(name, "ucfirst")) { ph_need(na, 1, name, fl, line); ph_ety = PT_STRING; return ph_c1("php_ucfirst", ph_to_str(a0, t0), ty_pstr); }
    if (str_eq(name, "lcfirst")) { ph_need(na, 1, name, fl, line); ph_ety = PT_STRING; return ph_c1("php_lcfirst", ph_to_str(a0, t0), ty_pstr); }
    if (str_eq(name, "strrev")) { ph_need(na, 1, name, fl, line); ph_ety = PT_STRING; return ph_c1("php_strrev", ph_to_str(a0, t0), ty_pstr); }
    if (str_eq(name, "trim") || str_eq(name, "ltrim") || str_eq(name, "rtrim") || str_eq(name, "chop")) {
        if (na < 1 || na > 2) ph_todo2(fl, line, "the wrong number of arguments for", name);
        uptr f = "php_f_trim";
        if (str_eq(name, "ltrim")) f = "php_f_ltrim";
        if (str_eq(name, "rtrim") || str_eq(name, "chop")) f = "php_f_rtrim";
        i64 cl = ph_call("php_znull", 0, 0, 0, 0, 0, ty_pzv);
        if (na == 2) cl = ph_to_mixed(ph_a(av, 1), ph_aty(av, 1));
        ph_ety = PT_STRING;
        return ph_c2(f, ph_to_mixed(a0, t0), cl, ty_pstr);
    }
    if (str_eq(name, "str_pad")) {
        if (na < 2 || na > 4) ph_need(na, 2, name, fl, line);
        i64 pad = ph_strlit(" ", 1);
        i64 type = ph_int(1);                       // STR_PAD_RIGHT
        if (na >= 3) pad = ph_to_str(ph_a(av, 2), ph_aty(av, 2));
        if (na >= 4) type = ph_to_int(ph_a(av, 3), ph_aty(av, 3));
        ph_ety = PT_STRING;
        return ph_c4("php_str_pad", ph_to_str(a0, t0), ph_to_int(ph_a(av, 1), ph_aty(av, 1)), pad, type, ty_pstr);
    }
    if (str_eq(name, "str_contains")) { ph_need(na, 2, name, fl, line); ph_ety = PT_BOOL; return ph_c2("php_str_contains", ph_to_str(a0, t0), ph_to_str(ph_a(av, 1), ph_aty(av, 1)), TY_U8); }
    if (str_eq(name, "str_starts_with")) { ph_need(na, 2, name, fl, line); ph_ety = PT_BOOL; return ph_c2("php_str_starts", ph_to_str(a0, t0), ph_to_str(ph_a(av, 1), ph_aty(av, 1)), TY_U8); }
    if (str_eq(name, "str_ends_with")) { ph_need(na, 2, name, fl, line); ph_ety = PT_BOOL; return ph_c2("php_str_ends", ph_to_str(a0, t0), ph_to_str(ph_a(av, 1), ph_aty(av, 1)), TY_U8); }
    if (str_eq(name, "strcmp")) { ph_need(na, 2, name, fl, line); ph_ety = PT_INT; return ph_c2("php_str_cmp", ph_to_str(a0, t0), ph_to_str(ph_a(av, 1), ph_aty(av, 1)), TY_I64); }
    if (str_eq(name, "strcasecmp")) { ph_need(na, 2, name, fl, line); ph_ety = PT_INT; return ph_c2("php_strcasecmp", ph_to_str(a0, t0), ph_to_str(ph_a(av, 1), ph_aty(av, 1)), TY_I64); }
    if (str_eq(name, "intval")) { ph_need(na, 1, name, fl, line); ph_ety = PT_INT;    return ph_to_int(a0, t0); }
    if (str_eq(name, "strval")) { ph_need(na, 1, name, fl, line); ph_ety = PT_STRING; return ph_to_str(a0, t0); }
    if (str_eq(name, "floatval") || str_eq(name, "doubleval")) { ph_need(na, 1, name, fl, line); ph_ety = PT_FLOAT; return ph_to_float(a0, t0); }
    if (str_eq(name, "boolval")) { ph_need(na, 1, name, fl, line); ph_ety = PT_BOOL; return ph_to_bool(a0, t0); }
    // D4 makes these compile-time constants: the type IS static
    if (str_eq(name, "is_int") || str_eq(name, "is_integer") || str_eq(name, "is_long"))
        return ph_isof(na, t0, a0, PT_INT, 4, fl, line, name);
    if (str_eq(name, "is_scalar")) {
        ph_need(na, 1, name, fl, line); ph_ety = PT_BOOL;
        if (t0 == PT_MIXED || t0 == PT_NULL) return ph_cast(TY_U8, ph_c1("php_zv_isscalar", a0, TY_I64));
        if (t0 == PT_ARR) return ph_bool(0);
        return ph_bool(1);
    }
    if (str_eq(name, "is_object")) {
        ph_need(na, 1, name, fl, line); ph_ety = PT_BOOL;
        if (t0 == PT_MIXED) return ph_cast(TY_U8, ph_c2("php_zv_is", a0, ph_int(8), TY_I64));
        return ph_bool(0);
    }
    if (str_eq(name, "is_string")) return ph_isof(na, t0, a0, PT_STRING, 6, fl, line, name);
    if (str_eq(name, "is_float") || str_eq(name, "is_double")) return ph_isof(na, t0, a0, PT_FLOAT, 5, fl, line, name);
    if (str_eq(name, "is_bool")) return ph_isof(na, t0, a0, PT_BOOL, 3, fl, line, name);
    if (str_eq(name, "is_array")) return ph_isof(na, t0, a0, PT_ARR, 7, fl, line, name);
    if (str_eq(name, "is_null")) return ph_isof(na, t0, a0, PT_NULL, 1, fl, line, name);
    if (str_eq(name, "is_numeric")) {
        ph_need(na, 1, name, fl, line); ph_ety = PT_BOOL;
        if (t0 == PT_MIXED || t0 == PT_NULL) return ph_cast(TY_U8, ph_c1("php_zv_isnum", a0, TY_I64));
        if (t0 == PT_INT || t0 == PT_FLOAT) return ph_bool(1);
        if (t0 == PT_STRING) return ph_cast(TY_U8, ph_c1("php_zv_isnum", ph_to_mixed(a0, t0), TY_I64));
        return ph_bool(0);
    }
    if (str_eq(name, "function_exists")) {
        ph_need(na, 1, name, fl, line);
        ph_ety = PT_BOOL;
        uptr fnm = ph_alit(av, 0);
        if (!fnm) ph_refuse(fl, line, "function_exists with a name that is not a literal", "D6");
        return ph_bool(ph_fn_exists(fnm));
    }
    // get_called_class(): late static binding as a name, so it goes where
    // the compiler knows the declaring class
    if (str_eq(name, "get_called_class")) {
        if (na) ph_todo2(fl, line, "the wrong number of arguments for", name);
        i64 decl = ph_int(0);
        if (ph_cur_ceg) decl = ph_ceref(ph_cur_ceg);
        ph_ety = PT_MIXED;
        return ph_c1("php_f_called_class", decl, ty_pzv);
    }

    // a php function this program declared
    i64 fi = ph_fn_find(name);
    if (fi < 0) {
        i64 li = ph_lib_find(name);
        if (li >= 0) {
            i64 mn = ld64(ph_lmin + li * 8);
            i64 mx = ld64(ph_lmax + li * 8);
            if (ph_had_spread) { if (na > mx) na = mx; if (na < mn) na = mn; }
            if (na < mn || na > mx) ph_todo2(fl, line, "the wrong number of arguments for", name);
            i64 lhead = 0;
            i64 ltail = 0;
            i64 j = 0;
            loop {
                if (j >= mx) break;
                i64 an = ph_call("php_znull", 0, 0, 0, 0, 0, ty_pzv);
                if (j < na) an = ph_to_mixed(ph_a(av, j), ph_aty(av, j));
                if (j < na && ph_had_spread) an = ph_c1("php_nn", an, ty_pzv);
                if (ltail) set_nd_next(ltail, an);
                if (!ltail) lhead = an;
                ltail = an;
                j = j + 1;
            }
            i64 lc = node_new(N_CALL, line, fl);
            set_nd_name(lc, ld64(ph_lf + li * 8));
            set_nd_a(lc, lhead);
            i64 lr = ld64(ph_lret + li * 8);
            set_nd_type(lc, ph_mcty(lr));
            ph_ety = lr;
            if (lr == PT_ARR) ph_efresh = 1;
            return lc;
        }
        ph_todo2(fl, line, "a php function mc-php does not have", name);
    }
    i64 np = ld64(ph_fnp + fi * 8);
    i64 vararg = ld64(ph_fvar + fi * 8);
    i64 spread = ph_had_spread;
    if (na > np && !vararg && !spread) ph_todo2(fl, line, "the wrong number of arguments for", name);
    i64 head = 0;
    i64 tail = 0;
    i64 i = 0;
    i64 coerced = 0;
    loop {
        if (i >= np) break;
        i64 want = ld64(ph_fpt + (fi * PH_MAXP + i) * 8);
        i64 v = 0;
        if (vararg && i == np - 1) {
            // ...$rest: the caller packs what is left into an array
            ph_nonce = ph_nonce + 1;
            uptr rn = p_cat("phva_", php_dec(ph_nonce), 0, cstrlen(php_dec(ph_nonce)));
            ph_local(rn, ty_parr);
            i64 mk = ph_set(rn, ph_c1("php_arr_new", ph_int(8), ty_parr));
            i64 mt = mk;
            i64 j = i;
            i64 vpc = ld64(ph_fvpc + fi * 8);
            loop {
                if (j >= na) break;
                i64 ar = node_new(N_IDENT, line, fl);
                set_nd_name(ar, rn);
                set_nd_type(ar, ty_parr);
                uptr pushfn = "php_arr_push";
                if (spread) pushfn = "php_arr_push_opt";
                i64 el = ph_to_mixed(ph_a(av, j), ph_aty(av, j));
                if (vpc) {
                    u8 vcb[64];
                    st64(vcb, el);
                    st64(vcb + 8, ph_int(vpc));
                    st64(vcb + 16, ph_strlit("", 0));
                    st64(vcb + 24, ph_strlit(name, cstrlen(name)));
                    st64(vcb + 32, ph_int(j + 1));
                    st64(vcb + 40, ph_strlit("", 0));
                    el = ph_calln("php_param_coerce", vcb, 6, ty_pzv);
                }
                i64 ps = ph_stmt_of(ph_c2(pushfn, ar, el, TY_VOID));
                set_nd_next(mt, ps);
                mt = ps;
                j = j + 1;
            }
            // a refused element leaves the body unreached: without this the
            // pushes after it store nulls and the function still runs
            if (vpc && na > i) {
                i64 vck = ph_check(line, fl);
                set_nd_next(mt, vck);
                mt = vck;
                ph_can_throw = 1;
            }
            ph_pending_stmt(mk);
            v = node_new(N_IDENT, line, fl);
            set_nd_name(v, rn);
            set_nd_type(v, ty_parr);
        }
        if (!v && i >= na) {
            // not passed: a zval parameter takes 0, which its prologue reads
            if (want != PT_MIXED) ph_todo2(fl, line, "the wrong number of arguments for", name);
            v = ph_int(0);
        }
        if (!v && spread && want != PT_MIXED)
            ph_todo2(fl, line, "argument unpacking into a typed parameter of", name);
        if (!v) {
            i64 have = ph_aty(av, i);
            v = ph_a(av, i);
            // A parameter that KEPT its declared primitive is handed a native
            // int/float/string, so the type is gone at the ABI boundary and
            // the callee cannot check it -- `f(int $a)` with `f([])` ran the
            // body on a 0 where php raises a TypeError. The caller is the only
            // side that still has the zval, so the check is here, and only
            // when the argument IS a zval: a static int needs none.
            i64 cw = 0;
            if (have != want) {
                if (want == PT_INT)    cw = 1;
                if (want == PT_FLOAT)  cw = 2;
                if (want == PT_STRING) cw = 3;
                if (want == PT_BOOL)   cw = 4;
            }
            if (cw) {
                uptr pn = ld64(ph_fpn + (fi * PH_MAXP + i) * 8);
                u8 acb[64];
                st64(acb, ph_to_mixed(v, have));
                st64(acb + 8, ph_int(cw));
                st64(acb + 16, ph_strlit("", 0));
                st64(acb + 24, ph_strlit(name, cstrlen(name)));
                st64(acb + 32, ph_int(i + 1));
                st64(acb + 40, ph_strlit(pn, cstrlen(pn)));
                v = ph_tref(ph_temp(ph_calln("php_param_coerce", acb, 6, ty_pzv),
                                    ty_pzv, "phc_"));
                have = PT_MIXED;
                coerced = 1;
            }
            if (want == PT_INT)    v = ph_to_int(v, have);
            if (want == PT_FLOAT)  v = ph_to_float(v, have);
            if (want == PT_STRING) v = ph_to_str(v, have);
            if (want == PT_BOOL)   v = ph_to_bool(v, have);
            if (want == PT_MIXED)  v = ph_to_mixed(v, have);
            if (want == PT_ARR && have == PT_MIXED) v = ph_c1("php_zv_arr_r", v, ty_parr);
        }
        if (tail) set_nd_next(tail, v);
        if (!tail) head = v;
        tail = v;
        i = i + 1;
    }
    // ONE check for the whole argument list: php_param_coerce is a no-op once
    // something is pending, so the FIRST refusal is the one that stands, and
    // this runs before the call, so the body is not reached with a filled-in 0
    if (coerced) ph_pending_stmt(ph_check(line, fl));
    ph_can_throw = 1;
    i64 c = node_new(N_CALL, line, fl);
    set_nd_name(c, ph_mangle(name, "f_"));
    set_nd_a(c, head);
    i64 rt = ld64(ph_fret + fi * 8);
    set_nd_type(c, ph_mcty(rt));
    ph_ety = rt;
    ph_ref_call = ld64(ph_frr + fi * 8);
    return c;
}



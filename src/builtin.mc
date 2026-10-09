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
// ... and its DECLARED scalar return type (PT_INT..PT_BOOL), or -1: the
// return lowers as the cell (mixed), and the declared type is php's check
// on the value, made in place (src/lvalue.mc)
i64 ph_fn_retdecl;
// the function being lowered was declared `: void`: `return EXPR;` is php's
// compile-time fatal. Separate from ph_fn_ret because a function called
// ahead of its definition answers a value anyway (src/decl.mc).
i64 ph_fn_void;
// the DECLARED return type of the function being lowered, as php verifies it
// (src/types.mc RT_*; 0 when there is none, or a shape not checked here),
// its class names, php's spelling of it, the function's name as php's
// messages print it, and whether php calls it a method (it is written in a
// class): src/lvalue.mc's return, and the fall off the end (ph_ret_null)
i64  ph_fn_rtm;
uptr ph_fn_rtc;
uptr ph_fn_rtn;
uptr ph_fn_rtq;
i64  ph_fn_meth;

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

// ord($s[$i]): set by the caller just before ph_read_args, like ph_argref.
// The first argument, when it is a string offset, is then read as its BYTE
// (php_str_byte) before it can be hoisted, and ph_argbyte_done says so.
i64 ph_argbyte;
// 1 for a method call's arguments (src/class.mc ph_margs): a spread is one
// entry, its operand, with the type PH_SPREADT -- the call hands the runtime
// every value it holds, however many, and not a fixed number of slots
i64 ph_ra_tail;
#define PH_SPREADT (0 - 2)
// 1 when the argument list just read was `(...)`: a first-class callable
// (php 8.1), which the call shape turns into a closure (src/class.mc)
i64 ph_fcc;
i64 ph_argbyte_done;

i64 ph_zl_args;                  // ph_zl as the last argument left it
uptr ph_read_args(i64 maxn, uptr fl, i64 line, uptr pn) {
    // 24 bytes per argument: the node, its php type, and -- when the
    // argument is a string LITERAL -- its bytes, which is what a
    // compile-time answer like function_exists('f') needs (D6). The node
    // alone cannot say: an argument is hoisted into a temporary whenever it
    // can throw, and ph_strlit's own call sets that flag.
    uptr buf = xalloc(maxn * 24 + 24 + PH_SPREADN * 24);
    i64 mask = ph_argref;
    ph_argref = 0;
    i64 byte = ph_argbyte;
    ph_argbyte = 0;
    i64 tailm = ph_ra_tail;
    ph_ra_tail = 0;
    i64 fused = 0;
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
            if (tailm && n == 0 && ph_at(")", 1)) { ph_fcc = 1; break; }
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
            if (tailm) {
                // the operand checked, as below, and kept whole
                ph_pending_stmt(ph_stmt_of(ph_c2("php_unpack_check", ph_tref(tmp), ph_int(0), TY_VOID)));
                ph_pending_stmt(ph_check(ph_tline, ph_tfile));
                if (n >= maxn) ph_todo(fl, line, "too many arguments for this builtin");
                st64(buf + n * 24, ph_tref(tmp));
                st64(buf + n * 24 + 8, PH_SPREADT);
                st64(buf + n * 24 + 16, 0);
                n = n + 1;
                mine = 1;
                ph_had_spread = mine;
                if (ph_accept(",", 1)) continue;
                break;
            }
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
        // a call with no value (var_dump) is null here, as a zval: a bare 0
        // hoisted below would be a missing argument to the callee
        if (t == PT_NULL && nd_kind(a) == N_INT) a = ph_to_mixed(a, t);
        // the byte of a C read is a C read (src/expr.mc ph_index)
        uptr bn = 0;
        if (byte && n == 0 && t == PT_STRING && nd_kind(a) == N_CALL) {
            if (str_eq(nd_name(a), "php_str_off")) bn = "php_str_byte";
            if (str_eq(nd_name(a), "php_str_off_c")) bn = "php_str_byte_c";
            if (str_eq(nd_name(a), "php_str_off_d")) bn = "php_str_byte_d";
        }
        if (bn) {
            set_nd_name(a, bn);
            set_nd_type(a, TY_I64);
            t = PT_INT;
            fused = 1;
        }
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
    // the call itself is php's DO_FCALL, at the call's own line (the line its
    // name is on): what it raises is reported there whatever line its last
    // argument ended on -- except where php compiles it to an opcode, which
    // is at its last argument's (ph_builtin's `opc`)
    ph_zl_args = ph_zl;
    ph_zl = line;
    st64(pn, n);
    ph_had_spread = mine;
    ph_argbyte_done = fused;
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
    // is_int/is_float/is_string of a zval is a plain tag compare: the low byte
    // of the type_info u32 at +8 equals the tag (php_zv_type, lib/php_rt.mc),
    // inlined here -- no php_zv_is call -- for those three tags (4 long, 5
    // double, 6 string). is_bool (3) and is_null (1) keep the call, since
    // php_zv_is folds true/false together for a bool. ph_guard_of (src/types.mc)
    // matches this exact shape so `if (is_string($t))` still narrows.
    if ((t0 == PT_MIXED || t0 == PT_NULL) && (ztype == 4 || ztype == 5 || ztype == 6)) {
        i64 ty = ph_quiet("ld32", 1, ph_bin(ph_tok("+", 1), a0, ph_int(8), TY_UPTR), 0, 0, 0, TY_I64);
        i64 lo = ph_bin(ph_tok("&", 1), ty, ph_int(255), TY_I64);
        return ph_cast(TY_U8, ph_bin(ph_tok("==", 2), lo, ph_int(ztype), TY_U8));
    }
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
        ph_pending_stmt(ph_stmt_of(ph_c2("php_throw_str", ph_strlit("ArgumentCountError", 18),
                                         ph_strlit("sprintf() expects at least 1 argument, 0 given", 46), TY_VOID)));
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

// ---- a call through php's function table (the extension road) -------------
// A function the source does not declare and the library does not have is
// php's to find when the call runs (lib/php_ext.mc's phx_fcall), which is
// what a C extension does to call another extension's function. The
// arguments cross as engine zvals built on the stack: an int, a string and a
// bool as themselves, anything else through a runtime zval. The callee is not
// visible here, so the answer is a zval and the context types it with php's
// rules (a declared `: int` return checks it).
i64 ph_ftable_call(uptr name, uptr av, i64 na, uptr fl, i64 line, i64 fb) {
    if (ph_had_spread) ph_todo2(fl, line, "argument unpacking into a function php's function table answers", name);
    // ponytail: four, the (value, what) pairs of one mc call; a staging
    // buffer if a real source needs more
    if (na > 4) ph_todo2(fl, line, "more than 4 arguments to a function php's function table answers", name);
    // the count and each argument's kind packed in one word (phx_zin), so the
    // call travels in registers
    u8 cv[56];
    i64 nt = na;
    i64 i = 0;
    loop {
        if (i >= 4) break;
        i64 v = ph_int(0);
        if (i < na) {
            i64 t = ph_aty(av, i);
            v = ph_a(av, i);
            i64 w = 0;
            if (t == PT_INT) w = 4;                         // IS_LONG
            if (t == PT_STRING) w = 6;                      // IS_STRING
            if (t == PT_BOOL) { w = 2; v = ph_cast(TY_I64, v); }   // IS_FALSE + the value
            if (!w) v = ph_to_mixed(v, t);
            nt = nt | (w << (8 + i * 8));
        }
        st64(cv + 16 + i * 8, v);
        i = i + 1;
    }
    // The call site's own words (lib/php_ext.mc's phx_fcall): the function
    // found and the request it was found in, then what only a slow road reads
    // -- the name as the source spells it, the function this call is in (a
    // TypeError names it), the packed word -- so the common call passes
    // nothing but the arguments.
    uptr fn = ph_cur_fn;
    if (!fn) fn = "";
    // an unqualified name inside a namespace: php tries `ns\name` first and
    // then the global one (bit 48 of the packed word, lib/php_ext.mc)
    if (fb) { name = ph_ns_join(ph_ns_cur(), name); nt = nt | (1 << 48); }
    i64 i0 = ph_int(0);
    i64 i1 = ph_int(0);
    i64 sn = ph_raw(name, cstrlen(name));
    i64 sf = ph_raw(fn, cstrlen(fn));
    set_nd_next(i0, i1);
    set_nd_next(i1, sn);
    set_nd_next(sn, sf);
    set_nd_next(sf, ph_int(nt));
    st64(cv, ph_cache_init("phf_", 5, i0));
    st64(cv + 8, ph_int(nt));
    ph_ety = PT_MIXED;
    return ph_calln("phx_fcall", cv, 6, ty_pzv);
}

// Native sync, the primitive layer (docs/threads.md § Step 4): int handles
// into lib/php_rt.mc's table, every one of them an object of the process.
//   mcphp_mutex(): int                       mcphp_atomic(int $v = 0): int
//   mcphp_mutex_lock(int $m): void           mcphp_atomic_load(int $a): int
//   mcphp_mutex_trylock(int $m): bool        mcphp_atomic_store(int $a, int $v): void
//   mcphp_mutex_unlock(int $m): void         mcphp_atomic_add(int $a, int $d): int   (the value before)
//                                            mcphp_atomic_cas(int $a, int $e, int $n): bool
//                                            mcphp_atomic_xchg(int $a, int $v): int  (the value before)
// A handle that is not a live object of the kind, a lock of a mutex the
// thread holds, an unlock of one it does not: a named Error. 0 when `name`
// is none of these.
i64 ph_bi_sync(uptr name, i64 line, uptr fl) {
    uptr rt = 0;
    i64 lo = 1;
    i64 hi = 1;
    i64 ety = PT_INT;
    i64 defd = 0;                            // the last argument has a default
    i64 defval = 0;                          // its value (0 or -1)
    if (str_eq(name, "mcphp_mutex"))         { rt = "php_sy_mutex"; lo = 0; hi = 0; }
    if (str_eq(name, "mcphp_mutex_lock"))    { rt = "php_sy_lock"; ety = PT_NULL; }
    if (str_eq(name, "mcphp_mutex_trylock")) { rt = "php_sy_trylock"; ety = PT_BOOL; }
    if (str_eq(name, "mcphp_mutex_unlock"))  { rt = "php_sy_unlock"; ety = PT_NULL; }
    if (str_eq(name, "mcphp_atomic"))        { rt = "php_sy_atomic"; lo = 0; defd = 1; }
    if (str_eq(name, "mcphp_atomic_load"))   rt = "php_sy_load";
    if (str_eq(name, "mcphp_atomic_store"))  { rt = "php_sy_store"; lo = 2; hi = 2; ety = PT_NULL; }
    if (str_eq(name, "mcphp_atomic_add"))    { rt = "php_sy_add"; lo = 2; hi = 2; }
    if (str_eq(name, "mcphp_atomic_cas"))    { rt = "php_sy_cas"; lo = 3; hi = 3; ety = PT_BOOL; }
    if (str_eq(name, "mcphp_atomic_xchg"))   { rt = "php_sy_xchg"; lo = 2; hi = 2; }
    // 4b: semaphore, waitgroup, condition variable, with the timeout on the
    // three blocking waits (int $timeout_ms = -1; false on timeout)
    if (str_eq(name, "mcphp_semaphore"))         { rt = "php_sy_sem"; lo = 0; defd = 1; }
    if (str_eq(name, "mcphp_semaphore_acquire")) { rt = "php_sy_acquire"; lo = 1; hi = 2; defd = 1; defval = 0 - 1; ety = PT_BOOL; }
    if (str_eq(name, "mcphp_semaphore_release")) { rt = "php_sy_release"; ety = PT_NULL; }
    if (str_eq(name, "mcphp_waitgroup"))         { rt = "php_sy_wg"; lo = 0; hi = 0; }
    if (str_eq(name, "mcphp_waitgroup_add"))     { rt = "php_sy_wg_add"; lo = 2; hi = 2; ety = PT_NULL; }
    if (str_eq(name, "mcphp_waitgroup_done"))    { rt = "php_sy_wg_done"; ety = PT_NULL; }
    if (str_eq(name, "mcphp_waitgroup_wait"))    { rt = "php_sy_wg_wait"; lo = 1; hi = 2; defd = 1; defval = 0 - 1; ety = PT_BOOL; }
    if (str_eq(name, "mcphp_cond"))              { rt = "php_sy_cond"; lo = 0; hi = 0; }
    if (str_eq(name, "mcphp_cond_wait"))         { rt = "php_sy_cond_wait"; lo = 2; hi = 3; defd = 1; defval = 0 - 1; ety = PT_BOOL; }
    if (str_eq(name, "mcphp_cond_signal"))       { rt = "php_sy_cond_signal"; ety = PT_NULL; }
    if (str_eq(name, "mcphp_cond_broadcast"))    { rt = "php_sy_cond_broadcast"; ety = PT_NULL; }
    if (!rt) return 0;
    u8 np[8];
    uptr av = ph_read_args(3, fl, line, np);
    i64 n = ld64(np);
    if (n < lo || n > hi) ph_todo2(fl, line, "the wrong number of arguments for", name);
    i64 a0 = 0;
    i64 a1 = 0;
    i64 a2 = 0;
    if (n > 0) a0 = ph_to_int(ph_a(av, 0), ph_aty(av, 0));
    if (n > 1) a1 = ph_to_int(ph_a(av, 1), ph_aty(av, 1));
    if (n > 2) a2 = ph_to_int(ph_a(av, 2), ph_aty(av, 2));
    // the omitted default -- mcphp_atomic()/mcphp_semaphore() at 0, a missing
    // timeout at -1 -- is the last argument, so it fills the first free slot
    if (defd && n == hi - 1) {
        if (n == 0) a0 = ph_int(defval);
        if (n == 1) a1 = ph_int(defval);
        if (n == 2) a2 = ph_int(defval);
        n = hi;
    }
    i64 ty = TY_I64;
    if (ety == PT_NULL) ty = ty_pzv;
    i64 c = ph_call(rt, n, a0, a1, a2, 0, ty);
    ph_ety = ety;
    if (ety == PT_BOOL) return ph_cast(TY_U8, c);
    return c;
}

// The event loop and await (docs/threads.md § Step 5): cooperative fibers on
// one thread, suspended at an await until a timer, a future or an fd is ready.
// Eight published intrinsics, plus the self-test's pipe scaffolding (marked).
//   mcphp_future(): int                          a pending future (a handle)
//   mcphp_future_complete(int $f, mixed $v): void
//   mcphp_future_fail(int $f, \Throwable $e): void
//   mcphp_await(int $f): mixed                    suspend until $f is done
//   mcphp_timer(int $ms): int                     a future done after $ms
//   mcphp_loop_run(): void                        drive until nothing is pending
//   mcphp_spawn(callable $fn, mixed ...$args): int  run $fn on a fresh fiber
//   mcphp_io_read(int $fd, int $len): string      await a non-blocking read
// Values cross an await as ordinary in-arena values (cooperative, one thread:
// no deep copy within a thread; cross-thread completion is step 6b).
i64 ph_bi_async(uptr name, i64 line, uptr fl) {
    // the one-int and no-arg ones, by table
    uptr rt = 0;
    i64 lo = 1; i64 hi = 1; i64 ety = PT_INT;
    if (str_eq(name, "mcphp_future"))   { rt = "php_fut_new"; lo = 0; hi = 0; }
    if (str_eq(name, "mcphp_timer"))    rt = "php_timer";
    if (str_eq(name, "mcphp_loop_run")) { rt = "php_loop_run"; lo = 0; hi = 0; ety = PT_NULL; }
    if (str_eq(name, "mcphp_can_suspend")) { rt = "php_can_suspend"; lo = 0; hi = 0; ety = PT_BOOL; }
    if (str_eq(name, "mcphp_await"))    { rt = "php_await"; ety = PT_MIXED; }
    if (str_eq(name, "mcphp_pipe"))     { rt = "php_test_pipe"; lo = 0; hi = 0; }
    if (str_eq(name, "mcphp_tcp_listen")) rt = "php_test_listen";
    if (str_eq(name, "mcphp_fd_close")) { rt = "php_test_fd_close"; ety = PT_NULL; }
    if (str_eq(name, "mcphp_tcp_close")) { rt = "php_sock_close"; ety = PT_NULL; }   // a Winsock SOCKET needs closesocket, not close()
    if (str_eq(name, "mcphp_test_migrate")) { rt = "php_test_migrate"; lo = 0; hi = 0; ety = PT_NULL; }
    if (rt) {
        u8 np[8];
        uptr av = ph_read_args(2, fl, line, np);
        i64 n = ld64(np);
        if (n < lo || n > hi) ph_todo2(fl, line, "the wrong number of arguments for", name);
        i64 a0 = 0;
        if (n > 0) a0 = ph_to_int(ph_a(av, 0), ph_aty(av, 0));
        i64 ty = TY_I64;
        if (ety == PT_NULL || ety == PT_MIXED) ty = ty_pzv;
        i64 c = ph_call(rt, n, a0, 0, 0, 0, ty);
        ph_ety = ety;
        return c;
    }
    // (int, mixed): complete, fail, and the pipe-write scaffolding
    uptr r2 = 0;
    i64 e2 = PT_NULL;
    if (str_eq(name, "mcphp_future_complete")) r2 = "php_fut_complete";
    if (str_eq(name, "mcphp_future_fail"))     r2 = "php_fut_fail";
    if (str_eq(name, "mcphp_fd_write"))        { r2 = "php_test_fd_write"; e2 = PT_INT; }
    if (str_eq(name, "mcphp_tcp_accept_send")) r2 = "php_test_accept_send";
    if (r2) {
        u8 np[8];
        uptr av = ph_read_args(2, fl, line, np);
        if (ld64(np) != 2) ph_todo2(fl, line, "the wrong number of arguments for", name);
        i64 a0 = ph_to_int(ph_a(av, 0), ph_aty(av, 0));
        i64 a1 = ph_to_mixed(ph_a(av, 1), ph_aty(av, 1));
        i64 ty = ty_pzv; if (e2 == PT_INT) ty = TY_I64;
        i64 c = ph_c2(r2, a0, a1, ty);
        ph_ety = e2;
        return c;
    }
    // mcphp_io_read(int $fd, int $len): string
    if (str_eq(name, "mcphp_io_read")) {
        u8 np[8];
        uptr av = ph_read_args(2, fl, line, np);
        if (ld64(np) != 2) ph_todo2(fl, line, "the wrong number of arguments for", name);
        i64 a0 = ph_to_int(ph_a(av, 0), ph_aty(av, 0));
        i64 a1 = ph_to_int(ph_a(av, 1), ph_aty(av, 1));
        i64 c = ph_c2("php_io_read", a0, a1, ty_pzv);
        ph_ety = PT_MIXED;             // php_io_read returns a zval (a string), like mcphp_await
        return c;
    }
    // mcphp_connect(int $ip, int $port): int -- a non-blocking TCP connect
    // driven by the loop (docs/threads.md § Step 6b), returning the connected
    // fd; it rethrows at the await if the connect failed.
    if (str_eq(name, "mcphp_connect")) {
        u8 np[8];
        uptr av = ph_read_args(2, fl, line, np);
        if (ld64(np) != 2) ph_todo2(fl, line, "the wrong number of arguments for", name);
        i64 a0 = ph_to_int(ph_a(av, 0), ph_aty(av, 0));
        i64 a1 = ph_to_int(ph_a(av, 1), ph_aty(av, 1));
        i64 c = ph_c2("php_connect", a0, a1, TY_I64);
        ph_can_throw = 1;
        ph_ety = PT_INT;
        return c;
    }
    // mcphp_spawn(callable $fn, mixed ...$args): int -- the single-thread
    // analog of mcphp_thread_start, the fiber entry point. Arguments by value.
    if (str_eq(name, "mcphp_spawn")) {
        u8 snp[8];
        uptr sav = ph_read_args(6, fl, line, snp);
        i64 sn = ld64(snp);
        if (sn < 1) ph_todo2(fl, line, "the wrong number of arguments for", name);
        if (sn > 6) ph_todo2(fl, line, "more than five arguments for a fiber in", name);
        i64 c = node_new(N_CALL, line, fl);
        set_nd_name(c, "php_fib_spawn");
        set_nd_type(c, TY_I64);
        i64 a0 = ph_to_mixed(ph_a(sav, 0), ph_aty(sav, 0));
        set_nd_a(c, a0);
        i64 cnt = ph_int(sn - 1);
        set_nd_next(a0, cnt);
        i64 prev = cnt;
        i64 si = 1;
        loop {
            if (si > 5) break;
            i64 arg = ph_int(0);
            if (si < sn) arg = ph_to_mixed(ph_a(sav, si), ph_aty(sav, si));
            set_nd_next(prev, arg);
            prev = arg;
            si = si + 1;
        }
        ph_can_throw = 1;
        ph_ety = PT_INT;
        return c;
    }
    return 0;
}

// ---- the call's frame (lib/php_rt.mc § the trace) ---------------------------
// A compiled PROGRAM keeps php's call stack itself: around a call of a php
// function or method it pushes a frame -- the function, its class and `->` or
// `::`, the call's own file and line, and the arguments as they were passed,
// each a (tag, value) pair -- and pops it once the call returns, an exception
// included. A throwable created meanwhile copies the stack into its `trace`.
// An extension pushes nothing: Zend keeps the frames there.
//
// The arguments are evaluated once, before the frame: each one that is not a
// plain name or integer goes into a temporary of its own, which the frame and
// the call then both read. Answers the frame's argument area (a temporary),
// or 0 when no frame is kept.
// a statement of e alone: ph_expr_stmt_of would splice the pending queue in
i64 ph_fr_st(i64 e) {
    i64 st = node_new(N_EXPRSTMT, ph_tline, ph_tfile);
    set_nd_a(st, e);
    return st;
}
i64 ph_fr_tag(i64 t) {
    if (t == PT_INT) return 1;
    if (t == PT_FLOAT) return 2;
    if (t == PT_STRING) return 3;
    if (t == PT_BOOL) return 4;
    if (t == PT_NULL) return 5;
    if (t == PT_ARR) return 7;
    if (t == PT_OBJ) return 8;
    return 6;
}
i64 ph_fr_push(uptr fname, uptr cls, i64 ty, uptr av, i64 na, i64 line, uptr fl) {
    if (ph_ext) return 0;
    if (na > 0 && ph_had_spread) na = 0;      // a spread's values are the array's: not kept
    i64 i = 0;
    loop {
        if (i >= na) break;
        i64 a = ph_a(av, i);
        i64 at = ph_aty(av, i);
        if (at == PT_PK || at == PT_VOID) { na = i; break; }
        if (nd_kind(a) != N_IDENT && nd_kind(a) != N_INT) {
            i64 tmp = ph_temp(a, ph_mcty(at), "pha_");
            st64(av + i * 24, tmp);
        }
        i = i + 1;
    }
    uptr cs = cls;
    if (!cs) cs = "";
    i64 cn = ph_int(0);
    if (cls) cn = ph_raw(cls, cstrlen(cls));
    u8 pa[48];
    st64(pa, ph_raw(fname, cstrlen(fname)));
    st64(pa + 8, cn);
    st64(pa + 16, ph_int(ty));
    uptr afl = ph_disp(ph_absfile(fl));      // php's frames name the resolved path
    st64(pa + 24, ph_raw(afl, cstrlen(afl)));
    st64(pa + 32, ph_int(line));
    st64(pa + 40, ph_int(na));
    i64 fp = ph_temp(ph_calln("php_fr_push", pa, 6, TY_UPTR), TY_UPTR, "phf_");
    i = 0;
    loop {
        if (i >= na) break;
        i64 a2 = ph_a(av, i);
        i64 at2 = ph_aty(av, i);
        i64 tg = ph_fr_tag(at2);
        i64 vn = ph_tref(a2);
        if (nd_kind(a2) == N_INT) vn = ph_int(nd_val(a2));
        if (tg == 6) vn = ph_to_mixed(vn, at2);
        ph_pending_stmt(ph_fr_st(ph_quiet("st64", 2, ph_bin(ph_tok("+", 1), ph_tref(fp), ph_int(i * 16), TY_UPTR),
                                                 ph_int(tg), 0, 0, TY_VOID)));
        i64 dst = ph_bin(ph_tok("+", 1), ph_tref(fp), ph_int(i * 16 + 8), TY_UPTR);
        if (tg == 2) ph_pending_stmt(ph_fr_st(ph_quiet("stf64", 2, dst, vn, 0, 0, TY_VOID)));
        if (tg != 2) ph_pending_stmt(ph_fr_st(ph_quiet("st64", 2, dst, ph_cast(TY_I64, vn), 0, 0, TY_VOID)));
        i = i + 1;
    }
    return fp;
}

// the call c, run with its frame on the stack: its answer in a temporary,
// then the frame popped. Answers what takes the call's place.
i64 ph_fr_call(i64 c, i64 fp) {
    if (!fp) return c;
    i64 r = 0;
    if (nd_type(c) == TY_VOID) ph_pending_stmt(ph_fr_st(c));
    if (nd_type(c) != TY_VOID) r = ph_temp(c, nd_type(c), "phfr_");
    ph_pending_stmt(ph_fr_st(ph_quiet("php_fr_pop", 0, 0, 0, 0, 0, TY_VOID)));
    if (!r) return ph_int(0);
    return ph_tref(r);
}

// Does a call's argument list go through a caller-side coercion (the check
// in ph_builtin below, the same condition)? Those arguments are temporaries
// computed AHEAD of the expression, with the check that refuses one, and a
// TypeError's trace has the call it refused on top -- so that frame is opened
// there too (ph_fr_push). Every other call opens it in place (ph_fr_wrap).
i64 ph_fr_coerces(i64 fi, uptr av, i64 na, i64 np, i64 vararg) {
    i64 i = 0;
    loop {
        if (i >= np || i >= na) break;
        i64 fo = ld64(ph_fopt + (fi * PH_MAXP + i) * 8);
        i64 want = ld64(ph_fpt + (fi * PH_MAXP + i) * 8);
        if (fo != 1 && !(vararg && i == np - 1) && ph_aty(av, i) != want
            && (want == PT_INT || want == PT_FLOAT || want == PT_STRING || want == PT_BOOL)) return 1;
        // a native ?int checks anything but an int or null (ph_ptcheck below)
        if (fo == 1 && ph_aty(av, i) != PT_INT && ph_aty(av, i) != PT_NULL) return 1;
        i = i + 1;
    }
    return 0;
}

// one argument of the call c recorded in its frame as it is computed: the
// value node wrapped, its type kept (a float through its own wrapper, since a
// cast would convert it)
i64 ph_fr_arg(i64 v, i64 tag, i64 k, i64 last) {
    i64 t = nd_type(v);
    if (t == ty_f64) return ph_quiet("php_faf", 3, v, ph_int(k), ph_int(last), 0, ty_f64);
    return ph_cast(t, ph_quiet("php_fa", 4, ph_cast(TY_I64, v), ph_int(tag), ph_int(k), ph_int(last), TY_I64));
}

// the user call c with its frame built where php builds it: opened before the
// arguments, each argument stored as it is computed, popped after the call --
// one expression, so nothing around the call moves (a temporary ahead of the
// statement would run the call before its left-hand neighbours). Only the
// arguments the caller PASSED are shown, as php shows them.
i64 ph_fr_wrap(i64 c, uptr name, i64 fi, i64 na, i64 np, i64 vararg, i64 line, uptr fl) {
    if (ph_ext) return c;
    i64 n = 0;
    if (!ph_had_spread) {
        loop {
            if (n >= np || n >= na) break;
            i64 w0 = ld64(ph_fpt + (fi * PH_MAXP + n) * 8);
            if (w0 == PT_PK || w0 == PT_VOID) break;
            n = n + 1;
        }
    }
    i64 prev = 0;
    i64 cur = nd_a(c);
    i64 i = 0;
    loop {
        if (i >= n || !cur) break;
        i64 fo = ld64(ph_fopt + (fi * PH_MAXP + i) * 8);
        i64 want = ld64(ph_fpt + (fi * PH_MAXP + i) * 8);
        i64 tag = ph_fr_tag(want);
        if (vararg && i == np - 1) tag = 9;
        i64 two = fo == 1 || fo == 2;          // the value and a null flag (or a literal 0)
        i64 last = i == n - 1;
        i64 nx = nd_next(cur);
        set_nd_next(cur, 0);
        i64 w = ph_fr_arg(cur, tag, i, last && !(fo == 1));
        if (prev) set_nd_next(prev, w);
        if (!prev) set_nd_a(c, w);
        prev = w;
        if (two && nx) {
            i64 fx = nd_next(nx);
            set_nd_next(nx, 0);
            i64 fw = nx;
            if (fo == 1) fw = ph_cast(TY_U8, ph_quiet("php_fa_null", 3, ph_cast(TY_I64, nx), ph_int(i), ph_int(last), 0, TY_I64));
            set_nd_next(prev, fw);
            prev = fw;
            nx = fx;
        }
        set_nd_next(prev, nx);
        cur = nx;
        i = i + 1;
    }
    uptr afl = ph_disp(ph_absfile(fl));      // php's frames name the resolved path
    i64 open = ph_quiet("php_fr_open", 4, ph_raw(name, cstrlen(name)), ph_raw(afl, cstrlen(afl)),
                        ph_int(line), ph_int(n), TY_I64);
    i64 ct = nd_type(c);
    if (ct == ty_f64) return ph_quiet("php_frvf", 2, open, c, 0, 0, ty_f64);
    return ph_cast(ct, ph_quiet("php_frv", 2, open, ph_cast(TY_I64, c), 0, 0, TY_I64));
}

// a static property written: php_sprop_set_k answers the slot
i64 ph_sprop_set(i64 ce, uptr sp, i64 v, i64 kind) {
    u8 a[40];
    st64(a, ce);
    st64(a + 8, ph_strlit(sp, cstrlen(sp)));
    st64(a + 16, ph_scope());
    st64(a + 24, v);
    st64(a + 32, ph_int(kind));
    return ph_calln("php_sprop_set_k", a, 5, ty_pzv);
}

// five argument nodes as the array ph_calln takes
uptr ph_zpp_five(i64 a, i64 b, i64 c, i64 d, i64 e) {
    uptr r = xalloc(40);
    st64(r, a);
    st64(r + 8, b);
    st64(r + 16, c);
    st64(r + 24, d);
    st64(r + 32, e);
    return r;
}

// ---- a builtin that calls back into the program ----------------------------
// php runs array_map's callback from INSIDE array_map: the trace has the
// builtin's frame, with its arguments, and the callback's frame above it has
// no file of its own -- `#0 [internal function]: f(2)` (lib/php_rt.mc
// php_fr_push). The builtins that call their callback before they return:
i64 ph_calls_back(uptr n) {
    return str_eq(n, "array_map") || str_eq(n, "array_filter") || str_eq(n, "array_reduce")
        || str_eq(n, "usort") || str_eq(n, "uasort") || str_eq(n, "uksort");
}

// the call c (a library row's: zval arguments, the first na of them passed)
// with the builtin's own frame around it, the way a user call has one
i64 ph_fr_internal(i64 c, uptr name, i64 na, i64 line, uptr fl) {
    if (ph_ext) return c;
    i64 ct = nd_type(c);
    if (ct == TY_VOID) return c;
    i64 prev = 0;
    i64 cur = nd_a(c);
    i64 i = 0;
    loop {
        if (i >= na || !cur) break;
        i64 nx = nd_next(cur);
        set_nd_next(cur, 0);
        i64 w = ph_fr_arg(cur, 6, i, i == na - 1);
        set_nd_next(w, nx);
        if (prev) set_nd_next(prev, w);
        if (!prev) set_nd_a(c, w);
        prev = w;
        cur = nx;
        i = i + 1;
    }
    uptr afl = ph_disp(ph_absfile(fl));
    i64 open = ph_quiet("php_fr_open_i", 4, ph_raw(name, cstrlen(name)), ph_raw(afl, cstrlen(afl)),
                        ph_int(line), ph_int(na), TY_I64);
    if (ct == ty_f64) return ph_quiet("php_frvf", 2, open, c, 0, 0, ty_f64);
    return ph_cast(ct, ph_quiet("php_frv", 2, open, ph_cast(TY_I64, c), 0, 0, TY_I64));
}

// ---- a builtin's arguments against the parameters php declares -------------
// php's ZPP (lib/php_rt.mc php_zpp): every builtin with a stub row
// (src/arginfo.mc) has each argument checked against its declared parameter,
// in one place, before the builtin's own lowering converts it. The argument's
// STATIC type decides almost always: one the parameter takes, or one weak mode
// converts silently (an int to a string), costs nothing. What remains -- an
// array to a scalar, null to a non-nullable one, a float or a string to an
// int, anything the caller's strict_types refuses -- is checked at run time,
// and a mixed argument is checked only when its tag is not one the parameter
// takes as it is. The builtin is php's innermost frame while that runs, with
// the arguments as they were passed; a builtin php compiles to an opcode
// (strlen, count, ...) has no frame of its own.
#define ZP_S      1
#define ZP_L      2
#define ZP_D      4
#define ZP_B      8
#define ZP_A      16
#define ZP_N      32
#define ZP_O      64
#define ZP_STRICT 128

// the ZP_* mask of one stub type: `?string`, `int|float`, `Countable|array`
i64 ph_zpp_mask(uptr t, i64 n) {
    i64 m = 0;
    i64 i = 0;
    if (n > 0 && ld8(t) == '?') { m = ZP_N; i = 1; }
    loop {
        if (i >= n) break;
        i64 j = i;
        loop { if (j >= n || ld8(t + j) == '|') break; j = j + 1; }
        uptr w = xstrdup(t + i, j - i);
        if (str_eq(w, "string")) m = m | ZP_S;
        if (str_eq(w, "int"))    m = m | ZP_L;
        if (str_eq(w, "float"))  m = m | ZP_D;
        if (str_eq(w, "bool"))   m = m | ZP_B;
        if (str_eq(w, "array"))  m = m | ZP_A;
        if (str_eq(w, "null"))   m = m | ZP_N;
        if (ld8(w) >= 'A' && ld8(w) <= 'Z') m = m | ZP_O;
        i = j + 1;
    }
    return m;
}

// does the static type `have` need the run-time check against mask m?
// 0 no, 1 always, 2 only when the zval's tag is not one m takes as it is
i64 ph_zpp_need(i64 have, i64 m) {
    i64 strict = m & ZP_STRICT;
    if (have == PT_MIXED) return 2;
    if (have == PT_STRING) {
        if (m & ZP_S) return 0;
        if (strict) return 1;
        if (m & (ZP_L | ZP_D)) return 1;
        if (m & ZP_B) return 0;
        return 1;
    }
    if (have == PT_INT) {
        if (m & (ZP_L | ZP_D)) return 0;
        if (strict) return 1;
        if (m & (ZP_S | ZP_B)) return 0;
        return 1;
    }
    if (have == PT_IFALSE) {
        if ((m & (ZP_L | ZP_D | ZP_S | ZP_B)) && !strict) return 0;
        return 1;
    }
    if (have == PT_FLOAT) {
        if (m & ZP_D) return 0;
        if (strict) return 1;
        if (m & ZP_L) return 1;
        if (m & (ZP_S | ZP_B)) return 0;
        return 1;
    }
    if (have == PT_BOOL) {
        if (m & ZP_B) return 0;
        if (strict) return 1;
        if (m & (ZP_S | ZP_L | ZP_D)) return 0;
        return 1;
    }
    if (have == PT_NULL) { if (m & ZP_N) return 0; return 1; }
    if (have == PT_ARR) { if (m & ZP_A) return 0; return 1; }
    if (have == PT_OBJ) { if (m & ZP_O) return 0; return 1; }
    return 0;
}

// the zval tags m takes as they are, as a test on the local `tn` (the tag)
i64 ph_zpp_tagok(i64 m, uptr tn, i64 line, uptr fl) {
    u8 tags[96];
    i64 nt = 0;
    if (m & ZP_S) { st64(tags + nt * 8, 6); nt = nt + 1; }
    if (m & ZP_L) { st64(tags + nt * 8, 4); nt = nt + 1; }
    if (m & ZP_D) { st64(tags + nt * 8, 5); nt = nt + 1; }
    if ((m & ZP_D) && !(m & ZP_L)) { st64(tags + nt * 8, 4); nt = nt + 1; }
    if (m & ZP_B) { st64(tags + nt * 8, 2); st64(tags + nt * 8 + 8, 3); nt = nt + 2; }
    if (m & ZP_A) { st64(tags + nt * 8, 7); nt = nt + 1; }
    if (m & ZP_N) { st64(tags + nt * 8, 1); nt = nt + 1; }
    // an object is never taken by its tag alone: only the named classes are
    i64 acc = 0;
    i64 i = 0;
    loop {
        if (i >= nt) break;
        i64 tg = node_new(N_IDENT, line, fl);
        set_nd_name(tg, tn);
        set_nd_type(tg, TY_I64);
        i64 eq = ph_bin(ph_tok("==", 2), tg, ph_int(ld64(tags + i * 8)), TY_U8);
        if (!acc) acc = eq;
        if (acc != eq) acc = ph_bin(ph_tok("||", 2), acc, eq, TY_U8);
        i = i + 1;
    }
    if (!acc) acc = ph_bool(0);
    return acc;
}

uptr ph_zpp_local(uptr pfx, i64 mcty) {
    ph_nonce = ph_nonce + 1;
    uptr tn = p_cat(pfx, php_dec(ph_nonce), 0, cstrlen(php_dec(ph_nonce)));
    ph_local(tn, mcty);
    return tn;
}

i64 ph_zpp_ref(uptr tn, i64 mcty, i64 line, uptr fl) {
    i64 r = node_new(N_IDENT, line, fl);
    set_nd_name(r, tn);
    set_nd_type(r, mcty);
    return r;
}

void ph_zpp_args(uptr name, uptr av, i64 na, i64 line, uptr fl, i64 noframe) {
    uptr spec = ph_arginfo(name);
    // php compiles implode() with two arguments to its FRAMELESS form, whose
    // own parsing takes the separator as a string: an array there is refused
    // before the second argument is looked at (ext/standard/string.c)
    if (str_eq(name, "implode") && na == 2) spec = "string:separator;?array:array";
    if (!spec || na > 16) return;
    i64 strict = 0;
    if (ph_strict_bit(fl)) strict = ZP_STRICT;
    // each argument's parameter: its mask, name and type text, from the row
    u8 pm[136];
    u8 pnm[136];
    u8 ptn[136];
    i64 i = 0;
    uptr p = spec;
    i64 vm = -1;
    uptr vtn = 0;
    loop {
        if (i >= na) break;
        if (vm >= 0) { st64(pm + i * 8, vm); st64(pnm + i * 8, ""); st64(ptn + i * 8, vtn); i = i + 1; continue; }
        if (!ld8(p)) { st64(pm + i * 8, 0); i = i + 1; continue; }
        i64 var = ld8(p) == '*';
        if (var) p = p + 1;
        uptr c = p;
        loop { if (ld8(c) == ':') break; c = c + 1; }
        uptr e = c + 1;
        loop { if (!ld8(e) || ld8(e) == ';') break; e = e + 1; }
        i64 m = 0;
        uptr tn = xstrdup(p, c - p);
        // a callback is not ZPP's to check here; one spelled as a string is
        // what D6 refuses -- nothing dispatches on a string -- and it is
        // refused by name rather than failing as "Value not callable"
        i64 cb = str_eq(tn, "callable") || str_eq(tn, "?callable");
        if (cb && ph_aty(av, i) == PT_STRING) ph_refuse(fl, line, "a callable spelled as a string", "D6");
        if (!str_eq(tn, "-") && !cb) m = ph_zpp_mask(p, c - p);
        if (m) m = m | strict;
        st64(pm + i * 8, m);
        st64(pnm + i * 8, xstrdup(c + 1, e - c - 1));
        st64(ptn + i * 8, tn);
        if (var) { vm = m; vtn = tn; }
        p = e;
        if (ld8(p)) p = p + 1;
        i = i + 1;
    }
    // ord($s[$i]) reads the BYTE (ph_read_args): its argument is a string's
    if (ph_argbyte_done && na > 0) st64(pm, 0);
    i64 always = 0;
    i64 some = 0;
    i = 0;
    loop {
        if (i >= na) break;
        i64 m = ld64(pm + i * 8);
        i64 nd = 0;
        if (m) nd = ph_zpp_need(ph_aty(av, i), m);
        if (nd == 2 && (m & ZP_S) && ph_is_narrowed(ph_a(av, i), PT_STRING)) nd = 0;
        if (nd == 2 && (m & ZP_L) && ph_is_narrowed(ph_a(av, i), PT_INT)) nd = 0;
        st64(pm + i * 8, m | (nd << 16));
        if (nd == 1) always = 1;
        if (nd) some = 1;
        i = i + 1;
    }
    if (!some) return;
    // every argument computed once, in order, before any of them is checked
    i = 0;
    loop {
        if (i >= na) break;
        i64 a = ph_a(av, i);
        if (nd_kind(a) != N_IDENT && nd_kind(a) != N_INT)
            st64(av + i * 24, ph_temp(a, ph_mcty(ph_aty(av, i)), "phz_"));
        i = i + 1;
    }
    i64 head = 0;
    i64 tail = 0;
    uptr fp = 0;
    if (!noframe && !ph_ext) {
        fp = ph_zpp_local("phzf_", TY_UPTR);
        uptr afl = ph_disp(ph_absfile(fl));
        u8 pa[48];
        st64(pa, ph_raw(name, cstrlen(name)));
        st64(pa + 8, ph_int(0));
        st64(pa + 16, ph_int(0));
        st64(pa + 24, ph_raw(afl, cstrlen(afl)));
        st64(pa + 32, ph_int(line));
        st64(pa + 40, ph_int(na));
        head = ph_set(fp, ph_calln("php_fr_push", pa, 6, TY_UPTR));
        tail = head;
        i = 0;
        loop {
            if (i >= na) break;
            i64 a2 = ph_a(av, i);
            i64 at2 = ph_aty(av, i);
            i64 tg = ph_fr_tag(at2);
            i64 vn = ph_tref(a2);
            if (nd_kind(a2) == N_INT) vn = ph_int(nd_val(a2));
            if (tg == 6) vn = ph_to_mixed(vn, at2);
            i64 s1 = ph_fr_st(ph_quiet("st64", 2, ph_bin(ph_tok("+", 1), ph_zpp_ref(fp, TY_UPTR, line, fl), ph_int(i * 16), TY_UPTR),
                                       ph_int(tg), 0, 0, TY_VOID));
            i64 dst = ph_bin(ph_tok("+", 1), ph_zpp_ref(fp, TY_UPTR, line, fl), ph_int(i * 16 + 8), TY_UPTR);
            i64 s2 = 0;
            if (tg == 2) s2 = ph_fr_st(ph_quiet("stf64", 2, dst, vn, 0, 0, TY_VOID));
            if (tg != 2) s2 = ph_fr_st(ph_quiet("st64", 2, dst, ph_cast(TY_I64, vn), 0, 0, TY_VOID));
            set_nd_next(s1, s2);
            set_nd_next(tail, s1);
            tail = s2;
            i = i + 1;
        }
    }
    i64 cond = 0;
    i = 0;
    loop {
        if (i >= na) break;
        i64 m = ld64(pm + i * 8);
        i64 nd = m >> 16;
        m = m & 65535;
        if (nd) {
            i64 a3 = ph_a(av, i);
            uptr pn = ld64(pnm + i * 8);
            uptr tn = ld64(ptn + i * 8);
            u8 za[48];
            i64 a3v = ph_tref(a3);
            if (nd_kind(a3) == N_INT) a3v = ph_int(nd_val(a3));
            st64(za, ph_to_mixed(a3v, ph_aty(av, i)));
            st64(za + 8, ph_int(m));
            st64(za + 16, ph_raw(name, cstrlen(name)));
            st64(za + 24, ph_int(i + 1));
            st64(za + 32, ph_raw(pn, cstrlen(pn)));
            st64(za + 40, ph_raw(tn, cstrlen(tn)));
            i64 cs = ph_fr_st(ph_calln("php_zpp", za, 6, TY_I64));
            if (tail) set_nd_next(tail, cs);
            if (!head) head = cs;
            tail = cs;
            if (nd == 2) {
                uptr tg = ph_zpp_local("phzt_", TY_I64);
                ph_pending_stmt(ph_set(tg, ph_quiet("ld8", 1, ph_bin(ph_tok("+", 1), ph_tref(a3), ph_int(8), TY_UPTR), 0, 0, 0, TY_I64)));
                i64 bad = node_new(N_UNARY, line, fl);
                set_nd_op(bad, ph_tok("!", 1));
                set_nd_a(bad, ph_zpp_tagok(m, tg, line, fl));
                set_nd_type(bad, TY_U8);
                if (!cond) cond = bad;
                if (cond != bad) cond = ph_bin(ph_tok("||", 2), cond, bad, TY_U8);
            }
        }
        i = i + 1;
    }
    if (fp) {
        i64 pop = ph_fr_st(ph_quiet("php_fr_pop", 0, 0, 0, 0, 0, TY_VOID));
        set_nd_next(tail, pop);
        tail = pop;
    }
    i64 blk = node_new(N_BLOCK, line, fl);
    set_nd_a(blk, head);
    if (always || !cond) ph_pending_stmt(blk);
    if (!always && cond) {
        i64 iff = node_new(N_IF, line, fl);
        set_nd_a(iff, cond);
        set_nd_b(iff, blk);
        ph_pending_stmt(iff);
    }
    ph_pending_stmt(ph_check(line, fl));
}

// a and b equal, ASCII case folded (php's class and function names)
i64 ph_ci_eq(uptr a, uptr b) {
    i64 i = 0;
    loop {
        i64 x = ld8(a + i);
        i64 y = ld8(b + i);
        if (x >= 65 && x <= 90) x = x + 32;
        if (y >= 65 && y <= 90) y = y + 32;
        if (x != y) return 0;
        if (!x) return 1;
        i = i + 1;
    }
    return 0;
}

// `f($a, ...$rest)` for a builtin: its implementation is lowered for a count
// of arguments known while compiling, and a spread's count is not. So the
// call is dispatched on that count, each arm the call written out
// (`match (count($t = [...$rest])) { 0 => f($a), 1 => f($a, $t[0]), ... }`),
// parsed from that text where the call stands; a count php refuses is its
// ArgumentCountError, one past what the implementation takes mc-php's named
// limit. The arguments before the first spread stay as written, so a
// by-reference one (array_push's) is still the caller's variable. Answers 0
// (nothing consumed) when the call has no spread or the arity is not known.
i64 ph_spread_call(uptr raw, uptr name, i64 line, uptr fl) {
    uptr src = p_cp();
    uptr e = p_src_end();
    i64 len = e - src;
    i64 i = 0;
    loop { if (i >= len || !ph_space(ld8(src + i))) break; i = i + 1; }
    if (i >= len || ld8(src + i) != 40) return 0;
    i64 open = i;
    i = i + 1;
    i64 dp = 0;
    i64 argst = i;
    i64 nargs = 0;
    i64 first = 0 - 1;              // the first spread argument's index
    i64 fstart = 0;                 // and where it starts
    i64 close = 0 - 1;
    loop {
        if (i >= len) return 0;
        i64 h = ph_scan_hop(src, len, i);
        if (h != i) { i = h; continue; }
        i64 c = ld8(src + i);
        if (dp == 0 && (c == 44 || c == 41)) {
            // one argument ends: does it start with `...`?
            i64 k = argst;
            loop { if (k >= i || !ph_space(ld8(src + k))) break; k = k + 1; }
            if (k < i) {
                if (first < 0 && k + 2 < i && ld8(src + k) == 46 && ld8(src + k + 1) == 46 && ld8(src + k + 2) == 46) {
                    first = nargs;
                    fstart = k;
                }
                nargs = nargs + 1;
            }
            if (c == 41) { close = i; break; }
            argst = i + 1;
            i = i + 1;
            continue;
        }
        if (c == 40 || c == 91 || c == 123) dp = dp + 1;
        if (c == 41 || c == 93 || c == 125) dp = dp - 1;
        i = i + 1;
    }
    if (first < 0) return 0;
    uptr ac = ph_argn(name);
    if (!ac) return 0;
    i64 mn = 0;
    i64 j = 0;
    loop { if (ld8(ac + j) == 58) break; mn = mn * 10 + ld8(ac + j) - 48; j = j + 1; }
    j = j + 1;
    i64 mx = 0 - 1;
    if (ld8(ac + j) != 45) { mx = 0; loop { if (!ld8(ac + j)) break; mx = mx * 10 + ld8(ac + j) - 48; j = j + 1; } }
    // the most the implementation takes: its library row, else php's own
    i64 cap = mx;
    i64 lmn = mn;
    i64 li = ph_lib_find(name);
    if (li >= 0) { cap = ld64(ph_lmax + li * 8); lmn = ld64(ph_lmin + li * 8); }
    // a variadic builtin with no row lowers a spread itself (max, sprintf)
    if (cap < 0) return 0;
    if (mx >= 0 && cap > mx) cap = mx;
    // the text: LEAD is the arguments before the first spread, REST the rest
    i64 le = fstart;
    loop { if (le <= open + 1) break; i64 lc = ld8(src + le - 1); if (lc == 44 || ph_space(lc)) { le = le - 1; continue; } break; }
    uptr lead = xstrdup(src + open + 1, le - open - 1);
    uptr rest = xstrdup(src + fstart, close - fstart);
    ph_nonce = ph_nonce + 1;
    uptr tn = p_cat("$phsp_", php_dec(ph_nonce), 0, cstrlen(php_dec(ph_nonce)));
    uptr cn = p_cat(tn, "_n", 0, 2);
    uptr t = "";
    i64 k2 = 1;
    loop { if (k2 >= line) break; t = p_cat(t, "\n", 0, 1); k2 = k2 + 1; }
    t = p_cat(t, "(match (", 0, 8);
    t = p_cat(t, cn, 0, cstrlen(cn));
    t = p_cat(t, " = ", 0, 3);
    t = p_cat(t, php_dec(first), 0, cstrlen(php_dec(first)));
    t = p_cat(t, " + count(", 0, 9);
    t = p_cat(t, tn, 0, cstrlen(tn));
    t = p_cat(t, " = [", 0, 4);
    t = p_cat(t, rest, 0, cstrlen(rest));
    t = p_cat(t, "])) {", 0, 5);
    i64 cnt = first;
    if (cnt < mn) cnt = mn;
    if (cnt < lmn) cnt = lmn;
    loop {
        if (cnt > cap) break;
        t = p_cat(t, php_dec(cnt), 0, cstrlen(php_dec(cnt)));
        t = p_cat(t, " => ", 0, 4);
        t = p_cat(t, raw, 0, cstrlen(raw));
        t = p_cat(t, "(", 0, 1);
        t = p_cat(t, lead, 0, cstrlen(lead));
        i64 q = 0;
        loop {
            if (first + q >= cnt) break;
            if (first + q > 0) t = p_cat(t, ", ", 0, 2);
            t = p_cat(t, tn, 0, cstrlen(tn));
            t = p_cat(t, "[", 0, 1);
            t = p_cat(t, php_dec(q), 0, cstrlen(php_dec(q)));
            t = p_cat(t, "]", 0, 1);
            q = q + 1;
        }
        t = p_cat(t, "), ", 0, 3);
        cnt = cnt + 1;
    }
    // php's ArgumentCountError for a count it refuses (zend_wrong_parameters_
    // count_error), mc-php's limit past the implementation
    uptr arg1 = "s";
    t = p_cat(t, "default => ", 0, 11);
    if (mx >= 0 && cap >= mx) {
        uptr wd = "at most ";
        if (mn == mx) wd = "exactly ";
        uptr nn = php_dec(mx);
        if (mx == 1) arg1 = "";
        uptr msg = p_cat(p_cat(p_cat(name, "() expects ", 0, 11), wd, 0, cstrlen(wd)), nn, 0, cstrlen(nn));
        msg = p_cat(p_cat(msg, " argument", 0, 9), arg1, 0, cstrlen(arg1));
        uptr ms2 = p_cat(name, "() expects at least ", 0, 20);
        ms2 = p_cat(ms2, php_dec(mn), 0, cstrlen(php_dec(mn)));
        ms2 = p_cat(ms2, " argument", 0, 9);
        if (mn != 1) ms2 = p_cat(ms2, "s", 0, 1);
        t = p_cat(t, "throw new ArgumentCountError((", 0, 30);
        t = p_cat(t, cn, 0, cstrlen(cn));
        t = p_cat(t, " < ", 0, 3);
        t = p_cat(t, php_dec(mn), 0, cstrlen(php_dec(mn)));
        t = p_cat(t, " && ", 0, 4);
        t = p_cat(t, php_dec(mn), 0, cstrlen(php_dec(mn)));
        t = p_cat(t, " != ", 0, 4);
        t = p_cat(t, php_dec(mx), 0, cstrlen(php_dec(mx)));
        t = p_cat(t, " ? '", 0, 4);
        t = p_cat(t, ms2, 0, cstrlen(ms2));
        t = p_cat(t, "' : '", 0, 5);
        t = p_cat(t, msg, 0, cstrlen(msg));
        t = p_cat(t, "') . ', ' . ", 0, 12);
        t = p_cat(t, cn, 0, cstrlen(cn));
        t = p_cat(t, " . ' given')", 0, 12);
    } else if (mn > 0) {
        uptr ms3 = p_cat(name, "() expects at least ", 0, 20);
        ms3 = p_cat(ms3, php_dec(mn), 0, cstrlen(php_dec(mn)));
        ms3 = p_cat(ms3, " argument", 0, 9);
        if (mn != 1) ms3 = p_cat(ms3, "s", 0, 1);
        t = p_cat(t, cn, 0, cstrlen(cn));
        t = p_cat(t, " < ", 0, 3);
        t = p_cat(t, php_dec(mn), 0, cstrlen(php_dec(mn)));
        t = p_cat(t, " ? throw new ArgumentCountError('", 0, 33);
        t = p_cat(t, ms3, 0, cstrlen(ms3));
        t = p_cat(t, ", ' . ", 0, 6);
        t = p_cat(t, cn, 0, cstrlen(cn));
        t = p_cat(t, " . ' given') : __mcphp_spread_cap('", 0, 36);
        t = p_cat(t, name, 0, cstrlen(name));
        t = p_cat(t, "', ", 0, 3);
        t = p_cat(t, cn, 0, cstrlen(cn));
        t = p_cat(t, ")", 0, 1);
    } else {
        t = p_cat(t, "__mcphp_spread_cap('", 0, 20);
        t = p_cat(t, name, 0, cstrlen(name));
        t = p_cat(t, "', ", 0, 3);
        t = p_cat(t, cn, 0, cstrlen(cn));
        t = p_cat(t, ")", 0, 1);
    }
    t = p_cat(t, "})", 0, 2);
    p_skip_to(src + close + 1);
    ph_pushing = 1;
    p_push_source(fl, t, cstrlen(t));
    ph_pushing = 0;
    ph_nopeek = 1;
    ph_next();
    return ph_primary();
}

i64 ph_builtin(uptr name, i64 line, uptr fl) {
    // the name as written, resolved (src/ns.mc): as a function here, as a
    // constant where one is looked up, as a class before `::`. Outside a
    // namespace and unqualified, all three are the name itself.
    uptr raw = name;
    // `f(...)`: a first-class callable (php 8.1) -- the closure
    // `fn(...$a) => f(...$a)`, parsed from that text where the call stands,
    // at the same line, so it names and resolves f exactly as the call would
    {
        uptr q = p_cp();
        uptr e = p_src_end();
        loop { if (q >= e || !ph_space(ld8(q))) break; q = q + 1; }
        if (q < e && ld8(q) == 40) {
            q = q + 1;
            loop { if (q >= e || !ph_space(ld8(q))) break; q = q + 1; }
            if (q + 2 < e && ld8(q) == 46 && ld8(q + 1) == 46 && ld8(q + 2) == 46) {
                q = q + 3;
                loop { if (q >= e || !ph_space(ld8(q))) break; q = q + 1; }
                if (q < e && ld8(q) == 41) {
                    if (str_eq(raw, "new") || str_eq(raw, "isset") || str_eq(raw, "empty") || str_eq(raw, "unset") || str_eq(raw, "list"))
                        err_at(fl, line, "mc-php: cannot create a closure here");
                    ph_nonce = ph_nonce + 1;
                    uptr an = p_cat("$phfcc_", php_dec(ph_nonce), 0, cstrlen(php_dec(ph_nonce)));
                    uptr txt = "";
                    i64 k = 1;
                    loop { if (k >= line) break; txt = p_cat(txt, "\n", 0, 1); k = k + 1; }
                    txt = p_cat(txt, "(fn(...", 0, 7);
                    txt = p_cat(txt, an, 0, cstrlen(an));
                    txt = p_cat(txt, ") => ", 0, 5);
                    txt = p_cat(txt, raw, 0, cstrlen(raw));
                    txt = p_cat(txt, "(...", 0, 4);
                    txt = p_cat(txt, an, 0, cstrlen(an));
                    txt = p_cat(txt, "))", 0, 2);
                    p_skip_to(q + 1);
                    ph_pushing = 1;
                    p_push_source(fl, txt, cstrlen(txt));
                    ph_pushing = 0;
                    ph_nopeek = 1;
                    ph_next();
                    i64 cv = ph_primary();
                    ph_ety = PT_MIXED;
                    // no frame of its own: a call through it shows f's
                    return ph_c1("php_fcc_anon", ph_to_mixed(cv, PT_MIXED), ty_pzv);
                }
            }
        }
    }
    u8 fbb[8];
    name = ph_ns_fc(raw, 0, fbb);
    // a spread into a builtin (not a function this program declares)
    if (ph_fn_find0(name) < 0) {
        i64 sc = ph_spread_call(raw, name, line, fl);
        if (sc) return sc;
    }
    u8 cfb[8];
    uptr cnm = ph_ns_fc(raw, 1, cfb);
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
    if (str_eq(name, "__NAMESPACE__")) {
        uptr nsn = ph_ns_cur();
        ph_next();
        ph_ety = PT_STRING;
        return ph_strlit(nsn, cstrlen(nsn));
    }
    if (str_eq(name, "__CLASS__")) {
        ph_next();
        ph_ety = PT_STRING;
        if (!ph_cur_cls) return ph_strlit("", 0);
        return ph_strlit(ph_cur_cls, cstrlen(ph_cur_cls));
    }
    // a constant this program declared with `const` or define()
    i64 ci = ph_const_find(cnm);
    if (ci >= 0) {
        ph_next();
        i64 ct = ld64(ph_cty + ci * 8);
        if (ct < 0) { ph_ety = PT_MIXED; return ph_c1("php_const_get", ph_strlit(cnm, cstrlen(cnm)), ty_pzv); }
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
                // a native nullable scalar (src/decl.mc): isset is "not null"
                // (its u8 flag is 0), empty is "null or the value is falsy". A
                // chained isset($s[...]) would have refused on the int above.
                i64 optf = 0;
                if (t == PT_INT && ph_is_opt(d)) {
                    optf = node_new(N_IDENT, line, fl);
                    set_nd_name(optf, ph_vflag(d));
                    set_nd_type(optf, TY_U8);
                }
                if (optf && !isempty) one = ph_cast(TY_U8, ph_bin(ph_tok("==", 2), optf, ph_int(0), TY_U8));
                if (optf && isempty) one = ph_cast(TY_U8, ph_bin(ph_tok("||", 2), optf, ph_bin(ph_tok("==", 2), v, ph_int(0), TY_U8), TY_U8));
                if (!optf && !isempty) {
                    if (t == PT_INT)   one = ph_cast(TY_U8, ph_bin(ph_tok("!=", 2), v, ph_int(0), TY_U8));
                    if (t == PT_MIXED) one = ph_cast(TY_U8, ph_c1("php_zv_isset", v, TY_I64));
                    if (t != PT_INT && t != PT_MIXED) one = ph_bool(1);
                }
                if (!optf && isempty) {
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
        name = ph_ns_class(raw);
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
            // a static property is a zval SLOT, read through php_sprop_get
            // (an uninitialized typed one is php's Error) and written through
            // php_sprop_set_k, which checks its declared type; each use names
            // the class again, since one node cannot be in two argument lists
            ph_ety = PT_MIXED;
            i64 op = 0;
            if (ph_at(".=", 2))  op = ph_tok(".", 1);
            if (ph_at("+=", 2))  op = ph_tok("+", 1);
            if (ph_at("-=", 2))  op = ph_tok("-", 1);
            if (ph_at("*=", 2))  op = ph_tok("*", 1);
            if (ph_at("/=", 2))  op = ph_tok("/", 1);
            if (ph_at("%=", 2))  op = ph_tok("%", 1);
            i64 rd = ph_c3("php_sprop_get", ce, ph_strlit(sp, cstrlen(sp)), ph_scope(), ty_pzv);
            if (ph_at("++", 2) || ph_at("--", 2)) {
                uptr f = "php_zv_inc";
                i64 ik = 1;
                if (ph_at("--", 2)) { f = "php_zv_dec"; ik = 2; }
                ph_next();
                // the expression's value is the OLD one: a copy, taken first
                i64 t2 = ph_temp(ph_c1("php_zv_val", rd, ty_pzv), ty_pzv, "phs_");
                ph_pending_stmt(ph_expr_stmt_of(ph_sprop_set(ph_ce_of(name, fl, line), sp, ph_c1(f, ph_tref(t2), ty_pzv),
                                                             ph_pset_kind(ik, fl))));
                return ph_tref(t2);
            }
            if (op) {
                ph_next();
                i64 r = ph_expr(0);
                i64 rt = ph_ety;
                i64 v = 0;
                if (op == ph_tok(".", 1)) v = ph_c2("php_zv_concat", rd, ph_to_mixed(r, rt), ty_pzv);
                if (op != ph_tok(".", 1)) v = ph_arith_zv(op, rd, PT_MIXED, r, rt);
                ph_ety = PT_MIXED;
                return ph_c1("php_zv_val", ph_sprop_set(ph_ce_of(name, fl, line), sp, v, ph_pset_kind(0, fl)), ty_pzv);
            }
            if (ph_at("=", 1)) {
                ph_next();
                i64 r2 = ph_expr(0);
                i64 v2 = ph_to_mixed(ph_own(r2, ph_ety), ph_ety);
                ph_ety = PT_MIXED;
                // the value is the slot's at THIS point, not whatever a later
                // operand of the same expression leaves in it
                return ph_c1("php_zv_val", ph_sprop_set(ph_ce_of(name, fl, line), sp, v2, ph_pset_kind(0, fl)), ty_pzv);
            }
            return rd;
        }
        if (ph_tid != T_IDENT) err_at2(fl, line, "mc-php: a php class member was expected", ph_tname);
        uptr mn = ph_tname;
        i64 mline = ph_tline;                    // php's call line: the method's name
        ph_next();
        // Closure::fromCallable(x): a closure that calls x (lib/php_rt.mc
        // php_fcc); a callable spelled as a string is D6's
        if (ph_at("(", 1) && ph_ci_eq(name, "Closure") && ph_ci_eq(mn, "fromCallable")) {
            u8 fnb[8];
            uptr fav = ph_read_args(1, fl, mline, fnb);
            if (ld64(fnb) != 1) ph_todo2(fl, line, "the wrong number of arguments for", "Closure::fromCallable");
            if (ph_aty(fav, 0) == PT_STRING) ph_refuse(fl, line, "a callable spelled as a string", "D6");
            ph_ety = PT_MIXED;
            return ph_c2("php_fcc", ph_to_mixed(ph_a(fav, 0), ph_aty(fav, 0)), ph_scope(), ty_pzv);
        }
        if (ph_at("(", 1)) return ph_scall_node(ce, mn, fl, mline);
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
    // mcphp_thread(): which php thread runs this call, as a number -- the
    // thread's runtime block (lib/php_zts.mc's phz_tid). A ZTS module's test
    // gate (tests/frankenphp.sh counts the threads a load landed on); it
    // exists in a ZTS output only, and anything else refuses it by name.
    if (str_eq(name, "mcphp_thread")) {
        u8 tnp1[8];
        ph_read_args(1, fl, line, tnp1);
        if (ld64(tnp1) != 0) ph_todo2(fl, line, "the wrong number of arguments for", name);
        if (!ph_ext || !ph_ext_zts) err_at2(fl, line, "mc-php: mcphp_thread() is a ZTS extension's test gate", name);
        ph_ety = PT_INT;
        return ph_call("phz_tid", 0, 0, 0, 0, 0, TY_I64);
    }
    // mcphp_threads('f', $n, $arg): the runtime's own gate of its threads
    // (lib/php_rt.mc § other threads) -- n OS threads, thread i running the
    // compiled f(arg, i), the sum of what they returned. Internal: the public
    // thread API is a later step. f is a function declared above, taking
    // (int, int) and returning int, named by a literal.
    if (str_eq(name, "mcphp_threads")) {
        u8 tnp[8];
        uptr tav = ph_read_args(3, fl, line, tnp);
        if (ld64(tnp) != 3) ph_todo2(fl, line, "the wrong number of arguments for", name);
        uptr tf = ph_alit(tav, 0);
        if (!tf) err_at2(fl, line, "mc-php: mcphp_threads() names its function by a literal", name);
        i64 tfi = ph_fn_find(tf);
        if (tfi < 0 || ld64(ph_fnp + tfi * 8) != 2 || ld64(ph_fret + tfi * 8) != PT_INT
            || ld64(ph_fpt + (tfi * PH_MAXP) * 8) != PT_INT || ld64(ph_fpt + (tfi * PH_MAXP + 1) * 8) != PT_INT
            // a flagged slot (?int, int $x = N) is two mc parameters, not one
            || ld64(ph_fopt + (tfi * PH_MAXP) * 8) || ld64(ph_fopt + (tfi * PH_MAXP + 1) * 8))
            err_at2(fl, line, "mc-php: mcphp_threads() runs a function declared above as f(int, int): int", tf);
        i64 fp = node_new(N_ADDR, line, fl);
        set_nd_name(fp, ph_mangle(ld64(ph_fname + tfi * 8), "f_"));
        set_nd_type(fp, TY_UPTR);
        ph_ety = PT_INT;
        return ph_c3("php_thr_run", fp, ph_to_int(ph_a(tav, 1), ph_aty(tav, 1)),
                     ph_to_int(ph_a(tav, 2), ph_aty(tav, 2)), TY_I64);
    }
    i64 sy = ph_bi_sync(name, line, fl);
    if (sy) return sy;
    i64 as = ph_bi_async(name, line, fl);
    if (as) return as;
    // The thread API (docs/threads.md § Step 3), the primitive layer:
    //   mcphp_thread_start(callable $fn, mixed ...$args): int
    //   mcphp_thread_join(int $t): mixed
    //   mcphp_thread_detach(int $t): void
    //   mcphp_thread_running(): int
    //   mcphp_hardware_concurrency(): int
    // lib/php_rt.mc § the thread API does the work; the arguments go by value.
    if (str_eq(name, "mcphp_thread_start")) {
        u8 snp[8];
        uptr sav = ph_read_args(6, fl, line, snp);
        i64 sn = ld64(snp);
        if (sn < 1) ph_todo2(fl, line, "the wrong number of arguments for", name);
        if (sn > 6) ph_todo2(fl, line, "more than five arguments for a thread in", name);
        i64 c = node_new(N_CALL, line, fl);
        set_nd_name(c, "php_thr_start");
        set_nd_type(c, TY_I64);
        i64 a0 = ph_to_mixed(ph_a(sav, 0), ph_aty(sav, 0));
        set_nd_a(c, a0);
        i64 cnt = ph_int(sn - 1);
        set_nd_next(a0, cnt);
        i64 prev = cnt;
        i64 si = 1;
        loop {
            if (si > 5) break;
            i64 av = ph_int(0);
            if (si < sn) av = ph_to_mixed(ph_a(sav, si), ph_aty(sav, si));
            set_nd_next(prev, av);
            prev = av;
            si = si + 1;
        }
        ph_can_throw = 1;
        ph_ety = PT_INT;
        return c;
    }
    if (str_eq(name, "mcphp_thread_join") || str_eq(name, "mcphp_thread_detach")) {
        u8 jnp[8];
        uptr jav = ph_read_args(1, fl, line, jnp);
        if (ld64(jnp) != 1) ph_todo2(fl, line, "the wrong number of arguments for", name);
        i64 h = ph_to_int(ph_a(jav, 0), ph_aty(jav, 0));
        if (str_eq(name, "mcphp_thread_detach")) { ph_ety = PT_NULL; return ph_c1("php_thr_detach", h, ty_pzv); }
        ph_ety = PT_MIXED;
        return ph_c1("php_thr_join", h, ty_pzv);
    }
    if (str_eq(name, "mcphp_thread_running") || str_eq(name, "mcphp_hardware_concurrency")) {
        u8 rnp[8];
        ph_read_args(1, fl, line, rnp);
        if (ld64(rnp) != 0) ph_todo2(fl, line, "the wrong number of arguments for", name);
        ph_ety = PT_INT;
        if (str_eq(name, "mcphp_thread_running")) return ph_call("php_thr_running", 0, 0, 0, 0, 0, TY_I64);
        return ph_call("ph_os_ncpu", 0, 0, 0, 0, 0, TY_I64);
    }
    // mcphp_shared_mode() and mcphp_str_mine($s): the test gates of shared
    // mode (docs/threads.md § Step 3) -- the flag, and whether the runtime
    // would write $s in place. Internal.
    if (str_eq(name, "mcphp_shared_mode")) {
        u8 mnp[8];
        ph_read_args(1, fl, line, mnp);
        if (ld64(mnp) != 0) ph_todo2(fl, line, "the wrong number of arguments for", name);
        ph_ety = PT_INT;
        return ph_call("php_thr_shared", 0, 0, 0, 0, 0, TY_I64);
    }
    if (str_eq(name, "mcphp_str_mine")) {
        u8 snp2[8];
        uptr sav2 = ph_read_args(1, fl, line, snp2);
        if (ld64(snp2) != 1) ph_todo2(fl, line, "the wrong number of arguments for", name);
        ph_ety = PT_INT;
        return ph_c1("php_thr_mine", ph_to_str(ph_a(sav2, 0), ph_aty(sav2, 0)), TY_I64);
    }
    // mcphp_vm(): the process's virtual size in bytes (committed bytes on
    // Windows), -1 when the host cannot say -- the gate that sees a thread's
    // arena kept after it ends (tests/c/10-threads-vm.php). Internal.
    if (str_eq(name, "mcphp_vm")) {
        u8 vnp[8];
        ph_read_args(1, fl, line, vnp);
        if (ld64(vnp) != 0) ph_todo2(fl, line, "the wrong number of arguments for", name);
        ph_ety = PT_INT;
        return ph_call("ph_os_vm", 0, 0, 0, 0, 0, TY_I64);
    }
    // mcphp_now_ms(): the host's monotonic clock in milliseconds -- the gate
    // that a timeout actually waited (tests/c/17-sync-blocking.php). Internal.
    if (str_eq(name, "mcphp_now_ms")) {
        u8 nnp[8];
        ph_read_args(1, fl, line, nnp);
        if (ld64(nnp) != 0) ph_todo2(fl, line, "the wrong number of arguments for", name);
        ph_ety = PT_INT;
        return ph_call("ph_os_now_ms", 0, 0, 0, 0, 0, TY_I64);
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
        if (str_eq(name, "ord")) ph_argbyte = 1;
    }
    uptr av = ph_read_args(16, fl, line, pnb);
    i64 na = ld64(pnb);
    // php compiles these to an opcode of their own when the name reaches the
    // global function unqualified: no frame of theirs in a trace
    i64 opc = 0;
    if (na == 1 && (str_eq(name, "strlen") || str_eq(name, "count") || str_eq(name, "sizeof")
        || str_eq(name, "intval") || str_eq(name, "floatval") || str_eq(name, "doubleval")
        || str_eq(name, "boolval") || str_eq(name, "strval"))) opc = 1;
    if (na == 2 && str_eq(name, "array_key_exists")) opc = 1;
    if (opc && ld8(ph_ns_cur()) && ld8(raw) != 92) opc = 0;
    if (opc) ph_zl = ph_zl_args;
    // a program's own function of the name is not the builtin
    if (ph_fn_find(name) < 0) ph_zpp_args(name, av, na, line, fl, opc);
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
    if (str_eq(name, "strlen"))   { ph_need(na, 1, name, fl, line); ph_ety = PT_INT; return ph_strlen_of(ph_to_str(a0, t0)); }
    if (str_eq(name, "count") || str_eq(name, "sizeof")) {
        ph_need(na, 1, name, fl, line);
        if (t0 == PT_PK) { ph_ety = PT_INT; return ph_quiet("php_pk_count", 1, a0, 0, 0, 0, TY_I64); }
        // anything but an array: ZPP above refused it unless it is a Countable
        if (!ph_is_arr(t0)) { ph_ety = PT_INT; return ph_c1("php_count_zv", ph_to_mixed(a0, t0), TY_I64); }
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
        i64 nd = ph_to_str(ph_a(av, 1), ph_aty(av, 1));
        // strpos($s, 'c'): one byte from the start is a scan and nothing
        // else, and raises nothing (php_strpos1)
        if (na == 2 && ph_lit_len(nd) == 1)
            return ph_quiet("php_strpos1", 2, ph_to_str(a0, t0), ph_int(ph_lit_byte(nd)), 0, 0, TY_I64);
        // an offset is php's ValueError outside the haystack (php_strpos_c)
        if (na == 3 && !(nd_kind(off) == N_INT && nd_val(off) == 0))
            return ph_c3("php_strpos_c", ph_to_str(a0, t0), nd, off, TY_I64);
        return ph_c3("php_strpos", ph_to_str(a0, t0), nd, off, TY_I64);
    }
    if (str_eq(name, "str_replace")) {
        if (na < 3 || na > 4) ph_todo2(fl, line, "the wrong number of arguments for", name);
        ph_ety = PT_STRING;
        // the fourth argument is php's by-reference $count
        i64 cnt = ph_int(0);
        if (na == 4) cnt = ph_a(av, 3);
        // an array anywhere -- or a zval that may hold one -- is php's whole
        // signature, and the answer is an array when the SUBJECT is one
        i64 t1 = ph_aty(av, 1);
        i64 t2 = ph_aty(av, 2);
        i64 anyarr = ph_is_arr(t0) || ph_is_arr(t1) || ph_is_arr(t2);
        if (t0 == PT_MIXED || t1 == PT_MIXED || t2 == PT_MIXED) anyarr = 1;
        if (anyarr) {
            i64 z = ph_c4("php_f_str_replace", ph_to_mixed(a0, t0), ph_to_mixed(ph_a(av, 1), t1),
                          ph_to_mixed(ph_a(av, 2), t2), cnt, ty_pzv);
            if (t2 == PT_MIXED || ph_is_arr(t2)) { ph_ety = PT_MIXED; return z; }
            return ph_c1("php_zv_str", z, ty_pstr);
        }
        // no $count: the replacement itself, with no wrapper call around it,
        // and quiet -- over three strings str_replace raises nothing
        if (na == 3) {
            i64 rs = ph_to_str(a0, t0);
            i64 rr = ph_to_str(ph_a(av, 1), ph_aty(av, 1));
            i64 rj = ph_to_str(ph_a(av, 2), ph_aty(av, 2));
            // str_replace('a', '', str_replace('b', '', $s)), two single
            // bytes deleted: one pass (php_str_del2)
            if (ph_lit_len(rs) == 1 && ph_lit_len(rr) == 0 && nd_kind(rj) == N_CALL
                && str_eq(nd_name(rj), "php_str_replace")) {
                i64 is = nd_a(rj);
                i64 ir = nd_next(is);
                i64 isj = nd_next(ir);
                if (ph_lit_len(is) == 1 && ph_lit_len(ir) == 0) {
                    set_nd_next(isj, 0);
                    return ph_quiet("php_str_del2", 3, isj, ph_int(ph_lit_byte(is)), ph_int(ph_lit_byte(rs)), 0, ty_pstr);
                }
            }
            return ph_quiet("php_str_replace", 3, rs, rr, rj, 0, ty_pstr);
        }
        return ph_c4("php_str_replace_c", ph_to_str(a0, t0), ph_to_str(ph_a(av, 1), ph_aty(av, 1)),
                     ph_to_str(ph_a(av, 2), ph_aty(av, 2)), cnt, ty_pstr);
    }
    if (str_eq(name, "implode") || str_eq(name, "join")) {
        // php 8: implode($array), or implode($separator, $array) -- the
        // legacy implode($array, $separator) order is gone, it is a TypeError
        ph_ety = PT_STRING;
        if (na == 1 && ph_is_arr(t0)) return ph_c2("php_implode", ph_strlit("", 0), a0, ty_pstr);
        if (na < 1 || na > 2) ph_need(na, 2, name, fl, line);
        i64 at = 0;
        if (na == 2) at = ph_aty(av, 1);
        if (na == 2 && ph_is_arr(at) && t0 != PT_ARR && t0 != PT_MIXED)
            return ph_c2("php_implode", ph_to_str(a0, t0), ph_a(av, 1), ty_pstr);
        i64 z2 = ph_int(0);
        if (na == 2) z2 = ph_to_mixed(ph_a(av, 1), at);
        return ph_c3("php_implode_any", ph_raw(name, cstrlen(name)), ph_to_mixed(a0, t0), z2, ty_pstr);
    }
    if (str_eq(name, "explode")) {
        if (na < 2 || na > 3) ph_need(na, 2, name, fl, line);
        ph_ety = PT_ARR;
        ph_efresh = 1;
        if (na == 2) {
            // php's ValueError on an empty separator: a non-empty literal one
            // cannot be
            i64 sep = ph_to_str(a0, t0);
            if (ph_lit_len(sep) < 1) return ph_c2("php_explode_c", sep, ph_to_str(ph_a(av, 1), ph_aty(av, 1)), ty_parr);
            return ph_c2("php_explode", sep, ph_to_str(ph_a(av, 1), ph_aty(av, 1)), ty_parr);
        }
        return ph_c3("php_f_explode3", ph_to_mixed(a0, t0), ph_to_mixed(ph_a(av, 1), ph_aty(av, 1)),
                     ph_to_mixed(ph_a(av, 2), ph_aty(av, 2)), ty_parr);
    }
    if (str_eq(name, "intdiv")) {
        ph_need(na, 2, name, fl, line);
        ph_ety = PT_INT;
        // a divisor the compiler can see is a positive literal can neither be
        // zero nor turn PHP_INT_MIN into an overflow: mc's own `/`, which
        // cannot raise -- `%`'s rule in src/expr.mc, and no position store,
        // no test and no temporary around it
        if (nd_kind(ph_a(av, 1)) == N_INT && nd_val(ph_a(av, 1)) > 0)
            return ph_bin(ph_tok("/", 1), ph_to_int(a0, t0), ph_a(av, 1), TY_I64);
        return ph_c2("php_intdiv", ph_to_int(a0, t0), ph_to_int(ph_a(av, 1), ph_aty(av, 1)), TY_I64);
    }
    if (str_eq(name, "abs")) {
        ph_need(na, 1, name, fl, line);
        if (t0 == PT_FLOAT) { ph_ety = PT_FLOAT; return ph_c1("php_abs_f", a0, ty_f64); }
        // a zval or a string may hold a float: php's int|float answer
        if (t0 == PT_MIXED || t0 == PT_STRING || t0 == PT_NULL) { ph_ety = PT_MIXED; return ph_c1("php_zv_abs", ph_to_mixed(a0, t0), ty_pzv); }
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
            if (res) { st64(mm + 16, res); k = 1; }
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
    if (str_eq(name, "ord")) {
        ph_need(na, 1, name, fl, line);
        ph_ety = PT_INT;
        // ord($s[$i]): the byte was read in place (ph_read_args)
        if (ph_argbyte_done && na == 1) return a0;
        return ph_c1("php_ord", ph_to_str(a0, t0), TY_I64);
    }
    if (str_eq(name, "strtoupper")) { ph_need(na, 1, name, fl, line); ph_ety = PT_STRING; return ph_c1("php_strtoupper", ph_to_str(a0, t0), ty_pstr); }
    if (str_eq(name, "strtolower")) { ph_need(na, 1, name, fl, line); ph_ety = PT_STRING; return ph_c1("php_strtolower", ph_to_str(a0, t0), ty_pstr); }
    if (str_eq(name, "ucfirst")) { ph_need(na, 1, name, fl, line); ph_ety = PT_STRING; return ph_c1("php_ucfirst", ph_to_str(a0, t0), ty_pstr); }
    if (str_eq(name, "lcfirst")) { ph_need(na, 1, name, fl, line); ph_ety = PT_STRING; return ph_c1("php_lcfirst", ph_to_str(a0, t0), ty_pstr); }
    if (str_eq(name, "strrev")) { ph_need(na, 1, name, fl, line); ph_ety = PT_STRING; return ph_c1("php_strrev", ph_to_str(a0, t0), ty_pstr); }
    if (str_eq(name, "trim") || str_eq(name, "ltrim") || str_eq(name, "rtrim") || str_eq(name, "chop")) {
        if (na < 1 || na > 2) ph_todo2(fl, line, "the wrong number of arguments for", name);
        // a native string (and a native mask) needs no zval on either side:
        // a trim raises nothing, and a LITERAL mask's byte map is built once
        // per run (php_bmap_lit) instead of once per call
        i64 tmode = 0;
        if (str_eq(name, "ltrim")) tmode = 1;
        if (str_eq(name, "rtrim") || str_eq(name, "chop")) tmode = 2;
        if (t0 == PT_STRING && na == 1) {
            ph_ety = PT_STRING;
            return ph_quiet("php_trim", 2, a0, ph_int(tmode), 0, 0, ty_pstr);
        }
        if (t0 == PT_STRING && na == 2 && ph_aty(av, 1) == PT_STRING) {
            ph_ety = PT_STRING;
            i64 mk = ph_a(av, 1);
            if (ph_is_strlit(mk))
                return ph_quiet("php_trim_m", 3, a0, ph_bmap_of(mk, 1), ph_int(tmode), 0, ty_pstr);
            return ph_quiet("php_trim_s", 3, a0, mk, ph_int(tmode), 0, ty_pstr);
        }
        uptr f = "php_f_trim";
        if (str_eq(name, "ltrim")) f = "php_f_ltrim";
        if (str_eq(name, "rtrim") || str_eq(name, "chop")) f = "php_f_rtrim";
        i64 cl = ph_call("php_znull", 0, 0, 0, 0, 0, ty_pzv);
        if (na == 2) cl = ph_to_mixed(ph_a(av, 1), ph_aty(av, 1));
        ph_ety = PT_STRING;
        return ph_c2(f, ph_to_mixed(a0, t0), cl, ty_pstr);
    }
    // strspn/strcspn over native strings and int offsets: no zval, and a
    // LITERAL set's byte map built once per run. Neither raises in php 8 (the
    // window is clamped), so the call is quiet.
    //
    // A MIXED subject or set (a `global`/`static` string, or a `mixed` the
    // body never narrowed) is taken here too, coerced with ph_to_str -- which
    // for a string zval is php_zv_str, the string BORROWED with no reference
    // taken. The generic ph_lib fallthrough instead wraps the subject with
    // php_zstr, which escapes it (php_str_esc: a reference taken, released only
    // at the module-call boundary), so a hot loop inside one call leaked a
    // zval per iteration. This path never escapes, so there is nothing to
    // release -- the same shape strpos already uses.
    if ((str_eq(name, "strspn") || str_eq(name, "strcspn")) && na >= 2 && na <= 4
        && (t0 == PT_STRING || t0 == PT_MIXED)
        && (ph_aty(av, 1) == PT_STRING || ph_aty(av, 1) == PT_MIXED)
        && (na < 3 || ph_aty(av, 2) == PT_INT) && (na < 4 || ph_aty(av, 3) == PT_INT)) {
        i64 want = 1;
        if (str_eq(name, "strcspn")) want = 0;
        i64 so = ph_int(0);
        i64 sl = ph_int(0);
        i64 hasl = 0;
        if (na >= 3) so = ph_a(av, 2);
        if (na == 4) { sl = ph_a(av, 3); hasl = 1; }
        // ph_to_str is identity on a PT_STRING, so a literal set stays a
        // php_str_lit node and the byte-map/run branches below still see it.
        i64 set = ph_to_str(ph_a(av, 1), ph_aty(av, 1));
        u8 sa[48];
        st64(sa, ph_to_str(a0, t0));
        st64(sa + 16, so);
        st64(sa + 24, sl);
        st64(sa + 32, ph_int(hasl));
        st64(sa + 40, ph_int(want));
        uptr sf = "php_spn_s";
        i64 nargs = 6;
        // a literal set that is one run of bytes: php_spn_r, no byte map
        if (ph_is_strlit(set) && want && !hasl && ph_lit_len(set) > 0) {
            uptr lb = nd_name(nd_next(nd_a(set)));
            i64 ll = ph_lit_len(set);
            u8 seen[256];
            i64 q = 0;
            loop { if (q >= 256) break; st8(seen + q, 0); q = q + 1; }
            i64 lo = 255;
            i64 hi = 0;
            q = 0;
            loop {
                if (q >= ll) break;
                i64 c = ld8(lb + q);
                st8(seen + c, 1);
                if (c < lo) lo = c;
                if (c > hi) hi = c;
                q = q + 1;
            }
            i64 run = 1;
            q = lo;
            loop { if (q > hi) break; if (!ld8(seen + q)) run = 0; q = q + 1; }
            if (run) {
                st64(sa + 8, ph_int(lo));
                st64(sa + 16, ph_int(hi - lo));
                st64(sa + 24, so);
                i64 save0 = ph_can_throw;
                i64 sr = ph_calln("php_spn_r", sa, 4, TY_I64);
                ph_can_throw = save0;
                ph_ety = PT_INT;
                return sr;
            }
        }
        if (ph_is_strlit(set)) {
            sf = "php_spn";
            set = ph_bmap_of(set, 0);
            // strspn($s, 'lit'[, $o]): the three-argument routine
            if (want && !hasl) { sf = "php_spn_o"; nargs = 3; st64(sa + 16, so); }
        }
        st64(sa + 8, set);
        i64 save = ph_can_throw;
        i64 sc = ph_calln(sf, sa, nargs, TY_I64);
        ph_can_throw = save;
        ph_ety = PT_INT;
        return sc;
    }
    if (str_eq(name, "str_pad")) {
        if (na < 2 || na > 4) ph_need(na, 2, name, fl, line);
        i64 pad = ph_strlit(" ", 1);
        i64 type = ph_int(1);                       // STR_PAD_RIGHT
        if (na >= 3) pad = ph_to_str(ph_a(av, 2), ph_aty(av, 2));
        if (na >= 4) type = ph_to_int(ph_a(av, 3), ph_aty(av, 3));
        ph_ety = PT_STRING;
        i64 ps = ph_to_str(a0, t0);
        // an empty pad or a pad type php does not have is its ValueError: a
        // non-empty literal pad and a literal type in range need no check
        i64 pchk = na >= 3 && ph_lit_len(pad) < 1;
        if (na == 4 && !(nd_kind(type) == N_INT && nd_val(type) >= 0 && nd_val(type) <= 2)) pchk = 1;
        if (pchk) return ph_calln("php_str_pad_c", ph_zpp_five(ps, ph_to_int(ph_a(av, 1), ph_aty(av, 1)), pad, type, ph_int(na)), 5, ty_pstr);
        // str_pad((string) $int, ...): the digits padded in place, the
        // intermediate string never built (php_str_pad_i)
        if (nd_kind(ps) == N_CALL && str_eq(nd_name(ps), "php_itos"))
            return ph_c4("php_str_pad_i", nd_a(ps), ph_to_int(ph_a(av, 1), ph_aty(av, 1)), pad, type, ty_pstr);
        return ph_c4("php_str_pad", ps, ph_to_int(ph_a(av, 1), ph_aty(av, 1)), pad, type, ty_pstr);
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
    if (str_eq(name, "is_null")) {
        // a native nullable scalar: its null-ness is its flag, not a tag on a
        // (nonexistent) zval
        i64 onf = ph_opt_flagnode(a0);
        if (onf) { ph_ety = PT_BOOL; return ph_cast(TY_U8, onf); }
        return ph_isof(na, t0, a0, PT_NULL, 1, fl, line, name);
    }
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
            if (ph_calls_back(name)) return ph_fr_internal(lc, name, na, line, fl);
            return lc;
        }
        // An EXTENSION is loaded into a php that has a function table, and
        // php looks a call up there when it runs: another module may define
        // the name. A PROGRAM has no other module, so there it stays refused.
        if (ph_ext) return ph_ftable_call(name, av, na, fl, line, ld64(fbb));
        ph_todo2(fl, line, "a php function mc-php does not have", name);
    }
    i64 np = ld64(ph_fnp + fi * 8);
    i64 vararg = ld64(ph_fvar + fi * 8);
    i64 spread = ph_had_spread;
    if (na > np && !vararg && !spread) ph_todo2(fl, line, "the wrong number of arguments for", name);
    // a void call stays a statement of its own, and a coerced list is computed
    // ahead (ph_fr_coerces): both keep the frame ahead with it
    // php's required count: every parameter up to the last one with no
    // default (one with a default before it is "implicitly required"). A
    // call that leaves out a NATIVE one -- which has no "not passed" its
    // prologue could see -- raises here, with the callee's frame on the
    // stack as php's has; a zval one raises in the callee's prologue.
    i64 amin = 0;
    i64 nfix = np;
    if (vararg) nfix = np - 1;
    i64 ai = 0;
    loop { if (ai >= nfix) break; if (!ld64(ph_fpd + (fi * PH_MAXP + ai) * 8)) amin = ai + 1; ai = ai + 1; }
    i64 amiss = 0;
    if (!spread && na < amin && ld64(ph_fpt + (fi * PH_MAXP + na) * 8) != PT_MIXED) amiss = 1;
    i64 frp = 0;
    if (amiss || ph_mcty(ld64(ph_fret + fi * 8)) == TY_VOID || ph_fr_coerces(fi, av, na, np, vararg))
        frp = ph_fr_push(name, 0, 0, av, na, line, fl);
    i64 head = 0;
    i64 tail = 0;
    i64 i = 0;
    i64 coerced = 0;
    loop {
        if (i >= np) break;
        i64 want = ld64(ph_fpt + (fi * PH_MAXP + i) * 8);
        i64 v = 0;
        // a native nullable-scalar parameter (src/decl.mc): pass the value and
        // a u8 null flag as two mc arguments. The argument may be another such
        // variable (pass its value and flag), the null literal or an omitted
        // optional one (0 / flag 1), or a plain scalar value (coerced / flag 0).
        // a defaulted `int $x = N` (opt slot 2) takes this road only when the
        // argument is omitted; a passed one is an ordinary native int below,
        // with its TypeError check, and a 0 flag after it
        i64 fo = ld64(ph_fopt + (fi * PH_MAXP + i) * 8);
        // a required parameter reached by a spread: missing is php's
        // ArgumentCountError, at the parameter (php_spread_req)
        if (spread && i < na && i < amin && ph_aty(av, i) == PT_MIXED && want != PT_MIXED) {
            uptr sdf = ld64(ph_fdfile + fi * 8);
            if (!sdf) sdf = fl;
            u8 sra[64];
            st64(sra, ph_a(av, i));
            uptr sdn = ld64(ph_fname + fi * 8);
            st64(sra + 8, ph_strlit(sdn, cstrlen(sdn)));
            st64(sra + 16, ph_int(i));
            st64(sra + 24, ph_int(amin));
            st64(sra + 32, ph_int(amin == nfix));
            uptr sdfa = ph_disp(ph_absfile(sdf));
            st64(sra + 40, ph_strlit(sdfa, cstrlen(sdfa)));
            st64(sra + 48, ph_int(ld64(ph_fpl + (fi * PH_MAXP + i) * 8)));
            st64(av + i * 24, ph_tref(ph_temp(ph_calln("php_spread_req", sra, 7, ty_pzv), ty_pzv, "phsr_")));
            coerced = 1;
        }
        if (fo == 1 || (fo == 2 && (i >= na || (spread && ph_aty(av, i) == PT_MIXED)))) {
            i64 vv = 0;
            i64 vfl = 0;
            if (i >= na) {
                // a required one left out raised above (amiss): this is never read
                vv = ph_cast(ph_mcty(want), ph_int(0));
                vfl = ph_int(1);
            } else {
                i64 have = ph_aty(av, i);
                i64 an = ph_a(av, i);
                uptr af = 0;
                if (nd_kind(an) == N_IDENT) af = ph_opt_flag_of(nd_name(an));
                if (have == PT_NULL) {
                    vv = ph_cast(ph_mcty(want), ph_int(0));
                    vfl = ph_int(1);
                } else if (af) {
                    // another native nullable scalar: its value (coerced) and flag
                    if (want == PT_INT)    vv = ph_to_int(an, have);
                    if (want == PT_FLOAT)  vv = ph_to_float(an, have);
                    if (want == PT_STRING) vv = ph_to_str(an, have);
                    if (want == PT_BOOL)   vv = ph_to_bool(an, have);
                    i64 ff = node_new(N_IDENT, line, fl);
                    set_nd_name(ff, af);
                    set_nd_type(ff, TY_U8);
                    vfl = ff;
                } else if (have != PT_INT) {
                    // anything else where a native ?int is wanted: php's check
                    // and conversion (`?int`, as declared), the value once,
                    // then its null-ness and its int
                    uptr pn9 = ld64(ph_fpn + (fi * PH_MAXP + i) * 8);
                    if (!pn9) pn9 = "";
                    uptr df9 = ld64(ph_fdfile + fi * 8);
                    if (!df9) df9 = "";
                    if (cstrlen(df9)) df9 = ph_disp(ph_absfile(df9));
                    i64 pl9 = ld64(ph_fpl + (fi * PH_MAXP + i) * 8);
                    if (!pl9) pl9 = ld64(ph_fdline + fi * 8);
                    i64 m9 = RT_INT | RT_NULL | 32768;
                    if (fo == 2) m9 = RT_INT | 32768;          // a spread that may have run out
                    i64 ck9 = ph_ptcheck(ph_to_mixed(an, have), m9, "", 0, 0, "", name, i + 1, pn9, df9, pl9, fl);
                    i64 zt = ph_temp(ck9, ty_pzv, "phopt_");
                    coerced = 1;
                    if (frp) ph_pending_stmt(ph_stmt_of(ph_quiet("php_fr_coerced", 3, ph_int(i), ph_tref(zt), ph_int(0), 0, TY_VOID)));
                    vfl = ph_c1("php_opt_isnull", ph_tref(zt), TY_I64);
                    vv = ph_c1("php_opt_long", zt, TY_I64);
                } else {
                    if (want == PT_INT)    vv = ph_to_int(an, have);
                    if (want == PT_FLOAT)  vv = ph_to_float(an, have);
                    if (want == PT_STRING) vv = ph_to_str(an, have);
                    if (want == PT_BOOL)   vv = ph_to_bool(an, have);
                    vfl = ph_int(0);
                }
            }
            if (tail) set_nd_next(tail, vv);
            if (!tail) head = vv;
            set_nd_next(vv, vfl);
            tail = vfl;
            i = i + 1;
            continue;
        }
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
                    st64(vcb + 8, ph_int(vpc | ph_strict_bit(fl)));
                    st64(vcb + 16, ph_strlit("", 0));
                    st64(vcb + 24, ph_strlit(name, cstrlen(name)));
                    st64(vcb + 32, ph_int(j + 1));
                    st64(vcb + 40, ph_strlit("", 0));
                    // placed at the variadic parameter, as php places it
                    uptr vdf = ld64(ph_fdfile + fi * 8);
                    if (!vdf) vdf = "";
                    if (cstrlen(vdf)) vdf = ph_disp(ph_absfile(vdf));
                    st64(vcb + 48, ph_strlit(vdf, cstrlen(vdf)));
                    st64(vcb + 56, ph_int(ld64(ph_fpl + (fi * PH_MAXP + i) * 8)));
                    el = ph_calln("php_param_coerce_at", vcb, 8, ty_pzv);
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
            // not passed: a zval parameter takes 0, which its prologue reads;
            // a native one is required and raised above (amiss), so its 0 is
            // never read
            v = ph_cast(ph_mcty(want), ph_int(0));
        }
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
                if (want == PT_ARR && have == PT_MIXED) cw = 5;   // `array $a` given a zval
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
                // the caller's file decides strict_types; the error is placed
                // where the parameter is declared (php_param_coerce_at)
                st64(acb + 8, ph_int(cw | ph_strict_bit(fl)));
                uptr dfl = ld64(ph_fdfile + fi * 8);
                if (!dfl) dfl = "";
                if (cstrlen(dfl)) dfl = ph_disp(ph_absfile(dfl));
                st64(acb + 48, ph_strlit(dfl, cstrlen(dfl)));
                // php places it at the parameter's own line
                i64 pl = ld64(ph_fpl + (fi * PH_MAXP + i) * 8);
                if (!pl) pl = ld64(ph_fdline + fi * 8);
                st64(acb + 56, ph_int(pl));
                v = ph_tref(ph_temp(ph_calln("php_param_coerce_at", acb, 8, ty_pzv),
                                    ty_pzv, "phc_"));
                // the callee's frame (frp, pushed above) shows the converted value
                if (frp) ph_pending_stmt(ph_stmt_of(ph_quiet("php_fr_coerced", 3, ph_int(i), ph_tref(v), ph_int(0), 0, TY_VOID)));
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
        if (fo == 2) {
            i64 pf0 = ph_int(0);
            set_nd_next(v, pf0);
            tail = pf0;
        }
        i = i + 1;
    }
    // ONE check for the whole argument list: php_param_coerce is a no-op once
    // something is pending, so the FIRST refusal is the one that stands, and
    // this runs before the call, so the body is not reached with a filled-in 0
    // the frame goes BEFORE the check leaves: the TypeError was created with
    // it on the stack (php's #0 is the call it refused), and nothing leaves
    // with it still there
    if (amiss) {
        uptr dn = ld64(ph_fname + fi * 8);
        uptr dfl2 = ld64(ph_fdfile + fi * 8);
        if (!dfl2) dfl2 = fl;
        ph_pending_stmt(ph_ac_raise(dn, na, amin, amin == nfix, dfl2, ld64(ph_fpl + (fi * PH_MAXP + na) * 8)));
        coerced = 1;
    }
    if (coerced && frp) {
        i64 pex = node_new(N_IDENT, line, fl);
        set_nd_name(pex, "ph_exc");
        set_nd_type(pex, TY_UPTR);
        i64 pif = node_new(N_IF, line, fl);
        set_nd_a(pif, ph_truthy(pex));
        set_nd_b(pif, ph_fr_st(ph_quiet("php_fr_pop", 0, 0, 0, 0, 0, TY_VOID)));
        ph_pending_stmt(pif);
    }
    if (coerced) ph_pending_stmt(ph_check(line, fl));
    ph_can_throw = 1;
    i64 c = node_new(N_CALL, line, fl);
    set_nd_name(c, ph_mangle(name, "f_"));
    set_nd_a(c, head);
    i64 rt = ld64(ph_fret + fi * 8);
    set_nd_type(c, ph_mcty(rt));
    ph_ety = rt;
    ph_ref_call = ld64(ph_frr + fi * 8);
    if (frp) return ph_fr_call(c, frp);
    return ph_fr_wrap(c, name, fi, na, np, vararg, line, fl);
}



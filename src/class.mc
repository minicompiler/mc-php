// class.mc -- classes, interfaces, traits and enums.
// 
// Every lookup is BY NAME through a registry built at program start. That is
// dispatch, not reflection (docs/plan.md D6): the name is a literal in the
// source and no run-time type table a program can enumerate exists. The
// member list, the declaration and a method body are the three parts.

// ---- classes, interfaces, traits and enums --------------------------------
// The class entry is built at run time by statements this compiler emits in
// front of main, and every member is reached BY NAME through the registry.
// That is not reflection (D6): the name is a literal in the source and no
// program can enumerate the tables.
//
// A method is `uptr m_<Class>_<name>(uptr this, uptr a1..)`: every argument is
// a zval and so is the result, which is what lets php_mcall dispatch through
// one function pointer. An argument that was not passed arrives as 0, which is
// how a default parameter and ArgumentCountError are both expressible.
i64 ph_cnew_head;
i64 ph_cnew_tail;
i64 ph_cfill_head;
i64 ph_cfill_tail;
uptr ph_cur_ceg;               // the mc global holding its class entry
i64  ph_in_method;             // 1 while a method body is being parsed
i64  ph_in_static;

void ph_cnew(i64 s) {
    if (ph_cnew_tail) set_nd_next(ph_cnew_tail, s);
    if (!ph_cnew_tail) ph_cnew_head = s;
    ph_cnew_tail = s;
}

void ph_cfill(i64 s) {
    // T8: a class member's DEFAULT may be an array literal, and an array
    // literal is pending statements plus a local -- `public $x = [1, 2];`
    // captured the local before those ran, so the property came out
    // `array(0)` and, with another array literal earlier in the file, the
    // program segfaulted. The pendings belong in front of the fill.
    s = ph_prefix_stmts(ph_take_pend(), s);
    i64 t = s;
    loop { if (!nd_next(t)) break; t = nd_next(t); }
    if (ph_cfill_tail) set_nd_next(ph_cfill_tail, s);
    if (!ph_cfill_tail) ph_cfill_head = s;
    ph_cfill_tail = t;
}

i64 ph_stmt_of(i64 c) {
    i64 s = node_new(N_EXPRSTMT, ph_tline, ph_tfile);
    set_nd_a(s, c);
    return s;
}

// the class entry of the code doing an access, for the visibility check
// the class entry lives in a one-slot global, like a string literal's cache:
// mc's N_GLOBAL with a size is storage, and the value is read with ld64.
i64 ph_cegvar(uptr g) {
    i64 n = node_new(N_IDENT, ph_tline, ph_tfile);
    set_nd_name(n, g);
    set_nd_type(n, TY_UPTR);
    return n;
}

i64 ph_ceref(uptr g) { return ph_c1("ld64", ph_cegvar(g), TY_UPTR); }

i64 ph_scope() {
    if (!ph_cur_ceg) return ph_int(0);
    return ph_ceref(ph_cur_ceg);
}

// a class entry looked up by its literal name
i64 ph_ce_of(uptr name, uptr fl, i64 line) {
    if (str_eq(name, "static")) {
        // late static binding: the class the call was made ON, which the
        // runtime carries, falling back to the declaring class
        if (!ph_cur_ceg) err_at(fl, line, "mc-php: static:: outside a class");
        return ph_c1("php_lsb_or", ph_ceref(ph_cur_ceg), TY_UPTR);
    }
    if (str_eq(name, "self")) {
        if (!ph_cur_ceg) err_at(fl, line, "mc-php: self:: outside a class");
        return ph_ceref(ph_cur_ceg);
    }
    if (str_eq(name, "parent")) {
        if (!ph_cur_ceg) err_at(fl, line, "mc-php: parent:: outside a class");
        return ph_c1("php_ce_parent", ph_ceref(ph_cur_ceg), TY_UPTR);
    }
    return ph_c1("php_ce_byname", ph_strlit(name, cstrlen(name)), TY_UPTR);
}

// `this` inside a method
i64 ph_this(uptr fl, i64 line) {
    if (!ph_in_method) err_at(fl, line, "mc-php: $this outside a method");
    i64 n = node_new(N_IDENT, line, fl);
    set_nd_name(n, "v_this");
    set_nd_type(n, TY_UPTR);
    return n;
}

// the receiver of -> as a zval, whatever it was
i64 ph_recv(i64 v, i64 t) {
    if (t == PT_OBJ) return ph_c1("php_zobj", v, ty_pzv);
    return ph_to_mixed(v, t);
}

// the call arguments of a method: zvals, at most six (callp takes seven and
// the receiver is the first)
uptr ph_margs(uptr pn, uptr fl, i64 line) {
    u8 nb[8];
    uptr av = ph_read_args(6, fl, line, nb);
    i64 n = ld64(nb);
    if (n > 6) ph_todo(fl, line, "more than six arguments to a method");
    uptr out = xalloc(6 * 8 + 8);
    i64 i = 0;
    loop {
        if (i >= 6) break;
        i64 a = ph_int(0);
        if (i < n) a = ph_to_mixed(ph_a(av, i), ph_aty(av, i));
        st64(out + i * 8, a);
        i = i + 1;
    }
    st64(pn, n);
    return out;
}

i64 ph_calln(uptr fn, uptr args, i64 n, i64 ty) {
    ph_can_throw = 1;
    i64 c = node_new(N_CALL, ph_tline, ph_tfile);
    ph_rz_mark(c, fn);
    set_nd_name(c, fn);
    i64 head = 0;
    i64 tail = 0;
    i64 i = 0;
    loop {
        if (i >= n) break;
        i64 a = ld64(args + i * 8);
        if (tail) set_nd_next(tail, a);
        if (!tail) head = a;
        tail = a;
        i = i + 1;
    }
    set_nd_a(c, head);
    set_nd_type(c, ty);
    return c;
}

// $recv->name(args)
i64 ph_mcall_ns(i64 recv, uptr name, uptr fl, i64 line, i64 ns) {
    u8 nb[8];
    uptr ma = ph_margs(nb, fl, line);
    u8 all[80];
    st64(all, recv);
    st64(all + 8, ph_strlit(name, cstrlen(name)));
    st64(all + 16, ph_scope());
    st64(all + 24, ph_int(ld64(nb)));
    i64 i = 0;
    loop { if (i >= 6) break; st64(all + 32 + i * 8, ld64(ma + i * 8)); i = i + 1; }
    ph_ety = PT_MIXED;
    uptr f = "php_zv_mcall";
    if (ns) f = "php_zv_mcall_ns";                          // `$o?->m()`
    return ph_calln(f, all, 10, ty_pzv);
}

i64 ph_mcall_node(i64 recv, uptr name, uptr fl, i64 line) {
    return ph_mcall_ns(recv, name, fl, line, 0);
}

// Cls::name(args), with `this` forwarded when there is one (parent::__construct)
i64 ph_scall_node(i64 ce, uptr name, uptr fl, i64 line) {
    u8 nb[8];
    uptr ma = ph_margs(nb, fl, line);
    i64 thisp = ph_int(0);
    if (ph_in_method && !ph_in_static) thisp = ph_this(fl, line);
    u8 all[88];
    st64(all, ce);
    st64(all + 8, ph_strlit(name, cstrlen(name)));
    st64(all + 16, thisp);
    st64(all + 24, ph_scope());
    st64(all + 32, ph_int(ld64(nb)));
    i64 i = 0;
    loop { if (i >= 6) break; st64(all + 40 + i * 8, ld64(ma + i * 8)); i = i + 1; }
    ph_ety = PT_MIXED;
    return ph_calln("php_scall", all, 11, ty_pzv);
}

// ---- the member list -------------------------------------------------------
// `#[\Override]`: one call per marked member, into the list that runs after
// every class entry is built, so the parent chain is there to be walked.
// The check is php's own and it is not reflection (D6): the compiler names
// the member, and nothing at run time enumerates anything a program can see.
i64 ph_ovr_head;
i64 ph_ovr_tail;

void ph_ovr_check(uptr ceg, uptr cname, uptr mname, i64 kind, uptr fl, i64 line) {
    uptr what = p_cat(cname, "::", 0, 2);
    if (kind) what = p_cat(what, "$", 0, 1);
    what = p_cat(what, mname, 0, cstrlen(mname));
    if (!kind) what = p_cat(what, "()", 0, 2);
    u8 av[48];
    st64(av, ph_ceref(ceg));
    st64(av + 8, ph_strlit(what, cstrlen(what)));
    st64(av + 16, ph_strlit(mname, cstrlen(mname)));
    st64(av + 24, ph_int(kind));
    uptr af = ph_disp(ph_absfile(fl));
    st64(av + 32, ph_raw(af, cstrlen(af)));
    st64(av + 40, ph_int(line));
    i64 s = ph_stmt_of(ph_calln("php_ce_ovr", av, 6, TY_VOID));
    if (ph_ovr_tail) set_nd_next(ph_ovr_tail, s);
    if (!ph_ovr_tail) ph_ovr_head = s;
    ph_ovr_tail = s;
}

i64 ph_visword() {
    if (ph_is("public"))    { ph_next(); return V_PUBLIC; }
    if (ph_is("protected")) { ph_next(); return V_PROTECTED; }
    if (ph_is("private"))   { ph_next(); return V_PRIVATE; }
    return -1;
}

// a typed property's default, as php checks it while compiling: its static
// type det against the declared mask m (a constant expression php folds is
// left alone)
void ph_pdefault_check(i64 m, uptr tn, i64 det, uptr cname, uptr pname, uptr fl, i64 line) {
    uptr dn = 0;
    if (det == PT_NULL) {
        if (m & RT_NULL) return;
        uptr q = p_cat(p_cat("Default value for property of type ", tn, 0, cstrlen(tn)), " may not be null. Use the nullable type ?", 0, 41);
        q = p_cat(q, tn, 0, cstrlen(tn));
        ph_phpfatal_x(fl, line, p_cat(q, " to allow null default value", 0, 28), 1);
    }
    if (det == PT_INT) { if (m & RT_INT) return; dn = "int"; }
    if (det == PT_FLOAT) { if (m & RT_FLOAT) return; dn = "float"; }
    if (det == PT_STRING) { if (m & RT_STRING) return; dn = "string"; }
    if (det == PT_BOOL) { if (m & (RT_TRUE | RT_FALSE)) return; dn = "bool"; }
    if (det == PT_ARR) { if (m & RT_ARRAY) return; dn = "array"; }
    if (!dn) return;
    uptr msg = p_cat(p_cat("Cannot use ", dn, 0, cstrlen(dn)), " as default value for property ", 0, 31);
    msg = p_cat(msg, cname, 0, cstrlen(cname));
    msg = p_cat(msg, "::$", 0, 3);
    msg = p_cat(msg, pname, 0, cstrlen(pname));
    msg = p_cat(msg, " of type ", 0, 9);
    ph_phpfatal_x(fl, line, p_cat(msg, tn, 0, cstrlen(tn)), 1);
}

// a php type in a member position, accepted and discarded: D4 types the
// variable by its value, and a property is a zval whatever it declares
void ph_skip_type() {
    ph_accept("?", 1);
    loop {
        // a php type word may be one of mc's OWN keywords -- `void` is, and
        // `: void` on a method was 37 of the 734 that did not compile. The
        // test is what the token LOOKS like, not which id the core gave it.
        if (!ph_wordish() && ph_tid != T_STR && !(ph_tid == T_IDENT && ld8(ph_tname) == 92)) break;
        if (ph_at("$", 1)) break;
        ph_next();
        if (ph_accept("|", 1)) { ph_accept("?", 1); continue; }
        if (ph_accept("&", 1)) { ph_accept("?", 1); continue; }
        if (ph_accept("\\", 1)) continue;
        break;
    }
}

i64 ph_is_typeword() {
    if (ph_at("?", 1)) return 1;
    if (ph_tid == T_IDENT && ld8(ph_tname) == 92) return 1;       // \Fully\Qualified
    if (!ph_wordish()) return 0;
    if (ph_at("$", 1)) return 0;
    return 1;
}

void ph_method_body(uptr mcname, uptr cname, uptr ceg, i64 vis, i64 stat, i64 line, uptr fl, i64 abstract);

// ---- the declaration -------------------------------------------------------
// set by `new class ... {}`: the name ph_class gives a class that has none.
// php's own is "class@anonymous%s:%d$%x"; nothing in the corpus depends on
// the spelling except `get_class`, which prints it, so this is close to it
// and unique.
uptr ph_anon_name;
uptr ph_anon_args;                   // `new class (args)`: read where they are
i64  ph_anon_nargs;

// A published class's methods, as the class body is read (src/ext.mc's
// handlers are built from them when the class ends)
#define PH_MAXPM 64
uptr ph_pm_name[PH_MAXPM];
uptr ph_pm_fn[PH_MAXPM];
i64  ph_pm_vis[PH_MAXPM];
i64  ph_pm_np[PH_MAXPM];
i64  ph_pm_nreq[PH_MAXPM];
uptr ph_pm_pn[PH_MAXPM * 6];
i64  ph_npm;
// what ph_method_body read of the parameters of the method it just compiled
i64  ph_mb_np;
i64  ph_mb_nreq;
uptr ph_mb_pn[6];

void ph_class(uptr fl, i64 line, i64 flags) {
    i64 pub = 0;
    i64 kind = 0;                                    // 0 class 1 interface 2 trait 3 enum
    if (ph_is("interface")) kind = 1;
    if (ph_is("trait")) kind = 2;
    if (ph_is("enum")) kind = 3;
    ph_next();
    uptr cname = ph_anon_name;
    ph_anon_name = 0;
    ph_anon_args = 0;
    ph_anon_nargs = 0;
    // the constructor arguments of `new class (args) ... {}` sit between the
    // keyword and `extends`, so they are read here and handed back
    if (cname && ph_at("(", 1)) {
        u8 nbb[8];
        ph_anon_args = ph_margs(nbb, fl, line);
        ph_anon_nargs = ld64(nbb);
        if (!ph_anon_nargs) ph_anon_nargs = 0 - 1;   // `new class ()`: called, no args
    }
    if (!cname) {
        if (ph_tid != T_IDENT) err_at2(fl, line, "mc-php: a php class needs a name", ph_tname);
        cname = ph_ns_decl(ph_tname);               // `ns\Name` inside a namespace
        ph_next();
        // An extension PUBLISHES what the source names without a leading
        // underscore (lib/php_ext.mc § published classes); `_Name` is
        // module-private. What is published is a plain class at a file's top
        // level; the rest is refused by name rather than left out.
        if (ph_ext && ld8(ph_ns_last(cname)) != 95) {
            if (kind == 1) ph_todo2(fl, line, "an interface an extension would publish", cname);
            if (kind == 2) ph_todo2(fl, line, "a trait an extension would publish", cname);
            if (kind == 3) ph_todo2(fl, line, "an enum an extension would publish", cname);
            if (!ph_toplevel) ph_todo2(fl, line, "a class declared inside a function of an extension", cname);
            if (ph_is("extends") || ph_is("implements"))
                ph_todo2(fl, line, "a published class that extends or implements another", cname);
            pub = 1;
            ph_npm = 0;
        }
    }
    if (kind == 3) { if (ph_accept(":", 1)) ph_skip_type(); }

    ph_nonce = ph_nonce + 1;
    uptr ceg = ph_mangle(cname, "ce_");
    ceg = p_cat(ceg, php_dec(ph_nonce), 0, cstrlen(php_dec(ph_nonce)));
    i64 g = node_new(N_GLOBAL, line, fl);
    set_nd_name(g, ceg);
    set_nd_type(g, TY_UPTR);
    set_nd_val(g, 1);
    set_nd_a(g, 0);
    top_add(g);
    ph_cnew(ph_stmt_of(ph_c2("st64", ph_cegvar(ceg), ph_c1("php_ce_new", ph_strlit(cname, cstrlen(cname)), TY_UPTR), TY_VOID)));

    if (kind == 1) flags = flags | 4;
    if (kind == 3) flags = flags | 8;
    if (flags) ph_cfill(ph_stmt_of(ph_c2("php_ce_flag", ph_ceref(ceg), ph_int(flags), TY_VOID)));

    if (ph_is("extends")) {
        ph_next();
        loop {
            ph_accept("\\", 1);
            if (ph_tid != T_IDENT) err_at(fl, line, "mc-php: a php class name was expected after extends");
            uptr pn = ph_ns_class(ph_tname);
            ph_next();
            // an interface `extends` several: they are all interfaces here
            if (kind == 1) ph_cfill(ph_stmt_of(ph_c2("php_ce_iface", ph_ceref(ceg), ph_strlit(pn, cstrlen(pn)), TY_VOID)));
            if (kind != 1) ph_cfill(ph_stmt_of(ph_c2("php_ce_extend", ph_ceref(ceg), ph_strlit(pn, cstrlen(pn)), TY_VOID)));
            if (kind != 1) ph_cpar_add(cname, pn);
            if (!ph_accept(",", 1)) break;
        }
    }
    if (ph_is("implements")) {
        ph_next();
        loop {
            ph_accept("\\", 1);
            if (ph_tid != T_IDENT) err_at(fl, line, "mc-php: a php interface name was expected");
            uptr inm = ph_ns_class(ph_tname);
            ph_next();
            ph_cfill(ph_stmt_of(ph_c2("php_ce_iface", ph_ceref(ceg), ph_strlit(inm, cstrlen(inm)), TY_VOID)));
            if (!ph_accept(",", 1)) break;
        }
    }

    uptr savec = ph_cur_cls;
    uptr saveg = ph_cur_ceg;
    ph_cur_cls = cname;
    ph_cur_ceg = ceg;

    ph_want("{", 1, "expected { in a php class");
    loop {
        if (ph_at("}", 1)) break;
        if (ph_tid == T_EOF) err_at(fl, line, "mc-php: unterminated php class");
        i64 mline = ph_tline;
        uptr mfl = ph_tfile;
        i64 mflags = 0;
        i64 vis = -1;
        i64 stat = 0;
        i64 movr = ph_saw_override;
        ph_saw_override = 0;
        if (ph_ext_ab) { ph_ext_ab = 0; err_at(ph_ext_file, ph_ext_line, "mc-php: #[Extern] on something that is not a function"); }

        if (ph_is("use")) {
            ph_next();
            loop {
                uptr tn = ph_ns_class(ph_tname);
                ph_next();
                ph_cfill(ph_stmt_of(ph_c2("php_ce_use", ph_ceref(ceg), ph_strlit(tn, cstrlen(tn)), TY_VOID)));
                if (!ph_accept(",", 1)) break;
            }
            if (ph_at("{", 1)) { loop { if (ph_at("}", 1)) break; if (ph_tid == T_EOF) break; ph_next(); } ph_next(); }
            if (!ph_at("}", 1)) ph_accept(";", 1);
            continue;
        }
        if (kind == 3 && ph_is("case")) {
            ph_next();
            uptr en = ph_tname;
            ph_next();
            i64 ev = ph_call("php_znull", 0, 0, 0, 0, 0, ty_pzv);
            if (ph_accept("=", 1)) { i64 x = ph_expr(0); ev = ph_to_mixed(x, ph_ety); }
            ph_semi("expected ; after an enum case");
            ph_cfill(ph_stmt_of(ph_c3("php_enum_case", ph_ceref(ceg), ph_strlit(en, cstrlen(en)), ev, ty_pzv)));
            continue;
        }
        i64 nvis = 0;
        i64 nstat = 0;
        i64 nabs = 0;
        i64 nfin = 0;
        loop {
            i64 mfl2 = ph_tfile;
            i64 mln2 = ph_tline;
            if (ph_is("abstract")) { ph_next(); mflags = mflags | 1; nabs = nabs + 1;
                if (nabs > 1) ph_phpfatal(mfl2, mln2, "Multiple abstract modifiers are not allowed"); continue; }
            if (ph_is("final"))    { ph_next(); mflags = mflags | 2; nfin = nfin + 1;
                if (nfin > 1) ph_phpfatal(mfl2, mln2, "Multiple final modifiers are not allowed"); continue; }
            if (ph_is("readonly")) { ph_next(); mflags = mflags | 4; continue; }
            if (ph_is("static"))   { ph_next(); stat = 1; nstat = nstat + 1;
                if (nstat > 1) ph_phpfatal(mfl2, mln2, "Multiple static modifiers are not allowed"); continue; }
            i64 v = ph_visword();
            if (v >= 0) {
                vis = v;
                nvis = nvis + 1;
                if (nvis > 1) ph_phpfatal(mfl2, mln2, "Multiple access type modifiers are not allowed");
                continue;
            }
            break;
        }
        if (vis < 0) vis = V_PUBLIC;

        if (ph_is("const")) {
            ph_next();
            if (!ph_at("=", 1) && ph_is_typeword()) {
                // `const TYPE NAME = ...`, but `const NAME = ...` is the common shape
                uptr first = ph_tname;
                ph_next();
                if (ph_at("=", 1)) {
                    ph_want("=", 1, "expected = in a class constant");
                    i64 cv = ph_expr(0);
                    ph_cfill(ph_stmt_of(ph_c3("php_ce_const", ph_ceref(ceg), ph_strlit(first, cstrlen(first)),
                                              ph_to_mixed(cv, ph_ety), TY_VOID)));
                    loop {
                        if (!ph_accept(",", 1)) break;
                        uptr n2 = ph_tname;
                        ph_next();
                        ph_want("=", 1, "expected = in a class constant");
                        i64 cv2 = ph_expr(0);
                        ph_cfill(ph_stmt_of(ph_c3("php_ce_const", ph_ceref(ceg), ph_strlit(n2, cstrlen(n2)),
                                                  ph_to_mixed(cv2, ph_ety), TY_VOID)));
                    }
                    ph_semi("expected ; after a class constant");
                    continue;
                }
            }
            loop {
                uptr n3 = ph_tname;
                ph_next();
                ph_want("=", 1, "expected = in a class constant");
                i64 cv3 = ph_expr(0);
                ph_cfill(ph_stmt_of(ph_c3("php_ce_const", ph_ceref(ceg), ph_strlit(n3, cstrlen(n3)),
                                          ph_to_mixed(cv3, ph_ety), TY_VOID)));
                if (!ph_accept(",", 1)) break;
            }
            ph_semi("expected ; after a class constant");
            continue;
        }

        if (ph_is("function")) {
            ph_next();
            ph_accept("&", 1);
            if (ph_tid != T_IDENT) err_at2(mfl, mline, "mc-php: a php method needs a name", ph_tname);
            uptr mname = ph_tname;
            ph_next();
            uptr mcname = ph_mangle(cname, "m_");      // `\` is `$`, as for the class global
            mcname = p_cat(mcname, "_", 0, 1);
            mcname = p_cat(mcname, mname, 0, cstrlen(mname));
            mcname = p_cat(mcname, php_dec(ph_nonce), 0, cstrlen(php_dec(ph_nonce)));
            i64 isabs = 0;
            if (mflags & 1) isabs = 1;
            if (kind == 1) isabs = 1;
            i64 saves = ph_in_static;
            ph_in_static = stat;
            uptr savefn = ph_cur_fn;
            ph_cur_fn = mname;
            if (pub && stat) ph_todo2(mfl, mline, "a static method of a published class", mname);
            if (pub && isabs) ph_todo2(mfl, mline, "an abstract method of a published class", mname);
            ph_method_body(mcname, cname, ceg, vis, stat, mline, mfl, isabs);
            ph_cur_fn = savefn;
            ph_in_static = saves;
            if (pub) {
                if (ph_npm >= PH_MAXPM) err_at(mfl, mline, "mc-php: too many methods in a published class");
                st64(ph_pm_name + ph_npm * 8, mname);
                st64(ph_pm_fn + ph_npm * 8, mcname);
                st64(ph_pm_vis + ph_npm * 8, vis);
                st64(ph_pm_np + ph_npm * 8, ph_mb_np);
                st64(ph_pm_nreq + ph_npm * 8, ph_mb_nreq);
                i64 q = 0;
                loop { if (q >= ph_mb_np) break; st64(ph_pm_pn + (ph_npm * 6 + q) * 8, ld64(ph_mb_pn + q * 8)); q = q + 1; }
                ph_npm = ph_npm + 1;
            }
            if (!isabs) {
                // mc's N_ADDR carries the NAME itself (res_addr reads
                // nd_name of the node), not a child N_IDENT
                i64 fp = node_new(N_ADDR, mline, mfl);
                set_nd_name(fp, mcname);
                set_nd_type(fp, TY_UPTR);
                ph_cfill(ph_stmt_of(ph_c4("php_ce_method", ph_ceref(ceg), ph_strlit(mname, cstrlen(mname)),
                                          fp, ph_int(vis), TY_VOID)));
            }
            if (isabs)
                ph_cfill(ph_stmt_of(ph_c3("php_ce_absm", ph_ceref(ceg), ph_strlit(mname, cstrlen(mname)),
                                          ph_int(vis), TY_VOID)));
            if (movr) ph_ovr_check(ceg, cname, mname, 0, mfl, mline);
            continue;
        }

        // a property, with or without a declared type
        if (pub && stat) ph_todo2(mfl, mline, "a static property of a published class", cname);
        // its declared type is php's to enforce on every write (D9): recorded
        // here, and the class carries it (lib/php_rt.mc php_ce_ptype)
        i64 ptm = 0;
        uptr ptc = "";
        uptr ptn = "";
        if (!ph_at("$", 1)) {
            ph_rtype_read();
            if (ph_rtr_m || ld8(ph_rtr_cls)) {
                ptm = ph_rtr_m;
                ptc = ph_rtr_cls;
                ptn = ph_rtr_disp(ph_rtr_m, ph_rtr_cls);
                // a published class's properties are the engine's
                if (pub) ptm = 0;
                if (ptm & RT_STATIC && ph_cur_cls) {
                    if (ld8(ptc)) ptc = p_cat(ptc, "|", 0, 1);
                    ptc = p_cat(ptc, ph_cur_cls, 0, cstrlen(ph_cur_cls));
                }
                if (!ptm && !pub) ptm = 32768;
            }
        }
        if (!ph_at("$", 1)) ph_todo2(mfl, mline, "a php class member", ph_tname);
        loop {
            ph_next();
            if (ph_tid != T_IDENT) err_at(mfl, mline, "mc-php: a php property needs a name");
            uptr pname = ph_tname;
            ph_next();
            i64 def = ph_call("php_znull", 0, 0, 0, 0, 0, ty_pzv);
            // a typed property with no default starts uninitialized
            if (ptm && !(ptm & RT_MIXED)) def = ph_call("php_zuninit", 0, 0, 0, 0, 0, ty_pzv);
            if (ph_accept("=", 1)) {
                i64 dv = ph_expr(0);
                // an internal class's default is the engine's to keep for
                // the process: a scalar or a string, not an array
                if (pub && ph_ety != PT_INT && ph_ety != PT_FLOAT && ph_ety != PT_STRING && ph_ety != PT_BOOL && ph_ety != PT_NULL)
                    ph_todo2(mfl, mline, "a published class's property whose default is not a scalar", pname);
                i64 det = ph_ety;
                // php checks a typed property's default while compiling, and
                // turns an int into the float it declares
                if (ptm && !(ptm & RT_MIXED)) {
                    if (det == PT_INT && !(ptm & RT_INT) && (ptm & RT_FLOAT)) { dv = ph_to_float(dv, det); det = PT_FLOAT; }
                    ph_pdefault_check(ptm, ptn, det, cname, pname, mfl, mline);
                }
                def = ph_to_mixed(dv, det);
            }
            uptr fn = "php_ce_prop";
            if (stat) fn = "php_ce_sprop";
            ph_cfill(ph_stmt_of(ph_c4(fn, ph_ceref(ceg), ph_strlit(pname, cstrlen(pname)), def, ph_int(vis), TY_VOID)));
            if (ptm && !(ptm & RT_MIXED)) {
                u8 pta[40];
                st64(pta, ph_ceref(ceg));
                st64(pta + 8, ph_strlit(pname, cstrlen(pname)));
                st64(pta + 16, ph_int(ptm & 16383));
                st64(pta + 24, ph_strlit(ptc, cstrlen(ptc)));
                st64(pta + 32, ph_strlit(ptn, cstrlen(ptn)));
                ph_cfill(ph_stmt_of(ph_calln("php_ce_ptype", pta, 5, TY_VOID)));
            }
            // php reports a PROPERTY's #[\Override] at the CLASS's own line
            // and a method's at the method's (measured, php 8.5.10)
            if (mflags & 4)
                ph_cfill(ph_stmt_of(ph_c2("php_ce_ro", ph_ceref(ceg), ph_strlit(pname, cstrlen(pname)), TY_VOID)));
            if (movr) ph_ovr_check(ceg, cname, pname, 1, fl, line);
            if (!ph_accept(",", 1)) break;
        }
        ph_semi("expected ; after a php property");
    }
    ph_next();
    if (pub) { ph_ext_publish(cname, ceg, flags, fl, line); ph_npm = 0; }
    ph_cur_cls = savec;
    ph_cur_ceg = saveg;
}

// ---- a method body ---------------------------------------------------------
// Uniform shape so php_mcall can dispatch through one pointer: every
// parameter is a zval, the result is a zval, and an argument that was not
// passed arrives as 0 -- which is what makes a default value and
// ArgumentCountError both expressible without the caller knowing the arity.
void ph_method_body(uptr mcname, uptr cname, uptr ceg, i64 vis, i64 stat, i64 line, uptr fl, i64 abstract) {
    uptr savenv = ph_scope_save();
    // a method parsed inside a guarded branch starts with clean narrowing
    uptr snn = ph_narrow_name;
    i64 snt = ph_narrow_ty;
    ph_narrow_name = 0;
    ph_narrow_ty = 0;
    i64 hh = ph_hoist_head;
    i64 ht = ph_hoist_tail;
    i64 sret = ph_fn_ret;
    i64 srrm = ph_fn_retref;
    i64 sm = ph_in_method;
    ph_hoist_head = 0;
    ph_hoist_tail = 0;
    ph_fn_ret = PT_MIXED;
    ph_fn_retref = 0;
    i64 sfvm = ph_fn_void;
    ph_fn_void = 0;
    ph_in_method = 1;
    i64 stl = ph_toplevel;
    ph_toplevel = 0;
    i64 sls = ph_nls;
    ph_nls = 0;

    // EVERY method takes the receiver first, a static one too: every caller
    // in the runtime -- php_scall, php_mcall, __callStatic -- passes it
    // first, and a static method declared without the slot read its first
    // argument out of it, so `C::f($x)` said "Too few arguments" (found by
    // examples/decimal). Only the $this VARIABLE depends on `static`.
    i64 tp = param_new(TY_UPTR, "v_this");
    i64 head = tp;
    i64 tail = tp;
    if (!stat) ph_var_bind_raw("$this", PT_OBJ);
    ph_want("(", 1, "expected ( in a php method");
    i64 pre = 0;
    i64 pret = 0;
    i64 np = 0;
    // the parameters' names and the count before the first default, for a
    // published class (ph_mb_*: set at the END, after a nested class's body)
    u8 mbpn[48];
    i64 mbreq = -1;
    ph_ac_begin(p_cat(p_cat(cname, "::", 0, 2), ph_cur_fn, 0, cstrlen(ph_cur_fn)), fl);
    loop {
        if (ph_at(")", 1)) break;
        i64 pvis = -1;
        i64 pro = 0;
        loop {
            i64 v = ph_visword();
            if (v >= 0) { pvis = v; continue; }
            if (ph_is("readonly")) { ph_next(); pro = 1; if (pvis < 0) pvis = V_PUBLIC; continue; }
            break;
        }
        if (ph_at("...", 3)) ph_todo(fl, line, "a variadic parameter ...$args");
        i64 byref = 0;
        // the declared type was SKIPPED, so a typed method parameter was
        // bound as a plain zval with no check and no conversion
        // (docs/review-backlog.md section 2). The parameter stays a zval --
        // every method is reached through one callp signature -- and the
        // prologue coerces it with php's own non-strict rules.
        i64 pcw = 0;
        // a PROMOTED parameter's type is its property's too (php_ce_ptype)
        i64 prm = 0;
        uptr prc = "";
        uptr prn = "";
        i64 ptm = 0;
        if (!ph_at("$", 1) && !ph_at("&", 1)) {
            i64 dt = 0;
            if (pvis < 0) { dt = ph_param_type(); ptm = ph_ptm; }
            if (pvis >= 0) { ph_rtr_begin(); dt = ph_type_word(0); ptm = ph_rtr_m | 32768; }
            if (pvis >= 0) {
                ph_rtr_on = 0;
                if (!ph_rtr_bad && (ph_rtr_m || ld8(ph_rtr_cls)) && !(ph_rtr_m & RT_MIXED)) {
                    prm = ph_rtr_m | 32768;
                    prc = ph_rtr_cls;
                    prn = ph_rtr_disp(ph_rtr_m, ph_rtr_cls);
                }
            }
            if (dt == PT_INT)    pcw = 1;
            if (dt == PT_FLOAT)  pcw = 2;
            if (dt == PT_STRING) pcw = 3;
            if (dt == PT_BOOL)   pcw = 4;
            if (dt == PT_ARR)    pcw = 5;
        }
        if (ph_at("&", 1)) { ph_next(); byref = 1; }
        if (!ph_at("$", 1)) ph_todo2(fl, line, "a php parameter", ph_tname);
        i64 pln = ph_tline;
        ph_next();
        uptr d = p_cat("$", ph_tname, 0, cstrlen(ph_tname));
        ph_next();
        if (np >= 6) ph_todo(fl, line, "more than six parameters in a method");
        i64 dflt = 0;
        i64 dpre = 0;
        i64 dnul = 0;
        if (ph_accept("=", 1)) { i64 dv = ph_param_default(); dpre = ph_dflt_pre; dnul = ph_ety == PT_NULL; dflt = ph_to_mixed(dv, ph_ety); }
        st64(mbpn + np * 8, d + 1);
        if (dflt && mbreq < 0) mbreq = np;
        ph_var_bind_raw(d, PT_MIXED);
        // a by-reference method parameter costs nothing: every one of them is
        // already the caller's zval pointer, so marking it a ref is all that
        // is needed to make the callee write THROUGH it
        if (byref) ph_set_ref(d);
        i64 pn = param_new(TY_UPTR, ph_mangle(d, "v_"));
        if (tail) set_nd_next(tail, pn);
        if (!tail) head = pn;
        tail = pn;
        if (!byref) {
            i64 bv = ph_byval(d, line, fl);
            if (pret) set_nd_next(pret, bv);
            if (!pret) pre = bv;
            pret = bv;
        }
        if (pcw) {
            uptr bare2 = d + 1;
            i64 pv3 = node_new(N_IDENT, line, fl);
            set_nd_name(pv3, ph_mangle(d, "v_"));
            set_nd_type(pv3, ty_pzv);
            u8 pca[64];
            st64(pca, pv3);
            st64(pca + 8, ph_int(pcw));
            st64(pca + 16, ph_strlit(cname, cstrlen(cname)));
            st64(pca + 24, ph_strlit(ph_cur_fn, cstrlen(ph_cur_fn)));
            st64(pca + 32, ph_int(np + 1));
            st64(pca + 40, ph_strlit(bare2, cstrlen(bare2)));
            // the TypeError is placed at the parameter, as php places it
            uptr afl2 = ph_disp(ph_absfile(fl));
            st64(pca + 48, ph_strlit(afl2, cstrlen(afl2)));
            st64(pca + 56, ph_int(pln));
            // strict_types: the file the method is declared in, which is the
            // caller's whenever the two are one file
            st64(pca + 8, ph_int(pcw | ph_strict_bit(fl)));
            // a by-reference parameter IS the caller's cell, and php coerces
            // THAT: `m(int &$x)` with "5" leaves 6 in the caller's variable.
            // The plain call returns a new zval and the alias was silently
            // lost -- measured, the caller kept '5'.
            uptr pcfn = "php_param_coerce_at";
            if (byref) pcfn = "php_param_coerce_ref_at";
            i64 cz = ph_set(ph_mangle(d, "v_"), ph_calln(pcfn, pca, 8, ty_pzv));
            if (pret) set_nd_next(pret, cz);
            if (!pret) pre = cz;
            pret = cz;
        }
        // the prologue: a missing argument is 0
        i64 miss = node_new(N_UNARY, line, fl);
        set_nd_op(miss, ph_tok("!", 1));
        i64 pr = node_new(N_IDENT, line, fl);
        set_nd_name(pr, ph_mangle(d, "v_"));
        set_nd_type(pr, ty_pzv);
        set_nd_a(miss, pr);
        set_nd_type(miss, TY_U8);
        // a required one raises: ph_ac_end decides which are, and names the
        // METHOD in the message, not the mangled mc symbol
        i64 fill = 0;
        if (dflt) fill = ph_param_fill(ph_mangle(d, "v_"), dflt, dpre);
        i64 iff = node_new(N_IF, line, fl);
        set_nd_a(iff, miss);
        set_nd_b(iff, fill);
        if (pret) set_nd_next(pret, iff);
        if (!pret) pre = iff;
        pret = iff;
        ph_ac_param(iff, dflt != 0, ptm, dnul, d + 1, pln);
        // constructor promotion
        if (pvis >= 0) {
            uptr bare = d + 1;
            i64 pdef = ph_call("php_znull", 0, 0, 0, 0, 0, ty_pzv);
            if (prm) pdef = ph_call("php_zuninit", 0, 0, 0, 0, 0, ty_pzv);
            ph_cfill(ph_stmt_of(ph_c4("php_ce_prop", ph_ceref(ceg), ph_strlit(bare, cstrlen(bare)),
                                      pdef, ph_int(pvis), TY_VOID)));
            if (prm) {
                u8 pta2[40];
                st64(pta2, ph_ceref(ceg));
                st64(pta2 + 8, ph_strlit(bare, cstrlen(bare)));
                st64(pta2 + 16, ph_int(prm & 16383));
                st64(pta2 + 24, ph_strlit(prc, cstrlen(prc)));
                st64(pta2 + 32, ph_strlit(prn, cstrlen(prn)));
                ph_cfill(ph_stmt_of(ph_calln("php_ce_ptype", pta2, 5, TY_VOID)));
            }
            if (pro) ph_cfill(ph_stmt_of(ph_c2("php_ce_ro", ph_ceref(ceg), ph_strlit(bare, cstrlen(bare)), TY_VOID)));
            i64 pr2 = node_new(N_IDENT, line, fl);
            set_nd_name(pr2, ph_mangle(d, "v_"));
            set_nd_type(pr2, ty_pzv);
            i64 asg = ph_stmt_of(ph_c4("php_obj_set", ph_this(fl, line), ph_strlit(bare, cstrlen(bare)),
                                       pr2, ph_scope(), TY_VOID));
            set_nd_next(pret, asg);
            pret = asg;
        }
        np = np + 1;
        if (!ph_accept(",", 1)) break;
    }
    ph_want(")", 1, "expected ) in a php method");
    ph_ac_end();
    if (mbreq < 0) mbreq = np;
    i64 mrt = 0;
    i64 mrtw = PT_MIXED;
    if (ph_at(":", 1)) { ph_next(); mrtw = ph_rtype_read(); mrt = 1; }
    uptr srtm = ph_rt_save();
    ph_rt_set(mrt, p_cat(p_cat(cname, "::", 0, 2), ph_cur_fn, 0, cstrlen(ph_cur_fn)));
    // `return EXPR;` in a `: void` method is php's compile-time fatal too
    if (mrt && mrtw == PT_VOID) ph_fn_void = 1;
    if (abstract) {
        ph_accept(";", 1);
        if (ph_at("{", 1)) ph_block();
        ph_mb_np = np;
        ph_mb_nreq = mbreq;
        ph_scope_restore(savenv);
        ph_hoist_head = hh;
        ph_hoist_tail = ht;
        ph_fn_ret = sret;
        ph_fn_retref = srrm;
        ph_fn_void = sfvm;
        ph_rt_restore(srtm);
        ph_in_method = sm;
        return;
    }
    p_set_decl_name(mcname);
    // as in ph_function: php_argcount_n in the prologue must stop the method
    i64 sitm = ph_in_try;
    ph_in_try = 0;
    uptr sfrvm = ph_frv;
    uptr sffm = ph_frf;
    ph_frv = 0;
    ph_frf = 0;
    if (pre) pre = ph_prefix_stmts(pre, ph_check(line, fl));
    i64 body = ph_block();
    ph_in_try = sitm;
    ph_frv = sfrvm;
    ph_frf = sffm;
    if (pre) {
        i64 t = pre;
        loop { if (!nd_next(t)) break; t = nd_next(t); }
        set_nd_next(t, nd_a(body));
        set_nd_a(body, pre);
    }
    if (ph_hoist_head) {
        set_nd_next(ph_hoist_tail, nd_a(body));
        set_nd_a(body, ph_hoist_head);
    }
    // a php function with no explicit return answers null
    i64 t2 = nd_a(body);
    if (!t2) { set_nd_a(body, ph_ret_null(line, fl)); }
    if (t2) {
        loop { if (!nd_next(t2)) break; t2 = nd_next(t2); }
        set_nd_next(t2, ph_ret_null(line, fl));
    }
    i64 f = node_new(N_FUNC, line, fl);
    set_nd_name(f, mcname);
    set_nd_type(f, TY_UPTR);
    set_nd_a(f, head);
    set_nd_b(f, body);
    ph_rc_fn(f);
    ph_opt_fn(f);
    top_add(f);
    ph_scope_restore(savenv);
    ph_hoist_head = hh;
    ph_hoist_tail = ht;
    ph_fn_ret = sret;
    ph_fn_retref = srrm;
    ph_fn_void = sfvm;
    ph_rt_restore(srtm);
    ph_in_method = sm;
    ph_toplevel = stl;
    ph_nls = sls;
    ph_narrow_name = snn;
    ph_narrow_ty = snt;
    ph_mb_np = np;
    ph_mb_nreq = mbreq;
    i64 q = 0;
    loop { if (q >= np) break; st64(ph_mb_pn + q * 8, ld64(mbpn + q * 8)); q = q + 1; }
}


i64 ph_ret_null(i64 line, uptr fl) {
    i64 r = node_new(N_RETURN, line, fl);
    set_nd_a(r, ph_call("php_znull", 0, 0, 0, 0, 0, ty_pzv));
    // a declared return type the implicit null does not satisfy: php's
    // TypeError at the closing brace, `none returned` (`never` has its own)
    if (ph_fn_rtm && !(ph_fn_rtm & RT_VOID)) {
        i64 cl = ph_close_line;
        i64 ps = ph_posstmt(fl, cl);
        i64 nr = ph_stmt_of(ph_c4("php_ret_none_t", ph_strlit(ph_fn_rtq, cstrlen(ph_fn_rtq)),
                                  ph_strlit(ph_fn_rtn, cstrlen(ph_fn_rtn)),
                                  ph_int((ph_fn_rtm & RT_NEVER) != 0), ph_int(ph_fn_meth), TY_VOID));
        set_nd_next(ps, nr);
        set_nd_next(nr, r);
        return ps;
    }
    return r;
}

// $d->a->b = v / $d->m() / $d->a[k] = v, as a STATEMENT. The read of an
// intermediate step is materialised as it is walked; only the last step can
// be an lvalue.
i64 ph_obj_stmt(uptr d, uptr fl, i64 line, i64 semi) {
    i64 t = ph_var_type(d);
    i64 cur = node_new(N_IDENT, line, fl);
    set_nd_name(cur, ph_mangle(d, "v_"));
    set_nd_type(cur, ph_mcty(t));
    loop {
        if (!ph_at("->", 2) && !ph_at("?->", 3)) break;
        i64 ns = ph_at("?->", 3);
        ph_next();
        if (ph_at("$", 1) || ph_at("{", 1)) ph_refuse(fl, line, "a property name that is not a literal", "D6");
        if (ph_tid != T_IDENT) err_at2(fl, line, "mc-php: a php property needs a name", ph_tname);
        uptr pname = ph_tname;
        ph_next();
        i64 recv = ph_recv(cur, t);
        if (ph_at("(", 1)) {
            cur = ph_mcall_ns(recv, pname, fl, line, ns);
            t = PT_MIXED;
            continue;
        }
        if (ph_at("->", 2) || ph_at("?->", 3)) {
            uptr pgs = "php_zv_pget";
            if (ns) pgs = "php_zv_pget_ns";
            cur = ph_c3(pgs, recv, ph_strlit(pname, cstrlen(pname)), ph_scope(), ty_pzv);
            t = PT_MIXED;
            continue;
        }
        if (ph_at("[", 1)) {
            // $o->p[k]... : the property is used as an array in place
            i64 arr = ph_c3("php_zv_parr", recv, ph_strlit(pname, cstrlen(pname)), ph_scope(), ty_parr);
            loop {
                ph_want("[", 1, "expected [");
                i64 k = 0;
                if (!ph_at("]", 1)) k = ph_zkey(ph_expr(0), ph_ety);
                ph_want("]", 1, "expected ]");
                if (!ph_at("[", 1)) {
                    ph_want("=", 1, "expected = after a php property index");
                    i64 v = ph_expr(0);
                    i64 vt = ph_ety;
                    if (semi) ph_semi("expected ; after a php assignment");
                    return ph_expr_stmt_of(ph_store(arr, k, ph_to_mixed(ph_own(v, vt), vt), 0));
                }
                if (k)  arr = ph_c2("php_arr_dim", arr, k, ty_parr);
                if (!k) arr = ph_c1("php_arr_dimn", arr, ty_parr);
            }
        }
        // the last step: an assignment, a compound assignment or a read
        i64 op = 0;
        if (ph_at(".=", 2))  op = ph_tok(".", 1);
        if (ph_at("+=", 2))  op = ph_tok("+", 1);
        if (ph_at("-=", 2))  op = ph_tok("-", 1);
        if (ph_at("*=", 2))  op = ph_tok("*", 1);
        if (ph_at("/=", 2))  op = ph_tok("/", 1);
        if (ph_at("%=", 2))  op = ph_tok("%", 1);
        if (ph_at("**=", 3)) op = ph_tok("**", 2);
        i64 incdec = 0;
        if (ph_at("++", 2)) incdec = 1;
        if (ph_at("--", 2)) incdec = -1;
        if (ph_at("=", 1) || op || incdec) {
            i64 rt = ph_temp(recv, ty_pzv, "pho_");
            // every use of the property name needs its OWN node: nd_next is
            // the argument link, so one node in two argument lists is a CYCLE
            i64 v = 0;
            if (incdec) {
                ph_next();
                uptr f = "php_zv_inc";
                if (incdec < 0) f = "php_zv_dec";
                v = ph_c1(f, ph_c3("php_zv_pget", ph_tref(rt), ph_strlit(pname, cstrlen(pname)), ph_scope(), ty_pzv), ty_pzv);
            }
            if (!incdec && op) {
                ph_next();
                i64 r = ph_expr(0);
                i64 rrt = ph_ety;
                i64 old = ph_c3("php_zv_pget", ph_tref(rt), ph_strlit(pname, cstrlen(pname)), ph_scope(), ty_pzv);
                if (op == ph_tok(".", 1)) v = ph_c2("php_zv_concat", old, ph_to_mixed(r, rrt), ty_pzv);
                if (op != ph_tok(".", 1)) v = ph_arith_zv(op, old, PT_MIXED, r, rrt);
            }
            if (!incdec && !op) {
                ph_next();
                if (ph_at("&", 1))
                    return ph_ref_into(ph_c3("php_zv_pref", ph_tref(rt), ph_strlit(pname, cstrlen(pname)), ph_scope(), ty_pzv), fl, line, semi);
                i64 r2 = ph_expr(0);
                v = ph_to_mixed(ph_own(r2, ph_ety), ph_ety);
            }
            if (semi) ph_semi("expected ; after a php assignment");
            return ph_expr_stmt_of(ph_pset_node(ph_tref(rt), pname, v, ph_pset_kind(incdec, fl)));
        }
        cur = ph_c3("php_zv_pget", recv, ph_strlit(pname, cstrlen(pname)), ph_scope(), ty_pzv);
        t = PT_MIXED;
    }
    if (semi) ph_semi("expected ; after a php expression");
    return ph_expr_stmt_of(cur);
}


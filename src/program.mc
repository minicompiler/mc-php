// program.mc -- the one registration, and user_init.
// 
// Everything above hangs off syntax("<?php", &ph_program): one word
// registration owns the whole grammar, because a registration reserves its
// word for the entire program and php has about seventy keywords, which stay
// ordinary identifiers matched by str_eq. This also carries the byte scan
// that runs before the first token, and the #embed of lib/php_rt.mc.

// ---- the one registration --------------------------------------------------
void ph_program() {
    i64 line = ph_tline;
    uptr fl = p_file();
    ph_toplevel = 1;
    ph_entry = ph_absfile(fl);
    ph_fn_ret = PT_VOID;
    ph_fn_retref = 0;
    ph_sync();
    // `<?=` opens a file too, and it is an ECHO: leave it for the statement
    // loop below, which takes the echo branch on it
    if (!ph_at("<?=", 3)) ph_next();              // <?php
    // php's top-level scope is the global table: every name some function
    // declares `global` is its entry here, bound once, before anything runs
    ph_gtop_bind();
    loop {
        if (ph_tid == T_EOF) break;
        if (ph_ns_close()) continue;
        // namespaces and imports, php's rules (src/ns.mc): here and nowhere
        // else, since php only allows them at a file's top level
        if (ph_is("namespace")) { ph_ns_stmt(ph_tfile, ph_tline); continue; }
        if (ph_is("use")) { ph_ns_use_stmt(ph_tfile, ph_tline); continue; }
        if (ph_is("function")) {
            i64 fn = ph_function();
            top_add(fn);
            ph_ext_export(ph_last_fn, nd_file(fn), nd_line(fn));
            continue;
        }
        i64 s = ph_stmt_checked();
        if (ph_main_tail) set_nd_next(ph_main_tail, s);
        if (!ph_main_tail) ph_main_head = s;
        ph_main_tail = s;
        loop { if (!nd_next(ph_main_tail)) break; ph_main_tail = nd_next(ph_main_tail); }
    }
    // The tail, and it is the one place the two roads differ before the end.
    // A PROGRAM ends: an uncaught throwable is fatal, every surviving
    // __destruct runs (D7 has no refcount, so the end of the program is the
    // honest point) and the output buffer is emptied. A module's MINIT ends
    // no program -- phx_leave is the flush plus the bridge that turns a
    // pending php throwable into a Zend one, the same pair every handler
    // uses.
    i64 gp = ph_gtop_prologue();
    if (gp) {
        i64 gt = gp;
        loop { if (!nd_next(gt)) break; gt = nd_next(gt); }
        if (ph_main_head) set_nd_next(gt, ph_main_head);
        if (!ph_main_head) ph_main_tail = gt;
        ph_main_head = gp;
    }
    i64 fin = 0;
    i64 fin2 = 0;
    if (ph_ext) {
        fin = ph_stmt_of(ph_call("phx_leave", 0, 0, 0, 0, 0, TY_VOID));
        fin2 = fin;
    }
    if (!ph_ext) {
        fin = ph_stmt_of(ph_call("php_uncaught", 0, 0, 0, 0, 0, TY_VOID));
        i64 fin1 = ph_stmt_of(ph_call("php_shutdown", 0, 0, 0, 0, 0, TY_VOID));
        fin2 = ph_stmt_of(ph_call("php_flush", 0, 0, 0, 0, 0, TY_VOID));
        set_nd_next(fin, fin1);
        set_nd_next(fin1, fin2);
    }
    if (ph_main_tail) set_nd_next(ph_main_tail, fin);
    if (!ph_main_tail) ph_main_head = fin;
    i64 r = node_new(N_RETURN, line, fl);
    set_nd_a(r, ph_int(0));
    set_nd_next(fin2, r);
    // every class entry is created first, then filled: a class may extend one
    // that is declared later in the file, which php hoists too.
    if (ph_cfill_head) {
        if (ph_cnew_tail) set_nd_next(ph_cnew_tail, ph_cfill_head);
        if (!ph_cnew_tail) ph_cnew_head = ph_cfill_head;
        ph_cnew_tail = ph_cfill_tail;
    }
    // #[\Override] is checked once every class entry is filled: a class may
    // extend one declared later in the file, whose methods are not there yet
    if (ph_ovr_head) {
        if (ph_cnew_tail) set_nd_next(ph_cnew_tail, ph_ovr_head);
        if (!ph_cnew_tail) ph_cnew_head = ph_ovr_head;
    }
    i64 boot = ph_stmt_of(ph_call("php_bootstrap", 0, 0, 0, 0, 0, TY_VOID));
    set_nd_next(boot, ph_cnew_head);
    // every literal is built before anything can use one (ph_lit_finish)
    i64 lini = ph_stmt_of(ph_call("ph_lit_init", 0, 0, 0, 0, 0, TY_VOID));
    set_nd_next(lini, boot);
    ph_cnew_head = lini;
    if (ph_cnew_head) {
        i64 ct = ph_cnew_head;
        loop { if (!nd_next(ct)) break; ct = nd_next(ct); }
        set_nd_next(ct, ph_main_head);
        ph_main_head = ph_cnew_head;
    }
    if (ph_hoist_head) {
        set_nd_next(ph_hoist_tail, ph_main_head);
        ph_main_head = ph_hoist_head;
    }
    i64 b = node_new(N_BLOCK, line, fl);
    set_nd_a(b, ph_main_head);
    i64 f = node_new(N_FUNC, line, fl);
    set_nd_name(f, "main");
    set_nd_type(f, TY_I64);
    set_nd_b(f, b);
    // The extension road: the same statement stream becomes the module's
    // MINIT -- php_bootstrap, the class entries, a top-level `declare` or
    // `require` run when php loads the module -- and the handlers and
    // get_module go beside it. `main` does not exist in a .so.
    if (ph_ext) {
        set_nd_name(f, "mc_php_minit");
        i64 m0 = param_new(TY_I64, "mtype");
        i64 m1 = param_new(TY_I64, "mnum");
        set_nd_next(m0, m1);
        set_nd_a(f, m0);
    }
    // MCPHP_RC=check (src/rc.mc): the program counts its strings and poisons
    // one that reaches zero, `main` included; the first statement says so to
    // the runtime, before any string is built
    if (!ph_ext && ph_rcchk_mode) {
        i64 on = ph_set("ph_rcchk", ph_int(1));
        set_nd_next(on, nd_a(b));
        set_nd_a(b, on);
        ph_rc_fn(f);
    }
    ph_opt_fn(f);
    top_add(f);
    if (ph_ext) ph_ext_emit(fl, line);
    top_add(ph_lit_finish(fl, line));
}

// A .php the core lexer would meet before `<?php` is a named refusal, not a
// pile of stray identifiers: leading inline html has nowhere to go, because
// the module only gets control once a token has already been lexed.
i64 ph_ends(uptr s, uptr sfx) {
    i64 n = cstrlen(s);
    i64 m = cstrlen(sfx);
    if (m > n) return 0;
    return str_eq(s + n - m, sfx);
}

// the byte scan that finds every aliased name, before a token is lexed
i64 ph_nmb(i64 c, i64 first) {
    if (c >= 97 && c <= 122) return 1;
    if (c >= 65 && c <= 90) return 1;
    if (c == 95) return 1;
    if (!first && c >= 48 && c <= 57) return 1;
    return 0;
}

uptr ph_scan_name(uptr src, i64 len, uptr pi) {
    i64 i = ld64(pi);
    i64 st = i;
    loop { if (i >= len) break; if (!ph_nmb(ld8(src + i), i == st)) break; i = i + 1; }
    if (i == st) return 0;
    uptr o = xalloc(i - st + 2);
    st8(o, 36);
    i64 k = 0;
    loop { if (k >= i - st) break; st8(o + 1 + k, ld8(src + st + k)); k = k + 1; }
    st8(o + 1 + (i - st), 0);
    st64(pi, i);
    return o;
}

// The three source scans read BYTES, so a comment and a string literal look
// exactly like code to them. That is not only untidy: T8 measured it costing
// a D4 refusal, because `// array_splice(&$a, ...)` in the RUNTIME's own
// comments put `$a` in the ref set and made every `$a` in every program a
// zval. This hops over what is not code: `//`, `#` (but not `#[`), `/* */`
// and both quote forms. A `&$x` inside a double-quoted string is an
// interpolation and not a reference either, so skipping it is right too.
// A heredoc or nowdoc that opens at i (`<<<ID`, `<<<"ID"`, `<<<'ID'`): the
// index just past its closing identifier, 0 when i opens none. *now is 1 for
// a nowdoc, whose body interpolates nothing. The closing identifier is the
// first line that starts, after spaces and tabs, with the identifier and
// then a byte that cannot continue it (php 7.3's flexible syntax).
i64 ph_heredoc_end(uptr src, i64 len, i64 i, uptr now) {
    if (i + 3 >= len || ld8(src + i) != 60 || ld8(src + i + 1) != 60 || ld8(src + i + 2) != 60) return 0;
    i64 j = i + 3;
    loop { if (j >= len) break; if (ld8(src + j) != 32 && ld8(src + j) != 9) break; j = j + 1; }
    i64 q = 0;
    if (j < len && (ld8(src + j) == 39 || ld8(src + j) == 34)) { q = ld8(src + j); j = j + 1; }
    i64 s = j;
    loop { if (j >= len) break; if (!ph_nmb(ld8(src + j), j == s)) break; j = j + 1; }
    i64 n = j - s;
    if (n == 0) return 0;
    if (q) { if (j >= len || ld8(src + j) != q) return 0; j = j + 1; }
    st64(now, q == 39);
    // the body starts on the next line
    loop { if (j >= len) return len; if (ld8(src + j) == 10) break; j = j + 1; }
    loop {
        if (j >= len) return len;
        j = j + 1;                                   // past the newline
        i64 k = j;
        loop { if (k >= len) break; if (ld8(src + k) != 32 && ld8(src + k) != 9) break; k = k + 1; }
        if (k + n <= len && str_eq(xstrdup(src + k, n), xstrdup(src + s, n))
            && (k + n == len || !ph_nmb(ld8(src + k + n), 0)))
            return k + n;
        loop { if (j >= len) return len; if (ld8(src + j) == 10) break; j = j + 1; }
    }
    return len;
}

i64 ph_scan_hop(uptr src, i64 len, i64 i) {
    i64 c = ld8(src + i);
    // a heredoc or a nowdoc is text, as a quoted string is
    u8 hn[8];
    i64 he = ph_heredoc_end(src, len, i, hn);
    if (he) return he;
    if (c == 47 && i + 1 < len && ld8(src + i + 1) == 47) {
        i = i + 2;
        loop { if (i >= len) break; if (ld8(src + i) == 10) break; i = i + 1; }
        return i;
    }
    if (c == 35) {
        if (i + 1 < len && ld8(src + i + 1) == 91) return i;        // #[Attr]
        i = i + 1;
        loop { if (i >= len) break; if (ld8(src + i) == 10) break; i = i + 1; }
        return i;
    }
    if (c == 47 && i + 1 < len && ld8(src + i + 1) == 42) {
        i = i + 2;
        loop {
            if (i + 1 >= len) { i = len; break; }
            if (ld8(src + i) == 42 && ld8(src + i + 1) == 47) { i = i + 2; break; }
            i = i + 1;
        }
        return i;
    }
    if (c == 39 || c == 34) {
        i64 q = c;
        i = i + 1;
        loop {
            if (i >= len) break;
            i64 d = ld8(src + i);
            if (d == 92) { i = i + 2; continue; }
            if (d == q) { i = i + 1; break; }
            i = i + 1;
        }
        return i;
    }
    return i;
}

void ph_scan_refs(uptr src, i64 len) {
    i64 i = 0;
    loop {
        if (i >= len) break;
        i64 hop = ph_scan_hop(src, len, i);
        if (hop != i) { i = hop; continue; }
        i64 c = ld8(src + i);
        if (c == 38 && i + 1 < len && ld8(src + i + 1) == 36) {     // &$name
            u8 pb[8];
            st64(pb, i + 2);
            uptr n = ph_scan_name(src, len, pb);
            if (n) { ph_refset_add(n); i = ld64(pb); continue; }
        }
        if (c == 36 && i + 1 < len) {                               // $name++ / $name--
            u8 pb3[8];
            st64(pb3, i + 1);
            uptr n3 = ph_scan_name(src, len, pb3);
            if (n3) {
                i64 j3 = ld64(pb3);
                loop { if (j3 >= len) break; if (!ph_space(ld8(src + j3))) break; j3 = j3 + 1; }
                if (j3 + 1 < len) {
                    i64 c1 = ld8(src + j3);
                    if ((c1 == 43 || c1 == 45) && ld8(src + j3 + 1) == c1) ph_incset_add(n3);
                }
                i = ld64(pb3);
                continue;
            }
        }
        if ((c == 43 || c == 45) && i + 2 < len && ld8(src + i + 1) == c) {   // ++$name
            i64 j4 = i + 2;
            loop { if (j4 >= len) break; if (!ph_space(ld8(src + j4))) break; j4 = j4 + 1; }
            if (j4 < len && ld8(src + j4) == 36) {
                u8 pb4[8];
                st64(pb4, j4 + 1);
                uptr n4 = ph_scan_name(src, len, pb4);
                if (n4) { ph_incset_add(n4); i = ld64(pb4); continue; }
            }
        }
        if (c == 102 && i + 13 < len) {                             // func_num_args / func_get_arg
            if (ld8(src + i + 1) == 117 && ld8(src + i + 2) == 110 && ld8(src + i + 3) == 99
                && ld8(src + i + 4) == 95) ph_uses_nargs = 1;
        }
        if (c == 103 && i + 6 < len) {                              // global
            if (ld8(src + i + 1) == 108 && ld8(src + i + 2) == 111 && ld8(src + i + 3) == 98
                && ld8(src + i + 4) == 97 && ld8(src + i + 5) == 108 && !ph_nmb(ld8(src + i + 6), 0)) {
                i64 j = i + 6;
                loop {
                    loop { if (j >= len) break; if (!ph_space(ld8(src + j))) break; j = j + 1; }
                    if (j >= len || ld8(src + j) != 36) break;
                    u8 pb2[8];
                    st64(pb2, j + 1);
                    uptr n2 = ph_scan_name(src, len, pb2);
                    if (!n2) break;
                    ph_refset_add(n2);
                    ph_gset_add(n2);
                    j = ld64(pb2);
                    loop { if (j >= len) break; if (!ph_space(ld8(src + j))) break; j = j + 1; }
                    if (j < len && ld8(src + j) == 44) { j = j + 1; continue; }
                    break;
                }
                i = j;
                continue;
            }
        }
        i = i + 1;
    }
}

// pass 1 of the by-reference scan: which function names take one. A call may
// come before the declaration, so this is its own pass over the buffer.
void ph_scan_brf(uptr src, i64 len) {
    i64 i = 0;
    loop {
        if (i + 8 >= len) break;
        i64 hop = ph_scan_hop(src, len, i);
        if (hop != i) { i = hop; continue; }
        if (ld8(src + i) == 102 && ld8(src + i + 1) == 117 && ld8(src + i + 2) == 110
            && ld8(src + i + 3) == 99 && ld8(src + i + 4) == 116 && ld8(src + i + 5) == 105
            && ld8(src + i + 6) == 111 && ld8(src + i + 7) == 110
            && !ph_nmb(ld8(src + i + 8), 0) && (i == 0 || !ph_nmb(ld8(src + i - 1), 0))) {
            i64 j = i + 8;
            loop { if (j >= len) break; if (!ph_space(ld8(src + j))) break; j = j + 1; }
            if (j < len && ld8(src + j) == 38) {              // function &name()
                j = j + 1;
                loop { if (j >= len) break; if (!ph_space(ld8(src + j))) break; j = j + 1; }
            }
            i64 ns = j;
            loop { if (j >= len) break; if (!ph_nmb(ld8(src + j), j == ns)) break; j = j + 1; }
            if (j > ns) {
                uptr nm = xstrdup(src + ns, j - ns);
                loop { if (j >= len) break; if (!ph_space(ld8(src + j))) break; j = j + 1; }
                if (j < len && ld8(src + j) == 40) {
                    i64 d = 0;
                    i64 k = j;
                    i64 got = 0;
                    loop {
                        if (k >= len) break;
                        i64 c = ld8(src + k);
                        if (c == 40) d = d + 1;
                        if (c == 41) { d = d - 1; if (!d) break; }
                        if (c == 38 && k + 1 < len && ld8(src + k + 1) == 36) got = 1;
                        k = k + 1;
                    }
                    if (got) ph_brf_add(nm);
                    i = k;
                    continue;
                }
            }
            i = j;
            continue;
        }
        i = i + 1;
    }
}

// The declaration shape of every `function NAME (...)` in the source, so a
// call that comes BEFORE it can be built (php hoists a global function).
// This is ph_scan_brf's walk with the parameter list counted rather than only
// looked at for a `&$`: one pass, no second notion of where a header is.
void ph_scan_decl(uptr src, i64 len) {
    i64 i = 0;
    // the namespace a header is in: its declaration is `ns\name` (src/ns.mc)
    uptr sns = "";
    loop {
        if (i + 8 >= len) break;
        i64 hop = ph_scan_hop(src, len, i);
        if (hop != i) { i = hop; continue; }
        if (i + 10 < len && ld8(src + i) == 110 && (i == 0 || !ph_nmb(ld8(src + i - 1), 0))
            && str_eq(xstrdup(src + i, 9), "namespace") && (ph_space(ld8(src + i + 9)) || ld8(src + i + 9) == 123)) {
            i64 a = i + 9;
            loop { if (a >= len) break; if (!ph_space(ld8(src + a))) break; a = a + 1; }
            i64 b = a;
            loop { if (b >= len) break; i64 cb = ld8(src + b); if (!ph_nmb(cb, 0) && cb != 92) break; b = b + 1; }
            // `namespace X;`, `namespace X {`, and `namespace {`: the global one
            i64 cb2 = 0;
            if (b < len) cb2 = ld8(src + b);
            if (cb2 == 59 || cb2 == 123 || ph_space(cb2)) {
                if (b > a) sns = xstrdup(src + a, b - a);
                else if (cb2 == 123) sns = "";
            }
            i = b;
            continue;
        }
        if (ld8(src + i) == 102 && ld8(src + i + 1) == 117 && ld8(src + i + 2) == 110
            && ld8(src + i + 3) == 99 && ld8(src + i + 4) == 116 && ld8(src + i + 5) == 105
            && ld8(src + i + 6) == 111 && ld8(src + i + 7) == 110
            && !ph_nmb(ld8(src + i + 8), 0) && (i == 0 || !ph_nmb(ld8(src + i - 1), 0))) {
            i64 j = i + 8;
            loop { if (j >= len) break; if (!ph_space(ld8(src + j))) break; j = j + 1; }
            if (j < len && ld8(src + j) == 38) {              // function &name()
                j = j + 1;
                loop { if (j >= len) break; if (!ph_space(ld8(src + j))) break; j = j + 1; }
            }
            i64 ns = j;
            loop { if (j >= len) break; if (!ph_nmb(ld8(src + j), j == ns)) break; j = j + 1; }
            if (j == ns) { i = j + 1; continue; }             // `function (` -- a closure
            uptr nm = ph_ns_join(sns, xstrdup(src + ns, j - ns));
            loop { if (j >= len) break; if (!ph_space(ld8(src + j))) break; j = j + 1; }
            if (j >= len || ld8(src + j) != 40) { i = j; continue; }
            // walk the parameter list: one parameter per top-level comma plus
            // one if anything at all is there, `&` before a `$` at depth 1 is
            // by reference, `...` makes the last one variadic
            i64 d = 0;
            i64 k = j;
            i64 np = 0;
            i64 seen = 0;
            i64 prb = 0;
            i64 vrd = 0;
            loop {
                if (k >= len) break;
                i64 h2 = ph_scan_hop(src, len, k);
                if (h2 != k) { k = h2; continue; }
                i64 c = ld8(src + k);
                if (c == 40 || c == 91 || c == 123) d = d + 1;
                if (c == 41 || c == 93 || c == 125) {
                    d = d - 1;
                    if (!d) break;
                }
                if (d == 1 && k > j) {                    // not the `(` itself
                    if (c == 44) { np = np + 1; seen = 0; }
                    if (c == 38 && k + 1 < len && ld8(src + k + 1) == 36 && np < 63) prb = prb | (1 << np);
                    if (c == 46 && k + 2 < len && ld8(src + k + 1) == 46 && ld8(src + k + 2) == 46) vrd = 1;
                    if (!ph_space(c) && c != 44) seen = 1;
                }
                k = k + 1;
            }
            if (seen) np = np + 1;
            if (!seen && !np) np = 0;
            if (ph_ndecl < PH_MAXDECL && ph_decl_find(nm) < 0) {
                st64(ph_dn + ph_ndecl * 8, nm);
                st64(ph_dnp + ph_ndecl * 8, np);
                st64(ph_dpr + ph_ndecl * 8, prb);
                st64(ph_dvar + ph_ndecl * 8, vrd);
                ph_ndecl = ph_ndecl + 1;
            }
            i = k;
            continue;
        }
        i = i + 1;
    }
}

// pass 2: every $variable inside the parentheses of a call to one of them.
void ph_scan_brf_calls(uptr src, i64 len) {
    if (!ph_nbrf) return;
    i64 i = 0;
    loop {
        if (i >= len) break;
        i64 hop = ph_scan_hop(src, len, i);
        if (hop != i) { i = hop; continue; }
        if (ph_nmb(ld8(src + i), 1) && (i == 0 || !ph_nmb(ld8(src + i - 1), 0))) {
            i64 j = i;
            loop { if (j >= len) break; if (!ph_nmb(ld8(src + j), j == i)) break; j = j + 1; }
            uptr nm = xstrdup(src + i, j - i);
            i64 k = j;
            loop { if (k >= len) break; if (!ph_space(ld8(src + k))) break; k = k + 1; }
            if (k < len && ld8(src + k) == 40 && ph_brf_has(nm)) {
                i64 d = 0;
                loop {
                    if (k >= len) break;
                    i64 c = ld8(src + k);
                    if (c == 40) d = d + 1;
                    if (c == 41) { d = d - 1; if (!d) break; }
                    if (c == 36 && k + 1 < len) {
                        u8 pb[8];
                        st64(pb, k + 1);
                        uptr v = ph_scan_name(src, len, pb);
                        if (v) { ph_refset_add(v); k = ld64(pb); continue; }
                    }
                    k = k + 1;
                }
                i = k;
                continue;
            }
            i = j;
            continue;
        }
        i = i + 1;
    }
}

// ---- the checked reads (src/decls.mc ph_checked_reads, docs/semantics.md) -------
// `[php] checked_reads = true`, a TOML boolean; anything else is refused at its
// own position in the file (toml_err_key: mc's diagnostic over a key, the one
// name here that mc's tests/golden/surface.txt does not freeze).
void ph_checked_config() {
    uptr v = toml_get("php.checked_reads");
    if (!v) return;
    if (str_eq(v, "true")) { ph_checked_reads = 1; return; }
    if (str_eq(v, "false")) return;
    toml_err_key("php.checked_reads", "mc-php: expected true or false");
}

// `$GLOBALS` is refused by name, at its own line: php's view of the global
// table as an array is not built (the top level reaches the table through
// its variables, ph_gtop_bind). Comments, single-quoted strings and a
// nowdoc's body are not code; a double-quoted string or a heredoc
// interpolates, so it is searched.
void ph_scan_globals(uptr name, uptr src, i64 len) {
    i64 i = 0;
    loop {
        if (i >= len) break;
        i64 c = ld8(src + i);
        u8 hn[8];
        i64 he = ph_heredoc_end(src, len, i, hn);
        if (he && ld64(hn)) { i = he; continue; }       // a nowdoc
        if (he) { i = i + 3; continue; }                 // a heredoc: its body is searched
        if (c != 34) {
            i64 hop = ph_scan_hop(src, len, i);
            if (hop != i) { i = hop; continue; }
        }
        if (c == 36 && i + 8 <= len && str_eq(xstrdup(src + i + 1, 7), "GLOBALS")
            && (i + 8 == len || !ph_nmb(ld8(src + i + 8), 0))) {
            i64 line = 1;
            i64 j = 0;
            loop { if (j >= i) break; if (ld8(src + j) == 10) line = line + 1; j = j + 1; }
            ph_refuse2(name, line, "the global table as an array", "$GLOBALS", "D6");
        }
        i = i + 1;
    }
}

void ph_on_source(uptr name, uptr src, i64 len) {
    if (ph_pushing || ph_ends(name, ".php")) ph_scan_globals(name, src, len);
    ph_scan_decl(src, len);
    ph_scan_brf(src, len);
    ph_scan_refs(src, len);
    ph_scan_brf_calls(src, len);
    if (ph_pushing) return;                  // the body of a require: <?php already eaten
    if (!ph_ends(name, ".php")) return;
    if (len >= 5 && str_eq(xstrdup(src, 5), "<?php")) return;
    if (len >= 3 && str_eq(xstrdup(src, 3), "<?=")) return;
    ph_todo(name, 1, "a php file that does not open with <?php (leading inline html)");
}

i64 ph_dollar_expr() {
    err_at(p_file(), p_line(), "mc-php: a $variable outside a php expression");
    return 0;
}

#embed ph_tls "../lib/php_tls.mc"
#embed ph_rt "../lib/php_rt.mc"
#embed ph_prog_rt "../lib/php_prog.mc"

// The runtime's own system layer, one file per host: what a PROGRAM this
// compiler writes calls, which is not what the compiler calls. All four are
// embedded and one is pushed, chosen by host_os()/host_arch() -- there is no
// conditional compilation in this language, and a binary that carries four
// small files and picks one is smaller and far easier to prove than four
// compilers that each carry one.
//
// The choice is the HOST's because mc's default target is the host's
// (mc's M37): `mc-php --exe x.php` writes a binary for the machine it is
// running on, so the runtime's calls have to be that machine's.
#embed ph_rt_macos   "../lib/rt_host_macos.mc"
#embed ph_rt_linux   "../lib/rt_host_linux.mc"
#embed ph_rt_lin_a64 "../lib/rt_host_linux_aarch64.mc"
#embed ph_rt_lin_x64 "../lib/rt_host_linux_x86_64.mc"
#embed ph_rt_win     "../lib/rt_host_windows.mc"
#embed ph_rt_win_st  "../lib/rt_host_windows_start.mc"

// A push puts its source ON TOP of the lexer's stack, so the LAST push is the
// FIRST thing parsed (mc's p_push_source has #include's semantics, and it was
// measured with a control before anything rested on it: two embedded sources,
// one defining a `#define` the other uses, compile in one order and answer
// `unknown name` in the other).
//
// What that order is FOR is the `#define`s, and only those. php_rt.mc uses
// O_RDONLY, O_CREAT, S_IFDIR and the rest, and a `#define` must be parsed
// before its use -- so the runtime is pushed first and therefore lexed LAST,
// after a host layer that has them.
//
// A CALL needs no such order: mc binds one after the whole unit is parsed
// (which is why mc's own src/host_linux.mc may name mem_eq). So the two Linux
// halves may go in either order -- rt_host_linux_aarch64.mc calls stat() and
// rt_host_linux.mc declares it, and that is fine whichever is parsed first.
// tests/linux.sh is what says so rather than this comment: its smoke case
// calls is_dir, is_file and filesize, all three of which reach php_stat_mode
// and php_stat_size and therefore stat(), and it is green on both
// architectures.
// src with `from` replaced by `to`, as a new NUL-terminated buffer. `from`
// must occur EXACTLY once: a runtime source that lacks it, or has it twice,
// is this compiler's own bug and stops the build by name, never a silent
// half-swap (a ZTS output is its NTS source with these swaps and nothing else).
uptr ph_swap(uptr src, i64 n, uptr from, uptr to) {
    i64 fl = cstrlen(from);
    i64 tl = cstrlen(to);
    i64 at = 0 - 1;
    i64 i = 0;
    loop {
        if (i + fl > n) break;
        if (mem_eq(src + i, from, fl)) {
            if (at >= 0) err_at2("mc-php", 1, "mc-php: a ZTS swap's text occurs twice in the runtime source", from);
            at = i;
        }
        i = i + 1;
    }
    if (at < 0) err_at2("mc-php", 1, "mc-php: the runtime source lacks what a ZTS build swaps", from);
    uptr r = xalloc(n - fl + tl + 1);
    mem_copy(r, src, at);
    mem_copy(r + at, to, tl);
    mem_copy(r + at + tl, src + at + fl, n - at - fl);
    st8(r + n - fl + tl, 0);
    return r;
}

void ph_push_rt_host() {
    uptr os = host_os();
    if (str_eq(os, "macos")) {
        p_push_source("php runtime host", ph_rt_macos, ph_rt_macos_size);
        return;
    }
    // Windows: one file for both architectures -- nothing below it reads a
    // struct whose layout depends on the architecture (php_stat_* read
    // WIN32_FILE_ATTRIBUTE_DATA, which is the same on arm64 and x64). The
    // entry point is a second file because it names `main`, which an
    // extension does not have; pushed FIRST so it is parsed LAST, after the
    // host layer that declares ExitProcess.
    if (str_eq(os, "windows")) {
        if (!ph_ext) p_push_source("php runtime entry", ph_rt_win_st, ph_rt_win_st_size);
        // a ZTS php is php8ts.dll: the one name the host layer's php_dlsym
        // asks for is swapped in the SOURCE, so the NTS output is untouched
        if (ph_ext_zts) {
            uptr w = ph_swap(ph_rt_win, ph_rt_win_size, "GetModuleHandleA(\"php8.dll\"), name)", "GetModuleHandleA(\"php8ts.dll\"), name)");
            p_push_source("php runtime host", w, cstrlen(w));
            return;
        }
        p_push_source("php runtime host", ph_rt_win, ph_rt_win_size);
        return;
    }
    if (str_eq(os, "linux")) {
        p_push_source("php runtime host", ph_rt_linux, ph_rt_linux_size);
        uptr a = host_arch();
        if (str_eq(a, "aarch64")) {
            p_push_source("php runtime host arch", ph_rt_lin_a64, ph_rt_lin_a64_size);
            return;
        }
        if (str_eq(a, "x86_64")) {
            p_push_source("php runtime host arch", ph_rt_lin_x64, ph_rt_lin_x64_size);
            return;
        }
        err_at2("mc-php", 1, "mc-php: no runtime host layer for this linux architecture", a);
    }
    err_at2("mc-php", 1, "mc-php: no runtime host layer for this host", os);
}

void user_init() {
    ph_ext_config();
    ph_checked_config();
    ph_rc_env();
    phi_env();
    float_init();
    machine_arm64_float_init();
    machine_x86_64_float_init();
    ph_mach_init();
    ty_pstr = type_new("php_str", 8, 8, TK_INT);
    ty_parr = type_new("php_arr", 8, 8, TK_INT);
    ty_pzv  = type_new("php_zval", 8, 8, TK_INT);
    ph_tokens();
    ph_lib_init();
    ph_pre_init();
    ph_brf_init();
    syntax_expr("$", &ph_dollar_expr);            // makes `$name` lex as `$` + name
    on_source(&ph_on_source);
    syntax("<?php", &ph_program);
    syntax("<?=", &ph_program);                   // a file may open with it
    // The extension runtime names _emalloc, zend_type_error and two more
    // that exist inside a running php and nowhere else, so it is pushed only
    // on the road where they resolve. FIRST, so it is parsed LAST of the
    // three: a push is a stack, and php_ext.mc reads the runtime's own
    // globals (ph_exc) -- a call binds after the whole unit is parsed, a
    // GLOBAL has to be declared before the line that names it.
    // A ZTS output (lib/php_zts.mc, docs/threads.md § ZTS) is the NTS runtime
    // with the swaps below and nothing else, plus php_zts.mc, parsed after
    // php_ext.mc whose globals and #defines it names. Each swap's text must
    // occur exactly once (ph_swap).
    if (ph_ext && ph_ext_zts) {
        p_push_source("php extension zts", ph_zts_rt, ph_zts_rt_size);
        // RSHUTDOWN copies MINIT's arena back over what a request changed; in
        // a ZTS module nothing a request does writes that arena, and other
        // threads are reading it
        uptr e = ph_swap(ph_ext_rt, ph_ext_rt_size, "if (ld64(phT + PHT_phx_dirty)) {", "if (ld64(phT + PHT_phx_dirty) && 0) {");
        // RINIT enters a call to copy MINIT's state, which leaves the call's
        // home chunk behind, and the fast path takes any entry with a home:
        // it would never reach the slow path's one-time measurement of
        // EG(exception), which RINIT cannot make (no script runs yet). On
        // Windows the measured offset is not the headers' 960, so the fast
        // path waits for it.
        e = ph_swap(e, cstrlen(e), "if (ph_boot_done && !ld64(phT + PHT_phx_depth)", "if (ph_boot_done && phx_egx_ok() && !ld64(phT + PHT_phx_depth)");
        p_push_source("php extension runtime", e, cstrlen(e));
        // the booting thread's fast path never comes back (several php threads
        // run the module at once), a thread's block carries the ZTS words, and
        // a static property is this request's
        uptr r = ph_swap(ph_rt, ph_rt_size, "i64 outer = !ld64(phT + PHT_ph_tidx);", "i64 outer = 0;");
        r = ph_swap(r, cstrlen(r), "uptr php_thr_block(uptr from, i64 idx) {", "uptr php_thr_block_nts(uptr from, i64 idx) {");
        r = ph_swap(r, cstrlen(r), "uptr php_ce_sslot_s(uptr ce, uptr name, uptr scope) {", "uptr php_ce_sslot_s_nts(uptr ce, uptr name, uptr scope) {");
        // a php callable on a thread: a ZTS php can give it a context of its
        // own, which is threads step 3b and not built yet
        r = ph_swap(r, cstrlen(r), "a php callable cannot run on another thread in a php without thread safety; build the module with thread_safety = \\\"zts\\\", or pass a compiled function",
                    "a php callable cannot run on another thread yet: its own php context on the worker is threads step 3b; pass a compiled function");
        p_push_source("php runtime", r, cstrlen(r));
        ph_push_rt_host();
        uptr t = ph_swap(ph_tls, ph_tls_size, "#define PHT_SIZE 12344\n", "#define PHT_SIZE 12464\n");
        p_push_source("php thread block", t, cstrlen(t));
        pass(&ph_tls_pass);
        return;
    }
    if (ph_ext) p_push_source("php extension runtime", ph_ext_rt, ph_ext_rt_size);
    if (!ph_ext) p_push_source("php program allocator", ph_prog_rt, ph_prog_rt_size);
    p_push_source("php runtime", ph_rt, ph_rt_size);
    ph_push_rt_host();
    // the thread block's layout: pushed last, so parsed first -- every
    // PHT_* the runtime names is a #define (src/tls.mc)
    p_push_source("php thread block", ph_tls, ph_tls_size);
    pass(&ph_tls_pass);
}

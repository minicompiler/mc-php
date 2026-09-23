// stmt.mc -- statements, unwinding, and the line php reports.
// 
// There is no VM and no setjmp (docs/plan.md D7), so unwinding is a pending
// exception flag the compiler checks after every statement that can throw.
// The check goes BETWEEN computing a value and using it. The diagnostic
// position is php's own: the line a php error names is not always the line
// the statement started on.

// ---- unwinding -------------------------------------------------------------
void ph_ls_push(i64 kind) {
    if (ph_nls >= PH_MAXLS) err_at(ph_tfile, ph_tline, "mc-php: loops nested too deep");
    st64(ph_lstack + ph_nls * 8, kind);
    ph_nls = ph_nls + 1;
}

void ph_ls_pop() { if (ph_nls) ph_nls = ph_nls - 1; }

// the mc break level for a php level of n LOOPS
// how many mc loop levels out the nearest enclosing TRY wrapper is, 0 when
// there is none: what a `return` inside a try has to break out to so the
// finally still runs (docs/review-backlog.md section 2).
i64 ph_ls_try() {
    i64 lv = 0;
    i64 i = ph_nls - 1;
    loop {
        if (i < 0) return 0;
        lv = lv + 1;
        if (ld64(ph_lstack + i * 8)) return lv;
        i = i - 1;
    }
    return 0;
}

i64 ph_ls_level(i64 n, uptr fl, i64 line) {
    i64 want = n;
    i64 lv = 0;
    i64 i = ph_nls - 1;
    loop {
        if (i < 0) break;
        lv = lv + 1;
        if (!ld64(ph_lstack + i * 8)) {
            want = want - 1;
            if (want == 0) return lv;
        }
        i = i - 1;
    }
    return lv;
}

// the propagation check emitted after a statement that can throw: break out
// of the innermost try, or leave the function
// php parameters are BY VALUE: `function f($x) { $x[] = 2; }` must not touch
// the caller's array (docs/review-backlog.md section 2). A zval parameter
// arrives as the caller's own zval pointer, which is what a by-REFERENCE
// parameter wants and what every other one must not have, so the callee
// copies it once in its prologue -- `php_zv_val` is the same value copy an
// assignment makes (ph_own), deep for an array and a handle for an object.
// It is done in the CALLEE and not at the call site so that every road into
// the function -- a direct call, a forward call, a closure, a method -- pays
// it exactly once and none of them can forget.
i64 ph_byval(uptr d, i64 line, uptr fl) {
    i64 pr = node_new(N_IDENT, line, fl);
    set_nd_name(pr, ph_mangle(d, "v_"));
    set_nd_type(pr, ty_pzv);
    i64 pr2 = node_new(N_IDENT, line, fl);
    set_nd_name(pr2, ph_mangle(d, "v_"));
    set_nd_type(pr2, ty_pzv);
    i64 iff = node_new(N_IF, line, fl);
    set_nd_a(iff, ph_truthy(pr));
    set_nd_b(iff, ph_set(ph_mangle(d, "v_"), ph_c1("php_zv_val", pr2, ty_pzv)));
    return iff;
}

i64 ph_check(i64 line, uptr fl) {
    i64 cond = ph_call("php_thrown", 0, 0, 0, 0, 0, TY_I64);
    i64 act = 0;
    if (ph_in_try) {
        act = node_new(N_BREAK, line, fl);
        set_nd_val(act, 1);
    }
    if (!ph_in_try && ph_toplevel) act = ph_stmt_of(ph_call("php_uncaught", 0, 0, 0, 0, 0, TY_VOID));
    if (!ph_in_try && !ph_toplevel) {
        act = node_new(N_RETURN, line, fl);
        if (ph_fn_ret == PT_MIXED) set_nd_a(act, ph_call("php_znull", 0, 0, 0, 0, 0, ty_pzv));
        if (ph_fn_ret == PT_INT || ph_fn_ret == PT_BOOL || ph_fn_ret == PT_IFALSE) set_nd_a(act, ph_int(0));
        if (ph_fn_ret == PT_FLOAT) set_nd_a(act, ph_cast(ty_f64, ph_int(0)));
        if (ph_fn_ret == PT_STRING) set_nd_a(act, ph_strlit("", 0));
        if (ph_fn_ret == PT_ARR) set_nd_a(act, ph_c1("php_arr_new", ph_int(8), ty_parr));
    }
    i64 iff = node_new(N_IF, line, fl);
    set_nd_a(iff, ph_cast(TY_U8, cond));
    set_nd_b(iff, act);
    return iff;
}

// ---- statements ------------------------------------------------------------
// the pending statements an expression asked for (an array literal, var_dump)
// the pending statements are SPLICED into the enclosing list, never wrapped in
// a block: a block would scope what they declare (see ph_local).
i64 ph_wrap(i64 s) {
    if (!ph_pend_head) return s;
    i64 h = ph_pend_head;
    i64 t = ph_pend_tail;
    ph_pend_head = 0;
    ph_pend_tail = 0;
    set_nd_next(t, s);
    return h;
}

i64 ph_expr_stmt_of(i64 e) {
    i64 s = node_new(N_EXPRSTMT, ph_tline, ph_tfile);
    set_nd_a(s, e);
    return ph_wrap(s);
}

i64 ph_empty() { return node_new(N_BLOCK, ph_tline, ph_tfile); }

// a run of inline html between ?> and <?php, and the statement that prints it
i64 ph_inline_html(uptr fl, i64 line) {
    uptr q = p_cp();
    uptr e = p_src_end();
    uptr start = q;
    if (q < e && ld8(q) == 10) start = q + 1;                 // php eats one \n after ?>
    if (q + 1 < e && ld8(q) == 13 && ld8(q + 1) == 10) start = q + 2;
    uptr stop = e;
    uptr nxt = e;
    loop {
        if (q + 4 >= e) break;
        if (ld8(q) == 60 && ld8(q + 1) == 63) {               // <?
            if (ld8(q + 2) == 112 && ld8(q + 3) == 104 && ld8(q + 4) == 112) { stop = q; nxt = q + 5; break; }
            // `<?=` is an ECHO, so it is LEFT for the statement loop; only
            // `<?php` is skipped over (docs/review-backlog.md section 2)
            if (ld8(q + 2) == 61) { stop = q; nxt = q; break; }
        }
        q = q + 1;
    }
    if (stop == e) { if (q + 4 >= e) stop = e; }
    i64 n = stop - start;
    if (n < 0) n = 0;
    p_skip_to(nxt);
    ph_tid = PHT_HTML;
    ph_tname = xstrdup(start, n);
    ph_tlen = n;
    if (n == 0) { ph_next(); return ph_empty(); }
    i64 c = ph_c1("php_echo_str", ph_strlit(ph_tname, n), TY_I64);
    ph_next();
    i64 s = node_new(N_EXPRSTMT, line, fl);
    set_nd_a(s, c);
    return s;
}

// ---- the position php's diagnostics report ---------------------------------
// php prints "in FILE on line N", and FILE is the path php RESOLVED, so a
// relative argument comes out absolute. The compiler stores the pair into two
// runtime globals once per statement (php_pos); threading a file and a line
// through all 173 library rows instead would touch every one of them.
//
// Known and written down in RESULTS.md: a diagnostic raised after a user
// function RETURNED, inside the same statement, reports the line that callee
// last set. A statement whose warning comes before any user call -- which is
// nearly all of them -- is exact.
// realpath is <mc/host>'s own extern (src/host_macos.mc) -- not redeclared
#define PH_MAXFL 64
uptr ph_flsrc[PH_MAXFL];
uptr ph_flabs[PH_MAXFL];
i64  ph_nfl;

uptr ph_absfile(uptr fl) {
    i64 i = 0;
    loop {
        if (i >= ph_nfl) break;
        if (str_eq(ld64(ph_flsrc + i * 8), fl)) return ld64(ph_flabs + i * 8);
        i = i + 1;
    }
    uptr a = fl;
    if (ld8(fl) != 47) {
        uptr cwd = host_getcwd();
        if (cwd) a = path_norm(path_join(p_cat(cwd, "/x", 0, 2), fl));
    }
    // php reports the path it RESOLVED, symlinks included: on macOS /tmp is a
    // link to /private/tmp and every diagnostic raised by a script under it
    // printed the wrong one of the two. T8: one realpath(3), at compile time.
    uptr rp = xalloc(4200);
    if (realpath(a, rp)) a = rp;
    if (ph_nfl < PH_MAXFL) {
        st64(ph_flsrc + ph_nfl * 8, fl);
        st64(ph_flabs + ph_nfl * 8, a);
        ph_nfl = ph_nfl + 1;
    }
    return a;
}

i64 ph_posstmt(uptr fl, i64 line) {
    uptr a = ph_absfile(fl);
    i64 c = ph_c2("php_pos", ph_raw(a, cstrlen(a)), ph_int(line), TY_VOID);
    i64 s = node_new(N_EXPRSTMT, line, fl);
    set_nd_a(s, c);
    return s;
}

// A CONDITION that can throw has to be checked before the branch is taken:
// `if (throws()) { a(); } else { b(); }` must run neither arm, and the check
// appended after the whole statement (ph_stmt_checked) is too late -- the
// `if` has already chosen (docs/review-backlog.md section 2). T6's rule is
// that the check goes BETWEEN computing a value and using it, so the value
// becomes a temporary and the check goes after it.
//
// It costs nothing when the condition contains no call: ph_can_throw is 0
// and the condition node is returned untouched, so every `while ($i < 10)`
// in the corpus lowers exactly as it did.
i64 ph_cond_checked(i64 c, i64 line, uptr fl) {
    if (!ph_can_throw) return c;
    i64 tmp = ph_temp(c, TY_U8, "phk_");
    ph_pending_stmt(ph_check(line, fl));
    return ph_tref(tmp);
}

// a statement, followed by the unwinding check when it contains a call
i64 ph_stmt_checked() {
    i64 save = ph_can_throw;
    ph_can_throw = 0;
    i64 line = ph_tline;
    uptr fl = ph_tfile;
    i64 st = ph_stmt();
    if (ph_can_throw) {
        i64 t = st;
        loop { if (!nd_next(t)) break; t = nd_next(t); }
        set_nd_next(t, ph_check(line, fl));
    }
    ph_can_throw = save;
    return st;
}

i64 ph_block() {
    i64 line = ph_tline;
    uptr fl = ph_tfile;
    ph_want("{", 1, "expected { in php");
    i64 head = 0;
    i64 tail = 0;
    loop {
        if (ph_at("}", 1)) break;
        if (ph_tid == T_EOF) err_at(fl, line, "mc-php: unterminated php block");
        i64 s = ph_stmt_checked();
        if (tail) set_nd_next(tail, s);
        if (!tail) head = s;
        tail = s;
        loop { if (!nd_next(tail)) break; tail = nd_next(tail); }
    }
    ph_next();
    i64 b = node_new(N_BLOCK, line, fl);
    set_nd_a(b, head);
    return b;
}

// The alternative syntax: `if (c): ... endif;`, and the same for while, for,
// foreach and switch. It is the SAME statement list a `{ }` holds -- only the
// delimiters differ -- so this is ph_block's loop with a word for its `}`.
// `if` also stops at `elseif`/`else`, which the caller then reads.
i64 ph_alt_body(uptr endw, i64 forif) {
    i64 line = ph_tline;
    uptr fl = ph_tfile;
    i64 head = 0;
    i64 tail = 0;
    loop {
        if (ph_is(endw)) break;
        if (forif && (ph_is("elseif") || ph_is("else"))) break;
        if (ph_tid == T_EOF) err_at2(fl, line, "mc-php: unterminated alternative block, expected", endw);
        i64 s = ph_stmt_checked();
        if (tail) set_nd_next(tail, s);
        if (!tail) head = s;
        tail = s;
        loop { if (!nd_next(tail)) break; tail = nd_next(tail); }
    }
    i64 b = node_new(N_BLOCK, line, fl);
    set_nd_a(b, head);
    return b;
}

// the closing word and its `;`
void ph_alt_end(uptr endw) {
    if (!ph_is(endw)) err_at2(ph_tfile, ph_tline, "mc-php: expected", endw);
    ph_next();
    ph_accept(";", 1);
}

i64 ph_block_or_stmt() {
    if (ph_at("{", 1)) return ph_block();
    i64 line = ph_tline;
    uptr fl = ph_tfile;
    i64 s = ph_stmt_checked();
    i64 b = node_new(N_BLOCK, line, fl);
    set_nd_a(b, s);
    return b;
}

// `continue` jumps to the top of an mc `loop`, so a step appended after the
// body would be SKIPPED by it -- an infinite loop, measured on
// `for (...; $i++) { if (c) continue; }`. The step therefore runs at the TOP,
// guarded by a first-iteration flag, which is the one lowering where every
// edge into the next iteration passes through it.
// A loop CONDITION may need statements of its own -- `while (($n = f()) < 4)`
// and any condition with a call that can throw -- and they have to run on
// every iteration, after the step and before the test. ph_cpre carries them
// from the caller, which is the only place that knows the condition is a
// condition.
i64 ph_cpre;

i64 ph_loop_of(i64 cond, i64 body, i64 step, i64 line, uptr fl) {
    i64 pre = 0;
    if (step) {
        ph_nonce = ph_nonce + 1;
        uptr fn = p_cat("phl_f", php_dec(ph_nonce), 0, cstrlen(php_dec(ph_nonce)));
        ph_local(fn, TY_I64);
        pre = ph_set(fn, ph_int(1));                 // spliced in before the loop, below
        i64 fref = node_new(N_IDENT, line, fl);
        set_nd_name(fref, fn);
        set_nd_type(fref, TY_I64);
        i64 clr = ph_set(fn, ph_int(0));
        i64 gate = node_new(N_IF, line, fl);
        set_nd_a(gate, fref);
        set_nd_b(gate, clr);
        set_nd_c(gate, step);
        step = 0;
        i64 hold = body;                             // gate, then the old body
        body = gate;
        set_nd_next(gate, hold);
        ph_loop_pre = pre;
    }
    i64 neg = node_new(N_UNARY, line, fl);
    set_nd_op(neg, ph_tok("!", 1));
    set_nd_a(neg, cond);
    set_nd_type(neg, TY_U8);
    i64 brk = node_new(N_BREAK, line, fl);
    set_nd_val(brk, 1);
    i64 iff = node_new(N_IF, line, fl);
    set_nd_a(iff, neg);
    set_nd_b(iff, brk);
    // the condition's own statements, on every iteration, after the step and
    // before the test. `test` stays the node the body is linked after; `chk`
    // is what gets spliced in.
    i64 chk = iff;
    if (ph_cpre) {
        i64 cp = ph_cpre;
        ph_cpre = 0;
        i64 ct = cp;
        loop { if (!nd_next(ct)) break; ct = nd_next(ct); }
        set_nd_next(ct, iff);
        chk = cp;
    }
    // body already begins with the step gate when there is a step
    i64 first = body;
    if (nd_kind(body) == N_IF && ph_loop_pre) {
        // the gate is first; the condition test goes between it and the body
        i64 rest = nd_next(body);
        set_nd_next(body, chk);
        set_nd_next(iff, rest);
        first = body;
    }
    if (!ph_loop_pre) {
        set_nd_next(iff, body);
        first = chk;
    }
    i64 b = node_new(N_BLOCK, line, fl);
    set_nd_a(b, first);
    i64 lp = node_new(N_LOOP, line, fl);
    set_nd_a(lp, b);
    if (ph_loop_pre) {
        i64 pr = ph_loop_pre;
        ph_loop_pre = 0;
        set_nd_next(pr, lp);
        i64 ob = node_new(N_BLOCK, line, fl);
        set_nd_a(ob, pr);
        return ob;
    }
    return lp;
}


// php.mc -- T4's measuring instrument: how much of PHP's grammar Tier 3 takes.
//
// Not a compiler. It exists to answer `docs/plan.md` section 4 row T4 with a
// yes or a no per construct, so RESULTS.md can say where Tier 3 stops and why.
// The runtime under it is the crudest thing that runs: i64 for int, uptr for
// string, one write() per echo. The PARSER is what is being measured.
//
// The shape it measures is "one entry point owns the whole grammar":
//   syntax("<?php", &ph_program) is the ONE word registration. Every PHP
//   keyword stays an ordinary identifier and is recognised by str_eq, because
//   a registration reserves its word for the whole program and PHP has ~70 of
//   them. The expression grammar is the module's own (PHP's precedence is not
//   mc's, and $x can never reach parse_primary -- see RESULTS.md).

#define PH_MAXVAR 256

uptr ph_vname[PH_MAXVAR];      // the php spelling, `$x`
i64  ph_vtype[PH_MAXVAR];      // the type its FIRST assignment gave it (D4)
uptr ph_vwhere[PH_MAXVAR];     // file:line of that first assignment, for the error
i64  ph_nvar;

i64  ph_main_head;
i64  ph_main_tail;
i64  ph_in_func;               // 0 at top level: statements go into main()
i64  ph_nonce;                 // unique suffix for generated names

// ---- the punctuation the core does not have -------------------------------
// Measured in probes/t4/lex: every one of these is a plain tok_add away. The
// three the lexer keeps for itself are ' and # and the number formats.
void ph_tokens() {
    tok_add("<?php", 5);
    tok_add("?>",  2);
    tok_add("?->", 3);
    tok_add("??=", 3);
    tok_add("??",  2);
    tok_add("::",  2);
    tok_add("**",  2);
    tok_add("...", 3);
    tok_add("<=>", 3);
    tok_add("<<<", 3);
    tok_add(".=",  2);
    tok_add("->",  2);
    tok_add("<>",  2);
    tok_add("\\",  1);
    tok_add("+=",  2);
    tok_add("-=",  2);
    tok_add("&&",  2);
    tok_add("||",  2);
    tok_add("===", 3);
    tok_add("!==", 3);
    tok_add("++",  2);
}

// word_id only answers for ALPHA-initial lexemes (te_word); punctuation has to
// go through tok_add, which is idempotent and returns the existing id.
i64 ph_tok(uptr s, i64 n) { return tok_add(s, n); }

// ---- the in-place rewrite --------------------------------------------------
// on_source hands over the buffer the lexer is about to read. Two bytes are
// unreachable from Tier 3 and both are fixed here, byte for byte so that every
// line and column -- and therefore every err_at -- is the source's own:
//   '   mc lexes a char literal ('x' is silently the integer 120)
//   #   mc lexes a directive (`unknown directive`)
// This is the workaround, not the answer: see RESULTS.md and docs/plan.md.
i64 ph_ends(uptr s, uptr sfx) {
    i64 n = cstrlen(s);
    i64 m = cstrlen(sfx);
    if (m > n) return 0;
    return str_eq(s + n - m, sfx);
}

void ph_rewrite(uptr name, uptr src, i64 len) {
    if (!ph_ends(name, ".php")) return;
    i64 i = 0;
    i64 indq = 0;
    loop {
        if (i >= len) break;
        i64 c = ld8(src + i);
        if (c == 34) indq = !indq;
        if (!indq) {
            if (c == 39) st8(src + i, 34);              // ' -> "
            if (c == 35) {                              // # comment -> // comment
                st8(src + i, 47);
                if (i + 1 < len) {
                    i64 d = ld8(src + i + 1);
                    if (d == 10) st8(src + i, 32);      // a bare # : blank it
                    if (d != 10) st8(src + i + 1, 47);
                }
                loop {                                  // to end of line
                    if (i >= len) break;
                    if (ld8(src + i) == 10) break;
                    i = i + 1;
                }
            }
        }
        i = i + 1;
    }
}

i64 ph_claim(uptr name) { return ph_ends(name, ".php"); }

// ---- small helpers ---------------------------------------------------------
// A php keyword that is ALSO an mc core keyword (if, else, return, break,
// continue) arrives as its K_* id and never as T_IDENT, so the test is on the
// LEXEME and not on the token class -- with the three classes whose lexeme is
// not a name excluded, so the string "return" is not a keyword.
i64 ph_is(uptr w) {
    i64 t = p_id();
    if (t == T_STR)  return 0;
    if (t == T_CHAR) return 0;
    if (t == T_HOLE) return 0;
    if (t == T_INT)  return 0;
    return str_eq(p_name(), w);
}

void ph_eat(uptr w, uptr msg) {
    if (!ph_is(w)) err_at2(p_file(), p_line(), msg, w);
    p_next();
}

i64 ph_int(i64 v) {
    i64 n = node_new(N_INT, p_line(), p_file());
    set_nd_val(n, v);
    set_nd_type(n, TY_I64);
    return n;
}

// the mc-level name of a php variable: `$x` becomes `v_x`, so a php variable
// and a php function of the same spelling cannot collide.
uptr ph_mangle(uptr d, uptr pfx) {
    i64 n = cstrlen(d);
    i64 skip = 0;
    if (ld8(d) == 36) skip = 1;                          // drop the $
    uptr o = xalloc(n + 4);
    i64 i = 0;
    loop {
        i64 c = ld8(pfx + i);
        if (!c) break;
        st8(o + i, c);
        i = i + 1;
    }
    i64 j = skip;
    loop {
        if (j >= n) break;
        st8(o + i, ld8(d + j));
        i = i + 1;
        j = j + 1;
    }
    st8(o + i, 0);
    return o;
}

// ---- D4: a variable's type is its first assignment's, and never changes ----
i64 ph_var_find(uptr d) {
    i64 i = 0;
    loop {
        if (i >= ph_nvar) break;
        if (str_eq(ld64(ph_vname + i * 8), d)) return i;
        i = i + 1;
    }
    return -1;
}

uptr ph_tyname(i64 ty) {
    if (ty == TY_I64)  return "int";
    if (ty == TY_UPTR) return "string";
    return "mixed";
}

// returns 1 when this is the variable's FIRST assignment (so the caller emits
// an N_VAR and not an N_ASSIGN). A second assignment of another type is the
// one design rule D4 asks this probe to prove.
i64 ph_var_bind(uptr d, i64 ty, i64 line, uptr fl) {
    i64 i = ph_var_find(d);
    if (i < 0) {
        if (ph_nvar >= PH_MAXVAR) err_at(fl, line, "too many php variables");
        st64(ph_vname  + ph_nvar * 8, d);
        st64(ph_vtype  + ph_nvar * 8, ty);
        st64(ph_vwhere + ph_nvar * 8, fl);
        ph_nvar = ph_nvar + 1;
        return 1;
    }
    if (ld64(ph_vtype + i * 8) != ty) {
        uptr m = p_cat(d, " was ", 0, 5);
        uptr was = ph_tyname(ld64(ph_vtype + i * 8));
        m = p_cat(m, was, 0, cstrlen(was));
        m = p_cat(m, ", assigned ", 0, 11);
        m = p_cat(m, ph_tyname(ty), 0, cstrlen(ph_tyname(ty)));
        err_at2(fl, line, "a php variable has one type", m);
    }
    return 0;
}

// ---- the type words --------------------------------------------------------
i64 ph_type() {
    if (ph_is("int"))    { p_next(); return TY_I64; }
    if (ph_is("bool"))   { p_next(); return TY_I64; }
    if (ph_is("string")) { p_next(); return TY_UPTR; }
    if (ph_is("void"))   { p_next(); return TY_VOID; }
    if (ph_is("float"))  err_at(p_file(), p_line(), "php float is not in this probe");
    err_at2(p_file(), p_line(), "php type expected", p_name());
    return 0;
}

// ---- the expression grammar (the module's own) -----------------------------
// PHP's precedence, the subset this probe measures. parse_expr is never called:
// $x is a T_HOLE and parse_primary refuses it (`hole $name has no rule binding
// it`), so the whole expression road has to be the module's.
i64 ph_expr(i64 minp);

i64 ph_interp(uptr raw, i64 line, uptr fl);

i64 ph_digit(i64 c, i64 base) {
    i64 d = -1;
    if (c >= 48) { if (c <= 57) d = c - 48; }
    if (c >= 97) { if (c <= 102) d = c - 87; }
    if (c >= 65) { if (c <= 70)  d = c - 55; }
    if (d < 0) return -1;
    if (d >= base) return -1;
    return d;
}

// The number formats the core lexer does not have. It stops a number where ITS
// grammar ends, so `0b101` is the token `0` with the cursor on `b101` and
// `1_000` is `1` with the cursor on `_000`. p_cp() is that cursor and
// p_take_lit(q) is how a handler says where its literal really ended -- the M24
// syntax_lit contract, measured here from a handler that owns the whole
// expression grammar and therefore never reaches parse_primary at all.
i64 ph_number() {
    i64 line = p_line();
    uptr fl = p_file();
    i64 v = p_val();
    uptr q = p_cp();
    uptr e = p_src_end();
    i64 base = 0;
    if (v == 0) { if (q < e) { if (ld8(q) == 98) base = 2; } }
    if (v == 0) { if (q < e) { if (ld8(q) == 111) base = 8; } }
    if (base) {
        q = q + 1;
        i64 acc = 0;
        i64 n = 0;
        loop {
            if (q >= e) break;
            i64 c = ld8(q);
            if (c == 95) { q = q + 1; continue; }
            i64 d = ph_digit(c, base);
            if (d < 0) break;
            acc = acc * base + d;
            n = n + 1;
            q = q + 1;
        }
        if (!n) err_at(fl, line, "a php integer literal with no digits");
        p_take_lit(q);
        p_next();
        return ph_int(acc);
    }
    // `1_000`, and the float shapes, which this probe refuses by name rather
    // than lexing them as `1 . 5` -- which is what php.mc did before the scan
    // and is the one SILENT wrong answer the lexer sweep found.
    loop {
        if (q >= e) break;
        i64 c = ld8(q);
        if (c == 95) {
            q = q + 1;
            loop {
                if (q >= e) break;
                i64 d = ph_digit(ld8(q), 10);
                if (d < 0) break;
                v = v * 10 + d;
                q = q + 1;
            }
            continue;
        }
        break;
    }
    if (q < e) {
        i64 c = ld8(q);
        i64 isf = 0;
        if (c == 101) isf = 1;                       // 1e3
        if (c == 69)  isf = 1;
        if (c == 46) { if (q + 1 < e) { if (ph_digit(ld8(q + 1), 10) >= 0) isf = 1; } }
        if (isf) err_at(fl, line, "php float is not in this probe (docs/plan.md D4)");
    }
    p_take_lit(q);
    p_next();
    return ph_int(v);
}

i64 ph_primary() {
    i64 line = p_line();
    uptr fl = p_file();
    if (p_id() == T_INT) return ph_number();
    if (p_id() == T_STR) {
        uptr s = p_name();
        p_next();
        return ph_interp(s, line, fl);
    }
    if (p_id() == T_HOLE) {                          // $x
        uptr d = p_name();
        p_next();
        if (ph_var_find(d) < 0) err_at2(fl, line, "undefined php variable", d);
        i64 n = node_new(N_IDENT, line, fl);
        set_nd_name(n, ph_mangle(d, "v_"));
        set_nd_type(n, ld64(ph_vtype + ph_var_find(d) * 8));
        return n;
    }
    if (p_id() == ph_tok("(", 1)) {
        p_next();
        i64 e = ph_expr(0);
        p_expect(ph_tok(")", 1), "expected ) in a php expression");
        return e;
    }
    if (p_id() == T_IDENT) {
        uptr name = p_name();
        if (str_eq(name, "eval"))
            err_at(fl, line, "eval is refused: a binary has no interpreter (docs/plan.md D1)");
        // a name def_add() registered (a class offset, below). The module owns
        // the expression grammar, so it owns this lookup too: parse_primary's
        // own def_find branch is never reached.
        i64 di = def_find(name, cstrlen(name));
        if (di >= 0) {
            p_next();
            return ph_int(de_val(de_at(di)));
        }
        if (str_eq(name, "true"))  { p_next(); return ph_int(1); }
        if (str_eq(name, "false")) { p_next(); return ph_int(0); }
        p_next();
        if (p_id() != ph_tok("(", 1)) err_at2(fl, line, "php constant is not in this probe", name);
        p_next();
        i64 head = 0;
        i64 tail = 0;
        loop {
            if (p_id() == ph_tok(")", 1)) break;
            i64 a = ph_expr(0);
            if (tail) set_nd_next(tail, a);
            if (!tail) head = a;
            tail = a;
            if (p_id() != ph_tok(",", 1)) break;
            p_next();
        }
        p_expect(ph_tok(")", 1), "expected ) in a php call");
        i64 c = node_new(N_CALL, line, fl);
        set_nd_name(c, ph_mangle(name, "f_"));
        set_nd_a(c, head);
        set_nd_type(c, TY_I64);
        return c;
    }
    err_at2(fl, line, "php expression expected", p_name());
    return 0;
}

// (op token, precedence) -- PHP's own table for what this probe reads.
i64 ph_prec(i64 t) {
    if (t == ph_tok("*", 1)) return 60;
    if (t == ph_tok("/", 1)) return 60;
    if (t == ph_tok("%", 1)) return 60;
    if (t == ph_tok("+", 1)) return 50;
    if (t == ph_tok("-", 1)) return 50;
    if (t == ph_tok(".", 1)) return 50;
    if (t == ph_tok("<", 1)) return 40;
    if (t == ph_tok(">", 1)) return 40;
    if (t == ph_tok("<=", 2)) return 40;
    if (t == ph_tok(">=", 2)) return 40;
    if (t == ph_tok("==", 2)) return 35;
    if (t == ph_tok("!=", 2)) return 35;
    if (t == ph_tok("===", 3)) return 35;
    if (t == ph_tok("!==", 3)) return 35;
    if (t == ph_tok("&&", 2)) return 25;
    if (t == ph_tok("||", 2)) return 20;
    return -1;
}

// `.` is php's string concatenation, not an arithmetic operator.
i64 ph_binop(i64 t) {
    if (t == ph_tok("===", 3)) return ph_tok("==", 2);
    if (t == ph_tok("!==", 3)) return ph_tok("!=", 2);
    return t;
}

i64 ph_expr(i64 minp) {
    i64 lhs = ph_primary();
    loop {
        i64 t = p_id();
        i64 pr = ph_prec(t);
        if (pr < 0) break;
        if (pr < minp) break;
        i64 line = p_line();
        uptr fl = p_file();
        p_next();
        i64 rhs = ph_expr(pr + 1);
        if (t == ph_tok(".", 1)) {                   // "a" . "b"
            i64 c = node_new(N_CALL, line, fl);
            set_nd_name(c, "php_concat");
            set_nd_a(c, lhs);
            set_nd_next(lhs, rhs);
            set_nd_type(c, TY_UPTR);
            lhs = c;
        }
        if (t != ph_tok(".", 1)) {
            i64 b = node_new(N_BINARY, line, fl);
            set_nd_op(b, ph_binop(t));
            set_nd_a(b, lhs);
            set_nd_b(b, rhs);
            lhs = b;
        }
    }
    return lhs;
}

// ---- "x=$x\n": the interpolation ------------------------------------------
// The core lexer hands over ONE T_STR whose escapes are already decoded, so the
// $ inside it is a plain byte and the module re-scans it. What it cannot see is
// the raw source (\$ is already \ + $ by then) -- recorded in RESULTS.md.
i64 ph_str_node(uptr s, i64 n, i64 line, uptr fl) {
    uptr c = xstrdup(s, n);
    i64 k = node_new(N_STR, line, fl);
    set_nd_name(k, c);
    set_nd_val(k, n);
    set_nd_type(k, TY_UPTR);
    return k;
}

i64 ph_cat2(i64 a, i64 b, i64 line, uptr fl) {
    if (!a) return b;
    i64 c = node_new(N_CALL, line, fl);
    set_nd_name(c, "php_concat");
    set_nd_a(c, a);
    set_nd_next(a, b);
    set_nd_type(c, TY_UPTR);
    return c;
}

i64 ph_interp(uptr raw, i64 line, uptr fl) {
    i64 n = cstrlen(raw);
    i64 i = 0;
    i64 seg = 0;
    i64 acc = 0;
    loop {
        if (i >= n) break;
        if (ld8(raw + i) != 36) { i = i + 1; continue; }   // $
        i64 j = i + 1;
        loop {
            if (j >= n) break;
            i64 c = ld8(raw + j);
            i64 ok = 0;
            if (c >= 97) { if (c <= 122) ok = 1; }
            if (c >= 65) { if (c <= 90)  ok = 1; }
            if (c >= 48) { if (c <= 57)  ok = 1; }
            if (c == 95) ok = 1;
            if (!ok) break;
            j = j + 1;
        }
        if (j == i + 1) { i = i + 1; continue; }            // a lone $
        if (i > seg) acc = ph_cat2(acc, ph_str_node(raw + seg, i - seg, line, fl), line, fl);
        uptr d = xstrdup(raw + i, j - i);
        if (ph_var_find(d) < 0) err_at2(fl, line, "undefined php variable in a string", d);
        i64 v = node_new(N_IDENT, line, fl);
        set_nd_name(v, ph_mangle(d, "v_"));
        i64 conv = v;
        if (ld64(ph_vtype + ph_var_find(d) * 8) == TY_I64) {
            conv = node_new(N_CALL, line, fl);
            set_nd_name(conv, "php_itoa");
            set_nd_a(conv, v);
            set_nd_type(conv, TY_UPTR);
        }
        acc = ph_cat2(acc, conv, line, fl);
        seg = j;
        i = j;
    }
    if (!acc) return ph_str_node(raw, n, line, fl);
    if (n > seg) acc = ph_cat2(acc, ph_str_node(raw + seg, n - seg, line, fl), line, fl);
    return acc;
}

// ---- statements ------------------------------------------------------------
i64 ph_stmt();

i64 ph_block() {
    i64 line = p_line();
    uptr fl = p_file();
    p_expect(ph_tok("{", 1), "expected { in php");
    i64 head = 0;
    i64 tail = 0;
    loop {
        if (p_id() == ph_tok("}", 1)) break;
        if (p_id() == T_EOF) err_at(fl, line, "unterminated php block");
        i64 s = ph_stmt();
        if (tail) set_nd_next(tail, s);
        if (!tail) head = s;
        tail = s;
    }
    p_next();
    i64 b = node_new(N_BLOCK, line, fl);
    set_nd_a(b, head);
    return b;
}

// `foreach ($a as $v) { }` over a LITERAL array: the array is lowered to an
// mc global of i64 and the loop is an index walk. Only the literal form.
i64 ph_foreach(i64 line, uptr fl) {
    p_next();                                              // foreach
    p_expect(ph_tok("(", 1), "expected ( after foreach");
    if (p_id() != ph_tok("[", 1))
        err_at(fl, line, "foreach takes a literal array in this probe");
    p_next();
    i64 nel = 0;
    i64 head = 0;
    i64 tail = 0;
    loop {
        if (p_id() == ph_tok("]", 1)) break;
        i64 e = ph_expr(0);
        if (tail) set_nd_next(tail, e);
        if (!tail) head = e;
        tail = e;
        nel = nel + 1;
        if (p_id() != ph_tok(",", 1)) break;
        p_next();
    }
    p_expect(ph_tok("]", 1), "expected ] in a php array");
    ph_eat("as", "expected as in foreach");
    if (p_id() != T_HOLE) err_at(fl, line, "foreach needs $var");
    uptr d = p_name();
    p_next();
    p_expect(ph_tok(")", 1), "expected ) after foreach");

    ph_nonce = ph_nonce + 1;
    uptr an = p_cat("php_arr_", "0123456789", ph_nonce % 10, 1);
    i64 g = node_new(N_GLOBAL, line, fl);
    set_nd_name(g, an);
    set_nd_type(g, TY_I64);
    set_nd_val(g, nel);
    set_nd_a(g, head);
    top_add(g);

    ph_var_bind(d, TY_I64, line, fl);
    uptr iname = p_cat(an, "_i", 0, 2);

    // i64 <i> = 0; loop { if (<i> >= nel) break; v_x = arr[<i>]; <body>; <i> = <i>+1; }
    i64 iv = node_new(N_VAR, line, fl);
    set_nd_name(iv, iname);
    set_nd_type(iv, TY_I64);
    set_nd_a(iv, ph_int(0));

    i64 iref = node_new(N_IDENT, line, fl);
    set_nd_name(iref, iname);
    i64 lim = node_new(N_BINARY, line, fl);
    set_nd_op(lim, ph_tok(">=", 2));
    set_nd_a(lim, iref);
    set_nd_b(lim, ph_int(nel));
    i64 brk = node_new(N_BREAK, line, fl);
    set_nd_val(brk, 1);
    i64 iff = node_new(N_IF, line, fl);
    set_nd_a(iff, lim);
    set_nd_b(iff, brk);

    i64 aref = node_new(N_IDENT, line, fl);
    set_nd_name(aref, an);
    i64 iref2 = node_new(N_IDENT, line, fl);
    set_nd_name(iref2, iname);
    i64 sc = node_new(N_BINARY, line, fl);           // i * 8
    set_nd_op(sc, ph_tok("*", 1));
    set_nd_a(sc, iref2);
    set_nd_b(sc, ph_int(8));
    i64 ad = node_new(N_BINARY, line, fl);           // arr + i * 8
    set_nd_op(ad, ph_tok("+", 1));
    set_nd_a(ad, aref);
    set_nd_b(ad, sc);
    i64 idx = node_new(N_CALL, line, fl);            // the core has no index
    set_nd_name(idx, "ld64");
    set_nd_a(idx, ad);
    set_nd_type(idx, TY_I64);
    i64 asg = node_new(N_ASSIGN, line, fl);
    set_nd_name(asg, ph_mangle(d, "v_"));
    set_nd_a(asg, idx);

    i64 body = ph_block();

    i64 iref3 = node_new(N_IDENT, line, fl);
    set_nd_name(iref3, iname);
    i64 inc = node_new(N_BINARY, line, fl);
    set_nd_op(inc, ph_tok("+", 1));
    set_nd_a(inc, iref3);
    set_nd_b(inc, ph_int(1));
    i64 bump = node_new(N_ASSIGN, line, fl);
    set_nd_name(bump, iname);
    set_nd_a(bump, inc);

    set_nd_next(iff, asg);
    set_nd_next(asg, body);
    set_nd_next(body, bump);
    i64 lb = node_new(N_BLOCK, line, fl);
    set_nd_a(lb, iff);
    i64 lp = node_new(N_LOOP, line, fl);
    set_nd_a(lp, lb);

    i64 vv = node_new(N_VAR, line, fl);              // the loop variable's slot
    set_nd_name(vv, ph_mangle(d, "v_"));
    set_nd_type(vv, TY_I64);
    set_nd_a(vv, ph_int(0));

    set_nd_next(iv, vv);
    set_nd_next(vv, lp);
    i64 outer = node_new(N_BLOCK, line, fl);
    set_nd_a(outer, iv);
    return outer;
}

// `require 'f.php';` and its three siblings (D5): a LITERAL path, resolved
// against the including file, spliced with p_push_source. `_once` is by path.
#define PH_MAXINC 64
uptr ph_seen[PH_MAXINC];
i64  ph_nseen;

// D5: all four spellings are compile-time splices of a LITERAL path resolved
// against the including file; the one distinction kept is _once, by normalised
// path. One road for all four, and the once-list is the MODULE's: mc's own
// lex_include keeps a list of its own that a p_push_source never enters, so a
// module cannot mix the two roads and still have `require` then `require_once`
// of the same file behave as php does (measured -- RESULTS.md).
void ph_require(i64 once, i64 line, uptr fl) {
    p_next();                                              // require / include
    if (p_id() != T_STR) err_at(fl, line, "require takes a literal path (docs/plan.md D1)");
    uptr rel = p_name();
    p_next();                                              // now ON the `;`
    if (p_id() != ph_tok(";", 1)) err_at(fl, line, "expected ; after require");
    uptr full = path_norm(path_join(fl, rel));
    i64 i = 0;
    i64 seen = 0;
    loop {
        if (i >= ph_nseen) break;
        if (str_eq(ld64(ph_seen + i * 8), full)) seen = 1;
        i = i + 1;
    }
    if (once) { if (seen) { p_next(); return; } }
    if (!seen) {
        if (ph_nseen >= PH_MAXINC) err_at(fl, line, "too many php requires");
        st64(ph_seen + ph_nseen * 8, full);
        ph_nseen = ph_nseen + 1;
    }
    i64 len = 0;
    uptr txt = read_file(full, &len);
    if (!txt) err_at2(fl, line, "cannot open the required file", full);
    p_push_source(full, txt, len);                         // on_source -> ph_rewrite
    p_next();                                              // discard the `;`
}

i64 ph_stmt() {
    i64 line = p_line();
    uptr fl = p_file();
    if (p_id() == ph_tok("<?php", 5)) { p_next(); return node_new(N_BLOCK, line, fl); }
    if (p_id() == ph_tok("?>", 2))    { p_next(); return node_new(N_BLOCK, line, fl); }
    if (p_id() == ph_tok("{", 1)) return ph_block();
    if (ph_is("echo")) {
        p_next();
        i64 e = ph_expr(0);
        p_expect(ph_tok(";", 1), "expected ; after echo");
        i64 c = node_new(N_CALL, line, fl);
        set_nd_name(c, "php_echo_int");
        if (nd_type(e) == TY_UPTR) set_nd_name(c, "php_echo_str");
        set_nd_a(c, e);
        set_nd_type(c, TY_I64);
        i64 s = node_new(N_EXPRSTMT, line, fl);
        set_nd_a(s, c);
        return s;
    }
    if (ph_is("return")) {
        p_next();
        i64 e = 0;
        if (p_id() != ph_tok(";", 1)) e = ph_expr(0);
        p_expect(ph_tok(";", 1), "expected ; after return");
        i64 r = node_new(N_RETURN, line, fl);
        set_nd_a(r, e);
        return r;
    }
    if (ph_is("if")) {
        p_next();
        p_expect(ph_tok("(", 1), "expected ( after if");
        i64 c = ph_expr(0);
        p_expect(ph_tok(")", 1), "expected ) after if");
        i64 t = ph_stmt();
        i64 e = 0;
        if (ph_is("else")) { p_next(); e = ph_stmt(); }
        i64 n = node_new(N_IF, line, fl);
        set_nd_a(n, c);
        set_nd_b(n, t);
        set_nd_c(n, e);
        return n;
    }
    if (ph_is("while")) {
        p_next();
        p_expect(ph_tok("(", 1), "expected ( after while");
        i64 c = ph_expr(0);
        p_expect(ph_tok(")", 1), "expected ) after while");
        i64 body = ph_stmt();
        i64 neg = node_new(N_UNARY, line, fl);
        set_nd_op(neg, ph_tok("!", 1));
        set_nd_a(neg, c);
        i64 brk = node_new(N_BREAK, line, fl);
        set_nd_val(brk, 1);
        i64 iff = node_new(N_IF, line, fl);
        set_nd_a(iff, neg);
        set_nd_b(iff, brk);
        set_nd_next(iff, body);
        i64 b = node_new(N_BLOCK, line, fl);
        set_nd_a(b, iff);
        i64 lp = node_new(N_LOOP, line, fl);
        set_nd_a(lp, b);
        return lp;
    }
    if (ph_is("for")) {
        p_next();
        p_expect(ph_tok("(", 1), "expected ( after for");
        i64 init = ph_stmt();                              // `$i = 0;`
        i64 c = ph_expr(0);
        p_expect(ph_tok(";", 1), "expected ; in for");
        // the step, as a statement without its own `;`
        i64 step = 0;
        if (p_id() == T_HOLE) {
            uptr d = p_name();
            p_next();
            i64 t = p_id();
            p_next();
            i64 rhs = ph_expr(0);
            i64 b = node_new(N_BINARY, line, fl);
            if (t == ph_tok("+=", 2)) set_nd_op(b, ph_tok("+", 1));
            if (t == ph_tok("-=", 2)) set_nd_op(b, ph_tok("-", 1));
            if (t != ph_tok("+=", 2)) { if (t != ph_tok("-=", 2)) err_at(fl, line, "for step: only $i += e / $i -= e"); }
            i64 lv = node_new(N_IDENT, line, fl);
            set_nd_name(lv, ph_mangle(d, "v_"));
            set_nd_a(b, lv);
            set_nd_b(b, rhs);
            step = node_new(N_ASSIGN, line, fl);
            set_nd_name(step, ph_mangle(d, "v_"));
            set_nd_a(step, b);
        }
        if (!step) err_at(fl, line, "for step: only $i += e / $i -= e");
        p_expect(ph_tok(")", 1), "expected ) after for");
        i64 body = ph_stmt();
        i64 neg = node_new(N_UNARY, line, fl);
        set_nd_op(neg, ph_tok("!", 1));
        set_nd_a(neg, c);
        i64 brk = node_new(N_BREAK, line, fl);
        set_nd_val(brk, 1);
        i64 iff = node_new(N_IF, line, fl);
        set_nd_a(iff, neg);
        set_nd_b(iff, brk);
        set_nd_next(iff, body);
        set_nd_next(body, step);
        i64 b2 = node_new(N_BLOCK, line, fl);
        set_nd_a(b2, iff);
        i64 lp = node_new(N_LOOP, line, fl);
        set_nd_a(lp, b2);
        set_nd_next(init, lp);
        i64 outer = node_new(N_BLOCK, line, fl);
        set_nd_a(outer, init);
        return outer;
    }
    if (ph_is("foreach")) return ph_foreach(line, fl);
    if (ph_is("require_once")) { ph_require(1, line, fl); return node_new(N_BLOCK, line, fl); }
    if (ph_is("include_once")) { ph_require(1, line, fl); return node_new(N_BLOCK, line, fl); }
    if (ph_is("require"))      { ph_require(0, line, fl); return node_new(N_BLOCK, line, fl); }
    if (ph_is("include"))      { ph_require(0, line, fl); return node_new(N_BLOCK, line, fl); }
    if (p_id() == T_HOLE) {                                // $x = expr;
        uptr d = p_name();
        p_next();
        if (p_id() != ph_tok("=", 1)) err_at2(fl, line, "a php variable statement must assign", d);
        p_next();
        i64 v = ph_expr(0);
        p_expect(ph_tok(";", 1), "expected ; after assignment");
        i64 ty = TY_I64;
        if (nd_type(v) == TY_UPTR) ty = TY_UPTR;
        if (nd_kind(v) == N_STR)   ty = TY_UPTR;
        i64 first = ph_var_bind(d, ty, line, fl);
        if (first) {
            i64 n = node_new(N_VAR, line, fl);
            set_nd_name(n, ph_mangle(d, "v_"));
            set_nd_type(n, ty);
            set_nd_a(n, v);
            return n;
        }
        i64 a = node_new(N_ASSIGN, line, fl);
        set_nd_name(a, ph_mangle(d, "v_"));
        set_nd_a(a, v);
        return a;
    }
    i64 e = ph_expr(0);
    p_expect(ph_tok(";", 1), "expected ; after a php expression");
    i64 s = node_new(N_EXPRSTMT, line, fl);
    set_nd_a(s, e);
    return s;
}

// ---- declarations ----------------------------------------------------------
i64 ph_function() {
    i64 line = p_line();
    uptr fl = p_file();
    p_next();                                              // function
    uptr name = p_ident();
    p_expect(ph_tok("(", 1), "expected ( in a php function");
    i64 head = 0;
    i64 tail = 0;
    i64 save = ph_nvar;
    loop {
        if (p_id() == ph_tok(")", 1)) break;
        i64 ty = TY_I64;
        if (p_id() != T_HOLE) ty = ph_type();
        if (p_id() != T_HOLE) err_at(fl, line, "a php parameter needs $name");
        uptr d = p_name();
        p_next();
        ph_var_bind(d, ty, line, fl);
        i64 pn = param_new(ty, ph_mangle(d, "v_"));
        if (tail) set_nd_next(tail, pn);
        if (!tail) head = pn;
        tail = pn;
        if (p_id() != ph_tok(",", 1)) break;
        p_next();
    }
    p_expect(ph_tok(")", 1), "expected ) in a php function");
    i64 rty = TY_I64;
    if (p_id() == ph_tok(":", 1)) { p_next(); rty = ph_type(); }
    uptr mn = ph_mangle(name, "f_");
    p_set_decl_name(mn);
    i64 body = ph_block();
    ph_nvar = save;                                        // per-function scope
    i64 f = node_new(N_FUNC, line, fl);
    set_nd_name(f, mn);
    set_nd_type(f, rty);
    set_nd_a(f, head);
    set_nd_b(f, body);
    return f;
}

// `class C { public int $p; function m(...) {...} }` -- the M12 shape:
// the property becomes an offset #define and the method an ordinary function
// taking `self` first. No vtable: this probe measures the GRAMMAR.
void ph_class() {
    i64 line = p_line();
    uptr fl = p_file();
    p_next();                                              // class
    uptr cname = p_ident();
    p_expect(ph_tok("{", 1), "expected { in a php class");
    i64 off = 0;
    loop {
        if (p_id() == ph_tok("}", 1)) break;
        if (p_id() == T_EOF) err_at(fl, line, "unterminated php class");
        if (ph_is("public"))    { p_next(); continue; }
        if (ph_is("private"))   { p_next(); continue; }
        if (ph_is("protected")) { p_next(); continue; }
        if (ph_is("static"))    { p_next(); continue; }
        if (ph_is("function")) {
            i64 m = ph_function();
            uptr mm = p_cat(cname, "_", 0, 1);
            mm = p_cat(mm, nd_name(m) + 2, 0, cstrlen(nd_name(m) + 2));
            set_nd_name(m, mm);
            i64 self = param_new(TY_UPTR, "v_this");
            set_nd_next(self, nd_a(m));
            set_nd_a(m, self);
            top_add(m);
            continue;
        }
        ph_type();                                         // the property's type
        if (p_id() != T_HOLE) err_at(fl, line, "a php property needs $name");
        uptr d = p_name();
        p_next();
        p_expect(ph_tok(";", 1), "expected ; after a php property");
        uptr pn = p_cat(cname, "_", 0, 1);
        pn = p_cat(pn, d + 1, 0, cstrlen(d + 1));
        def_add(pn, off, line, fl);
        off = off + 8;
    }
    p_next();                                              // }
    def_add(p_cat(cname, "_SIZE", 0, 5), off, line, fl);
}

// ---- the one registration --------------------------------------------------
void ph_program() {
    i64 line = p_line();
    uptr fl = p_file();
    p_next();                                              // <?php
    loop {
        if (p_id() == T_EOF) break;
        if (p_id() == ph_tok("?>", 2)) { p_next(); continue; }
        if (ph_is("function")) { top_add(ph_function()); continue; }
        if (ph_is("class"))    { ph_class(); continue; }
        if (ph_is("declare"))  { err_at(fl, p_line(), "declare() is not in this probe"); }
        i64 s = ph_stmt();
        if (ph_main_tail) set_nd_next(ph_main_tail, s);
        if (!ph_main_tail) ph_main_head = s;
        ph_main_tail = s;
    }
    i64 r = node_new(N_RETURN, line, fl);
    set_nd_a(r, ph_int(0));
    if (ph_main_tail) set_nd_next(ph_main_tail, r);
    if (!ph_main_tail) ph_main_head = r;
    i64 b = node_new(N_BLOCK, line, fl);
    set_nd_a(b, ph_main_head);
    i64 f = node_new(N_FUNC, line, fl);
    set_nd_name(f, "main");
    set_nd_type(f, TY_I64);
    set_nd_b(f, b);
    top_add(f);
}

#embed ph_rt "php_rt.txt"

void user_init() {
    ph_tokens();
    on_source(&ph_rewrite);
    source_claim(&ph_claim);
    syntax("<?php", &ph_program);
    p_push_source("php runtime", ph_rt, ph_rt_size);
}

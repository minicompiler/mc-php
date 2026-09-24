// packed.mc -- a php array the compiler PROVES is a packed int array, lowered
// to a native i64 buffer (php_pk_* in lib/php_rt.mc) instead of php's ordered
// hash of zvals.
//
// WHAT IS PROVED, per plain `function` (not a method, not a closure), by a
// token scan of its body before the body is compiled. A local $x is PACKED
// when every one of these holds:
//
//   * it is not a parameter, and no source anywhere names it `&$x`, `global
//     $x` or passes it to a by-reference parameter (the whole-source scans in
//     program.mc, the same sets that already make such a name a zval);
//   * the body contains none of `function`, `fn`, `class`, `interface`,
//     `trait`, `yield`, `goto`, `switch`, `eval`, `include`/`require`,
//     `compact`, `extract`, `get_defined_vars`, `$$`, `${`, a heredoc, a
//     backtick, `?>` or php's alternative syntax (`endif`, `endwhile`, ...)
//     -- anything that can reach a local by name, share it with another
//     scope, jump over its initialisation or open a block with no braces;
//   * its FIRST occurrence is a statement `$x = [];`, `$x = array();` or
//     `$x = array_fill(0, N, V);` with N and V ints, and every other
//     occurrence comes after it in the same block (so the initialisation has
//     run: it is straight-line code in front of every use);
//   * every other occurrence is one of
//         $x = [] / array() / array_fill(0, N, V);    a new array
//         $x[] = E;                                     E an int
//         $x[K] = E;                                    K and E ints
//         $x[K]                                         a read, K an int
//         count($x)
//     and nothing else: $x itself as a value -- passed to any function
//     but count, returned, stored, compared, copied, captured, iterated,
//     interpolated in a string -- is not on the list, and neither is
//     isset/empty/unset/list/destructuring, a compound assignment or `&`.
//
// "an int" is a STATIC answer: the scan predicts the type the lowering will
// give the expression (int literals, int-only variables, `+ - * %` of ints,
// `(int)`, intdiv/strlen/ord/count/abs, min/max of two ints, and a packed
// element read inside arithmetic), and the lowering checks each prediction
// where it builds the call -- a disagreement is a compile error naming this
// file, never a wrong answer. Whatever the scan cannot show is an int keeps
// the array a php array: the proof fails in the safe direction.
//
// Keys are NOT proved in range, and do not need to be. A read of a key the
// array does not have is php's warning and null (php_pk_get raises it and
// sets ph_pkabs); a store past the end or below zero makes the array php's
// ordered hash inside the same handle (php_pk_hash). So every key php allows
// behaves as php says.
//
// A variable whose only assignment is `$v = $x[K];` (the FIRST occurrence, a
// statement, every read after it in its block, never written again) is kept
// native too: an i64 plus the null flag (PT_INULL, two locals). That is
// `$xi = $x[$i]` in examples/decimal's _dec_umul, the operand of its inner
// loop's multiply.
//
// An element read or such a variable is PT_INULL: ph_arith treats it as an
// int beside another number -- php's null IS 0 there, `null + 1` and
// `null * 5` are ints -- and everywhere else (a call's argument, a
// comparison, echo, `.`) it becomes the zval php has (php_zinull), which is
// exactly what the read was before this file existed.
//
// One deviation, named: php promotes an int that overflows to a float, and
// the zval road this replaces did. So + - * on an element, and on what such
// an operation answered in the same expression, are php_add_ck/sub_ck/mul_ck:
// php's overflow test, and where php would make a float an ArithmeticError
// that says so -- a refusal at run time, never a wrapped int. (An int
// VARIABLE assigned from one is the native int road's own, which wraps; that
// is D10's gap, docs/plan.md § 7.)

#define PK_MAXT 16384
#define PK_MAXV 512

#define PKK_VAR 1
#define PKK_ID  2
#define PKK_NUM 3
#define PKK_STR 4
#define PKK_P   5

#define PKF_ISSET 1        // inside isset( / empty(
#define PKF_KILL  2        // inside unset( / list( / a destructuring [ ]

#define PKS_CAND  1
#define PKS_INULL 2
#define PKS_INT   4

// ---- the current function's answer -------------------------------------------
uptr pkx_names;             // the packed arrays, "$x", 0-terminated list
uptr pkx_inames;            // the PT_INULL variables

i64 pkx_in(uptr lst, uptr d) {
    if (!lst) return 0;
    i64 i = 0;
    loop {
        uptr n = ld64(lst + i * 8);
        if (!n) return 0;
        if (str_eq(n, d)) return 1;
        i = i + 1;
    }
    return 0;
}

i64 ph_pk_has(uptr d) { return pkx_in(pkx_names, d); }
i64 ph_pin_has(uptr d) { return pkx_in(pkx_inames, d); }

// a PT_INULL node, as the zval php has for it
i64 ph_inull_zv(i64 n) {
    if (nd_kind(n) == N_IDENT) {
        uptr vn = nd_name(n);
        i64 f = node_new(N_IDENT, nd_line(n), nd_file(n));
        set_nd_name(f, p_cat("vn_", vn + 2, 0, cstrlen(vn + 2)));
        set_nd_type(f, TY_I64);
        return ph_quiet("php_zinull2", 2, n, f, 0, 0, ty_pzv);
    }
    return ph_quiet("php_zinull", 1, n, 0, 0, 0, ty_pzv);
}

// ---- the token scan ------------------------------------------------------------
i64  pkx_n;
uptr pkx_k;                 // kind
uptr pkx_t;                 // VAR/ID: the name; P: the punctuation code; NUM: 1 = a plain int
uptr pkx_v;                 // NUM: its value
uptr pkx_m;                 // the matching bracket, for ( [ {
uptr pkx_b;                 // the innermost enclosing { token, -1 for the body
uptr pkx_f;                 // PKF_*
uptr pkx_vi;                // VAR: the index of its name in pkx_vn
i64  pkx_bad;
uptr pkx_vn;                // the distinct variable names
uptr pkx_vs;                // PKS_* per name
uptr pkx_vx;                // 1: a name this scan must not optimise (a string interpolates it)
i64  pkx_nv;
i64  pkx_at;

i64 pkx_pc(uptr s) {
    i64 c = ld8(s);
    if (c && ld8(s + 1)) { c = c | (ld8(s + 1) << 8); if (ld8(s + 2)) c = c | (ld8(s + 2) << 16); }
    return c;
}

i64 pkx_kind(i64 i) { if (i < 0 || i >= pkx_n) return 0; return ld64(pkx_k + i * 8); }
i64 pkx_isp(i64 i, uptr s) { return pkx_kind(i) == PKK_P && ld64(pkx_t + i * 8) == pkx_pc(s); }
i64 pkx_isid(i64 i, uptr s) { return pkx_kind(i) == PKK_ID && str_eq(ld64(pkx_t + i * 8), s); }
i64 pkx_mat(i64 i) { return ld64(pkx_m + i * 8); }

i64 pkx_var_index(uptr name) {
    i64 i = 0;
    loop {
        if (i >= pkx_nv) break;
        if (str_eq(ld64(pkx_vn + i * 8), name)) return i;
        i = i + 1;
    }
    if (pkx_nv >= PK_MAXV) { pkx_bad = 1; return 0; }
    st64(pkx_vn + pkx_nv * 8, name);
    st64(pkx_vs + pkx_nv * 8, 0);
    st64(pkx_vx + pkx_nv * 8, 0);
    pkx_nv = pkx_nv + 1;
    return pkx_nv - 1;
}

void pkx_add(i64 k, i64 t, i64 v) {
    if (pkx_n >= PK_MAXT) { pkx_bad = 1; return; }
    st64(pkx_k + pkx_n * 8, k);
    st64(pkx_t + pkx_n * 8, t);
    st64(pkx_v + pkx_n * 8, v);
    st64(pkx_m + pkx_n * 8, 0 - 1);
    st64(pkx_f + pkx_n * 8, 0);
    st64(pkx_vi + pkx_n * 8, 0 - 1);
    if (k == PKK_VAR) st64(pkx_vi + pkx_n * 8, pkx_var_index(t));
    pkx_n = pkx_n + 1;
}

uptr pkx_word(uptr src, i64 st, i64 e, i64 dollar) {
    uptr o = xalloc(e - st + 2);
    i64 j = 0;
    if (dollar) { st8(o, 36); j = 1; }
    i64 k = st;
    loop { if (k >= e) break; st8(o + j, ld8(src + k)); j = j + 1; k = k + 1; }
    st8(o + j, 0);
    return o;
}

// the three-, two- and one-byte operators, longest first
i64 pkx_punct(uptr src, i64 len, i64 i) {
    uptr p3 = "<=>===!==**=...<<=>>=??=?->";
    i64 j = 0;
    if (i + 2 < len) {
        loop {
            if (j >= 27) break;
            if (ld8(src + i) == ld8(p3 + j) && ld8(src + i + 1) == ld8(p3 + j + 1) && ld8(src + i + 2) == ld8(p3 + j + 2)) return 3;
            j = j + 3;
        }
    }
    uptr p2 = "==!=<=>==>->::++--+=-=*=/=.=%=**??&&||<<>>&=|=^=<>";
    j = 0;
    if (i + 1 < len) {
        loop {
            if (j >= 50) break;
            if (ld8(src + i) == ld8(p2 + j) && ld8(src + i + 1) == ld8(p2 + j + 1)) return 2;
            j = j + 2;
        }
    }
    return 1;
}

// the words that end the proof for the whole body
i64 pkx_badword(uptr w) {
    return str_eq(w, "function") || str_eq(w, "fn") || str_eq(w, "class") || str_eq(w, "interface")
        || str_eq(w, "trait") || str_eq(w, "yield") || str_eq(w, "goto") || str_eq(w, "switch")
        || str_eq(w, "eval") || str_eq(w, "include") || str_eq(w, "include_once")
        || str_eq(w, "require") || str_eq(w, "require_once") || str_eq(w, "compact")
        || str_eq(w, "extract") || str_eq(w, "get_defined_vars")
        // php's alternative syntax: a block with no braces, which the
        // dominance test below cannot see (`if ($c): ...; $x = []; endif;`)
        || str_eq(w, "endif") || str_eq(w, "endwhile") || str_eq(w, "endfor")
        || str_eq(w, "endforeach") || str_eq(w, "endswitch") || str_eq(w, "enddeclare");
}

// Tokenise the body after the `{` at src[0..len). Answers the offset of the
// matching `}`, or -1 and pkx_bad.
i64 pkx_lex(uptr src, i64 len) {
    i64 i = 0;
    i64 depth = 0;
    loop {
        if (pkx_bad) return 0 - 1;
        if (i >= len) { pkx_bad = 1; return 0 - 1; }
        i64 c = ld8(src + i);
        if (ph_space(c)) { i = i + 1; continue; }
        if (c == 96) { pkx_bad = 1; return 0 - 1; }                          // `...`
        if (c == 63 && i + 1 < len && ld8(src + i + 1) == 62) { pkx_bad = 1; return 0 - 1; }   // ?>
        if (c == 35 && i + 1 < len && ld8(src + i + 1) == 91) { pkx_bad = 1; return 0 - 1; }  // #[
        if (c == 60 && i + 2 < len && ld8(src + i + 1) == 60 && ld8(src + i + 2) == 60) { pkx_bad = 1; return 0 - 1; }
        if (c == 34) {
            // a double-quoted string interpolates: every $name in it is a use
            // the scan cannot classify
            i64 e = ph_scan_hop(src, len, i);
            i64 q = i + 1;
            loop {
                if (q >= e) break;
                i64 d = ld8(src + q);
                if (d == 92) { q = q + 2; continue; }
                if (d == 36 && q + 1 < e) {
                    i64 s2 = q + 1;
                    if (ld8(src + s2) == 123) { pkx_bad = 1; return 0 - 1; }     // ${
                    i64 q2 = s2;
                    loop { if (q2 >= e) break; if (!ph_nmb(ld8(src + q2), q2 == s2)) break; q2 = q2 + 1; }
                    if (q2 > s2) st64(pkx_vx + pkx_var_index(pkx_word(src, s2, q2, 1)) * 8, 1);
                    q = q2;
                    continue;
                }
                q = q + 1;
            }
            pkx_add(PKK_STR, 0, 0);
            i = e;
            continue;
        }
        i64 h = ph_scan_hop(src, len, i);
        if (h != i) {
            if (c == 39) pkx_add(PKK_STR, 0, 0);
            i = h;
            continue;
        }
        if (c == 36) {
            i64 s = i + 1;
            if (s < len && (ld8(src + s) == 36 || ld8(src + s) == 123)) { pkx_bad = 1; return 0 - 1; }
            i64 e2 = s;
            loop { if (e2 >= len) break; if (!ph_nmb(ld8(src + e2), e2 == s)) break; e2 = e2 + 1; }
            if (e2 == s) { pkx_bad = 1; return 0 - 1; }
            pkx_add(PKK_VAR, pkx_word(src, s, e2, 1), 0);
            i = e2;
            continue;
        }
        if (ph_nmb(c, 1)) {
            i64 e3 = i;
            loop { if (e3 >= len) break; if (!ph_nmb(ld8(src + e3), e3 == i)) break; e3 = e3 + 1; }
            uptr w = pkx_word(src, i, e3, 0);
            if (pkx_badword(w)) { pkx_bad = 1; return 0 - 1; }
            pkx_add(PKK_ID, w, 0);
            i = e3;
            continue;
        }
        if (c >= 48 && c <= 57) {
            // a plain decimal int of at most 18 digits is an int to php and to
            // the lowering alike; anything else (hex, a float, a longer run)
            // is left unclassified
            i64 e4 = i;
            i64 nd = 0;
            i64 val = 0;
            i64 plain = 1;
            if (c == 48 && i + 1 < len && ph_nmb(ld8(src + i + 1), 1)) plain = 0;
            loop {
                if (e4 >= len) break;
                i64 d4 = ld8(src + e4);
                if (d4 >= 48 && d4 <= 57) { nd = nd + 1; val = val * 10 + (d4 - 48); e4 = e4 + 1; continue; }
                if (d4 == 95) { e4 = e4 + 1; continue; }
                if (ph_nmb(d4, 0)) { plain = 0; e4 = e4 + 1; continue; }
                if (d4 == 46 && e4 + 1 < len && ld8(src + e4 + 1) >= 48 && ld8(src + e4 + 1) <= 57) { plain = 0; e4 = e4 + 1; continue; }
                break;
            }
            if (nd > 18) plain = 0;
            pkx_add(PKK_NUM, plain, val);
            i = e4;
            continue;
        }
        if (c == 46 && i + 1 < len && ld8(src + i + 1) >= 48 && ld8(src + i + 1) <= 57) {
            i64 e5 = i + 1;
            loop { if (e5 >= len) break; i64 d5 = ld8(src + e5); if (!ph_nmb(d5, 0)) break; e5 = e5 + 1; }
            pkx_add(PKK_NUM, 0, 0);
            i = e5;
            continue;
        }
        if (c == 123) depth = depth + 1;
        if (c == 125) {
            if (depth == 0) return i;
            depth = depth - 1;
        }
        i64 w2 = pkx_punct(src, len, i);
        i64 code = c;
        if (w2 >= 2) code = code | (ld8(src + i + 1) << 8);
        if (w2 >= 3) code = code | (ld8(src + i + 2) << 16);
        pkx_add(PKK_P, code, 0);
        i = i + w2;
    }
    return 0 - 1;
}

// brackets matched, the innermost block and the isset/unset/destructuring
// regions of every token
void pkx_nest() {
    uptr st = xalloc(pkx_n * 8 + 8);
    uptr sf = xalloc(pkx_n * 8 + 8);
    i64 sp = 0;
    i64 blk = 0 - 1;
    uptr bs = xalloc(pkx_n * 8 + 8);
    i64 bp = 0;
    i64 fl = 0;
    i64 i = 0;
    loop {
        if (i >= pkx_n) break;
        st64(pkx_b + i * 8, blk);
        st64(pkx_f + i * 8, fl);
        if (pkx_isp(i, "(") || pkx_isp(i, "[") || pkx_isp(i, "{")) {
            st64(st + sp * 8, i);
            st64(sf + sp * 8, fl);
            sp = sp + 1;
            if (pkx_isp(i, "(")) {
                if (pkx_isid(i - 1, "isset") || pkx_isid(i - 1, "empty")) fl = fl | PKF_ISSET;
                if (pkx_isid(i - 1, "unset") || pkx_isid(i - 1, "list")) fl = fl | PKF_KILL;
            }
            if (pkx_isp(i, "{")) { st64(bs + bp * 8, blk); bp = bp + 1; blk = i; }
            i = i + 1;
            continue;
        }
        if (pkx_isp(i, ")") || pkx_isp(i, "]") || pkx_isp(i, "}")) {
            if (sp == 0) { pkx_bad = 1; return; }
            sp = sp - 1;
            i64 o = ld64(st + sp * 8);
            fl = ld64(sf + sp * 8);
            i64 okm = 0;
            if (pkx_isp(i, ")") && pkx_isp(o, "(")) okm = 1;
            if (pkx_isp(i, "]") && pkx_isp(o, "[")) okm = 1;
            if (pkx_isp(i, "}") && pkx_isp(o, "{")) okm = 1;
            if (!okm) { pkx_bad = 1; return; }
            st64(pkx_m + o * 8, i);
            st64(pkx_m + i * 8, o);
            if (pkx_isp(i, "}")) { bp = bp - 1; blk = ld64(bs + bp * 8); }
        }
        i = i + 1;
    }
    if (sp) { pkx_bad = 1; return; }
    // a [ that is not a subscript and is written to (`[$a, $b] = ...`,
    // `foreach (... as [...])`) is a destructuring pattern: every token
    // inside it is an assignment target
    i = 0;
    loop {
        if (i >= pkx_n) break;
        if (pkx_isp(i, "[")) {
            i64 pk = pkx_kind(i - 1);
            i64 sub = 0;
            if (pk == PKK_VAR || pk == PKK_ID || pk == PKK_STR) sub = 1;
            if (pkx_isp(i - 1, "]") || pkx_isp(i - 1, ")") || pkx_isp(i - 1, "}")) sub = 1;
            if (pkx_isid(i - 1, "as")) sub = 0;
            i64 m = pkx_mat(i);
            if (!sub && (pkx_isp(m + 1, "=") || pkx_isid(i - 1, "as"))) {
                i64 j = i;
                loop { if (j > m) break; st64(pkx_f + j * 8, ld64(pkx_f + j * 8) | PKF_KILL); j = j + 1; }
            }
        }
        i = i + 1;
    }
}

// ---- the static answer: 1 an int, 2 a packed element (int or null), 0 other --
i64 pkx_st(i64 i) { return ld64(pkx_vs + ld64(pkx_vi + i * 8) * 8); }

i64 pkx_postfix(i64 j) {
    return pkx_isp(j, "[") || pkx_isp(j, "(") || pkx_isp(j, "->") || pkx_isp(j, "?->")
        || pkx_isp(j, "::") || pkx_isp(j, "++") || pkx_isp(j, "--");
}

// skip a postfix chain from j; answers the index after it
i64 pkx_skip(i64 j) {
    loop {
        if (pkx_isp(j, "[") || pkx_isp(j, "(")) { j = pkx_mat(j) + 1; continue; }
        if (pkx_isp(j, "->") || pkx_isp(j, "?->") || pkx_isp(j, "::")) { j = j + 2; continue; }
        if (pkx_isp(j, "++") || pkx_isp(j, "--")) { j = j + 1; continue; }
        break;
    }
    return j;
}

i64 pkx_expr(i64 i);
i64 pkx_un(i64 i);

// the arguments of the call whose ( is at o: up to four starts, answers the count
i64 pkx_args(i64 o, uptr starts) {
    i64 m = pkx_mat(o);
    if (m == o + 1) return 0;
    i64 na = 1;
    st64(starts, o + 1);
    i64 j = o + 1;
    loop {
        if (j >= m) break;
        if (pkx_isp(j, "(") || pkx_isp(j, "[") || pkx_isp(j, "{")) { j = pkx_mat(j) + 1; continue; }
        if (pkx_isp(j, ",")) { if (na >= 4) return 9; st64(starts + na * 8, j + 1); na = na + 1; }
        j = j + 1;
    }
    return na;
}

// one argument, from s to the next top-level `,` or the call's `)`
i64 pkx_arg(i64 s) {
    i64 r = pkx_expr(s);
    if (r < 0) return 0;
    if (!pkx_isp(pkx_at, ",") && !pkx_isp(pkx_at, ")")) return 0;
    return r;
}

i64 pkx_prim(i64 i) {
    i64 k = pkx_kind(i);
    if (k == PKK_NUM) { pkx_at = i + 1; if (pkx_postfix(i + 1)) { pkx_at = pkx_skip(i + 1); return 0; } return ld64(pkx_t + i * 8); }
    if (k == PKK_STR) { pkx_at = pkx_skip(i + 1); return 0; }
    if (k == PKK_VAR) {
        i64 s = pkx_st(i);
        if (pkx_isp(i + 1, "[") && (s & PKS_CAND)) {
            i64 m = pkx_mat(i + 1);
            if (!pkx_postfix(m + 1)) { pkx_at = m + 1; return 2; }
        }
        if (pkx_postfix(i + 1)) { pkx_at = pkx_skip(i + 1); return 0; }
        pkx_at = i + 1;
        if (s & PKS_INT) return 1;
        if (s & PKS_INULL) return 2;
        return 0;
    }
    if (k == PKK_ID) {
        if (pkx_isp(i + 1, "(")) {
            i64 o = i + 1;
            i64 m = pkx_mat(o);
            pkx_at = m + 1;
            if (pkx_postfix(m + 1)) { pkx_at = pkx_skip(m + 1); return 0; }
            u8 as[32];
            i64 na = pkx_args(o, as);
            uptr w = ld64(pkx_t + i * 8);
            if (str_eq(w, "intdiv") || str_eq(w, "strlen") || str_eq(w, "ord")) return 1;
            if (str_eq(w, "count")) {
                if (na == 1 && pkx_kind(o + 1) == PKK_VAR && pkx_isp(o + 2, ")") && (pkx_st(o + 1) & PKS_CAND)) return 1;
                return 0;
            }
            if ((str_eq(w, "min") || str_eq(w, "max")) && na == 2) {
                if (pkx_arg(ld64(as)) == 1 && pkx_arg(ld64(as + 8)) == 1) { pkx_at = m + 1; return 1; }
                pkx_at = m + 1;
                return 0;
            }
            if (str_eq(w, "abs") && na == 1) {
                i64 r = pkx_arg(ld64(as));
                pkx_at = m + 1;
                if (r == 1) return 1;
                return 0;
            }
            return 0;
        }
        if (pkx_isid(i, "new") || pkx_isid(i, "clone") || pkx_isid(i, "print") || pkx_isid(i, "match")
            || pkx_isid(i, "static") || pkx_isid(i, "throw") || pkx_isid(i, "instanceof")) return 0 - 1;
        pkx_at = pkx_skip(i + 1);
        return 0;
    }
    if (pkx_isp(i, "(")) {
        i64 m2 = pkx_mat(i);
        if (pkx_kind(i + 1) == PKK_ID && pkx_isp(i + 2, ")")) {
            uptr cw = ld64(pkx_t + (i + 1) * 8);
            if (str_eq(cw, "int") || str_eq(cw, "integer")) {
                i64 r2 = pkx_un(i + 3);
                if (r2 < 0) return 0 - 1;
                return 1;
            }
            if (str_eq(cw, "float") || str_eq(cw, "double") || str_eq(cw, "string") || str_eq(cw, "bool")
                || str_eq(cw, "boolean") || str_eq(cw, "array") || str_eq(cw, "object") || str_eq(cw, "binary")) {
                i64 r3 = pkx_un(i + 3);
                if (r3 < 0) return 0 - 1;
                return 0;
            }
        }
        i64 r4 = pkx_expr(i + 1);
        if (r4 < 0 || pkx_at != m2) r4 = 0;
        pkx_at = m2 + 1;
        if (pkx_postfix(m2 + 1)) { pkx_at = pkx_skip(m2 + 1); return 0; }
        // a parenthesised element read is normalised to a zval by ph_expr
        if (r4 == 2) return 0;
        return r4;
    }
    if (pkx_isp(i, "[")) { pkx_at = pkx_skip(pkx_mat(i) + 1); return 0; }
    return 0 - 1;
}

i64 pkx_un(i64 i) {
    if (pkx_isp(i, "-")) {
        i64 r = pkx_un(i + 1);
        if (r < 0) return 0 - 1;
        if (r >= 1) return 1;
        return 0;
    }
    if (pkx_isp(i, "+") || pkx_isp(i, "!") || pkx_isp(i, "~") || pkx_isp(i, "@")) {
        i64 r2 = pkx_un(i + 1);
        if (r2 < 0) return 0 - 1;
        return 0;
    }
    if (pkx_isp(i, "++") || pkx_isp(i, "--")) {
        i64 r3 = pkx_prim(i + 1);
        if (r3 < 0) return 0 - 1;
        return 0;
    }
    return pkx_prim(i);
}

i64 pkx_comb(i64 a, i64 b) { if (a >= 1 && b >= 1) return 1; return 0; }

i64 pkx_mul(i64 i) {
    i64 s = pkx_un(i);
    if (s < 0) return 0 - 1;
    loop {
        i64 j = pkx_at;
        if (pkx_isp(j, "*") || pkx_isp(j, "%")) {
            i64 r = pkx_un(j + 1);
            if (r < 0) return 0 - 1;
            s = pkx_comb(s, r);
            continue;
        }
        if (pkx_isp(j, "/")) {
            i64 r2 = pkx_un(j + 1);
            if (r2 < 0) return 0 - 1;
            s = 0;
            continue;
        }
        break;
    }
    return s;
}

i64 pkx_expr(i64 i) {
    i64 s = pkx_mul(i);
    if (s < 0) return 0 - 1;
    loop {
        i64 j = pkx_at;
        if (pkx_isp(j, "+") || pkx_isp(j, "-")) {
            i64 r = pkx_mul(j + 1);
            if (r < 0) return 0 - 1;
            s = pkx_comb(s, r);
            continue;
        }
        break;
    }
    return s;
}

// an expression from i that must END at a token of the given set: `;`,
// `)` `,` `]` for any=1, only `;` for any=0. Answers its shape or 0.
i64 pkx_rhs(i64 i, i64 any) {
    i64 r = pkx_expr(i);
    if (r < 0) return 0;
    i64 j = pkx_at;
    if (pkx_isp(j, ";")) return r;
    if (any && (pkx_isp(j, ")") || pkx_isp(j, ",") || pkx_isp(j, "]"))) return r;
    return 0;
}

// ---- the occurrences ------------------------------------------------------------
// a token that begins a statement
i64 pkx_stmt_start(i64 i) {
    if (i == 0) return 1;
    return pkx_isp(i - 1, ";") || pkx_isp(i - 1, "{") || pkx_isp(i - 1, "}");
}

// what may stand before a plain read of a variable
i64 pkx_read_prev(i64 i) {
    if (i == 0) return 1;
    i64 k = pkx_kind(i - 1);
    if (k == PKK_P) {
        if (pkx_isp(i - 1, "&") || pkx_isp(i - 1, "->") || pkx_isp(i - 1, "?->") || pkx_isp(i - 1, "::")
            || pkx_isp(i - 1, "\\") || pkx_isp(i - 1, "=>")) return 0;
        return 1;
    }
    if (k == PKK_ID) {
        return pkx_isid(i - 1, "return") || pkx_isid(i - 1, "echo") || pkx_isid(i - 1, "print")
            || pkx_isid(i - 1, "and") || pkx_isid(i - 1, "or") || pkx_isid(i - 1, "xor")
            || pkx_isid(i - 1, "throw") || pkx_isid(i - 1, "clone");
    }
    return 0;
}

// the later occurrence j is after the first one f and inside f's block
i64 pkx_dominated(i64 f, i64 j) {
    if (j <= f) return 0;
    i64 b = ld64(pkx_b + f * 8);
    if (b < 0) return 1;
    return j < pkx_mat(b);
}

// `$x = [];`, `$x = array();`, `$x = array_fill(0, N, V);` from the `=` at e
i64 pkx_init_form(i64 e) {
    if (pkx_isp(e + 1, "[") && pkx_isp(e + 2, "]") && pkx_isp(e + 3, ";")) return 1;
    if (pkx_isid(e + 1, "array") && pkx_isp(e + 2, "(") && pkx_isp(e + 3, ")") && pkx_isp(e + 4, ";")) return 1;
    if (pkx_isid(e + 1, "array_fill") && pkx_isp(e + 2, "(")) {
        i64 m = pkx_mat(e + 2);
        if (!pkx_isp(m + 1, ";")) return 0;
        if (!(pkx_kind(e + 3) == PKK_NUM && ld64(pkx_t + (e + 3) * 8) == 1 && ld64(pkx_v + (e + 3) * 8) == 0)) return 0;
        if (!pkx_isp(e + 4, ",")) return 0;
        if (pkx_expr(e + 5) != 1 || !pkx_isp(pkx_at, ",")) return 0;
        i64 v = pkx_at + 1;
        if (pkx_expr(v) != 1 || pkx_at != m) return 0;
        return 1;
    }
    return 0;
}

// the status name v can keep, checked occurrence by occurrence
i64 pkx_check(i64 v, i64 s) {
    uptr d = ld64(pkx_vn + v * 8);
    if (ld64(pkx_vx + v * 8)) return 0;
    if (ph_refset_has(d) || ph_gset_has(d)) return 0;
    i64 param = ph_var_find(d) >= 0;
    if (s == PKS_INT && param) {
        if (ph_var_type(d) != PT_INT || ph_is_ref(d)) return 0;
    }
    if ((s == PKS_CAND || s == PKS_INULL) && param) return 0;
    i64 first = 0 - 1;
    i64 nasg = 0;
    i64 i = 0;
    loop {
        if (i >= pkx_n) break;
        if (pkx_kind(i) != PKK_VAR || ld64(pkx_vi + i * 8) != v) { i = i + 1; continue; }
        i64 fl = ld64(pkx_f + i * 8);
        i64 isfirst = first < 0;
        if (isfirst) first = i;
        if (!isfirst && s != PKS_INT && !pkx_dominated(first, i)) return 0;
        i64 nx = i + 1;
        if (s == PKS_CAND) {
            if (fl) return 0;
            if (pkx_isp(nx, "=")) {
                if (!pkx_init_form(nx)) return 0;
                if (isfirst && !pkx_stmt_start(i)) return 0;
                if (!isfirst && !(pkx_stmt_start(i) || pkx_isp(i - 1, ")") || pkx_isid(i - 1, "else"))) return 0;
            } else {
                if (isfirst) return 0;
                if (pkx_isp(nx, "[")) {
                    i64 m = pkx_mat(nx);
                    i64 stmt = pkx_stmt_start(i) || pkx_isp(i - 1, ")") || pkx_isid(i - 1, "else");
                    if (m == nx + 1) {
                        if (!pkx_isp(m + 1, "=") || !stmt) return 0;
                        if (pkx_rhs(m + 2, 0) != 1) return 0;
                    } else {
                        if (pkx_expr(nx + 1) != 1 || pkx_at != m) return 0;
                        if (pkx_isp(m + 1, "=")) {
                            if (!stmt) return 0;
                            if (pkx_rhs(m + 2, 0) != 1) return 0;
                        } else {
                            if (pkx_postfix(m + 1) || pkx_isp(m + 1, "??")) return 0;
                            if (pkx_kind(m + 1) == PKK_P) {
                                i64 c2 = ld64(pkx_t + (m + 1) * 8);
                                if (((c2 >> 8) & 255) == 61 && (c2 >> 16) == 0 && (c2 & 255) != 61
                                    && (c2 & 255) != 33 && (c2 & 255) != 60 && (c2 & 255) != 62) return 0;   // op=
                                if (pkx_isp(m + 1, "**=") || pkx_isp(m + 1, "??=") || pkx_isp(m + 1, "<<=") || pkx_isp(m + 1, ">>=")) return 0;
                            }
                            if (!pkx_read_prev(i)) return 0;
                        }
                    }
                } else {
                    // $x itself: only as count($x)
                    if (!(pkx_isp(i - 1, "(") && pkx_isid(i - 2, "count") && pkx_isp(nx, ")"))) return 0;
                }
            }
            i = i + 1;
            continue;
        }
        // a scalar variable
        if (fl & PKF_KILL) return 0;
        if (!pkx_stmt_start(i) && !pkx_read_prev(i) && !pkx_isid(i - 1, "else")
            && !pkx_isp(i - 1, "++") && !pkx_isp(i - 1, "--")) return 0;
        if (pkx_isp(nx, "=")) {
            nasg = nasg + 1;
            if (s == PKS_INULL) {
                if (!isfirst || !pkx_stmt_start(i) || nasg > 1) return 0;
                if (pkx_rhs(nx + 1, 0) != 2) return 0;
                if (!(pkx_kind(nx + 1) == PKK_VAR && (pkx_st(nx + 1) & PKS_CAND))) return 0;
            } else {
                if (pkx_rhs(nx + 1, 1) != 1) return 0;
            }
            i = i + 1;
            continue;
        }
        if (s == PKS_INULL && (fl & PKF_ISSET)) return 0;
        if (pkx_isp(nx, "+=") || pkx_isp(nx, "-=") || pkx_isp(nx, "*=") || pkx_isp(nx, "%=")) {
            if (s != PKS_INT || isfirst && !param) return 0;
            if (pkx_rhs(nx + 1, 1) < 1) return 0;
            i = i + 1;
            continue;
        }
        if (pkx_isp(nx, "++") || pkx_isp(nx, "--") || pkx_isp(i - 1, "++") || pkx_isp(i - 1, "--")) {
            if (s != PKS_INT || isfirst && !param) return 0;
            i = i + 1;
            continue;
        }
        if (isfirst && !param) return 0;
        if (pkx_postfix(nx)) return 0;
        if (pkx_isp(i - 1, "++") || pkx_isp(i - 1, "--")) return 0;
        if (pkx_kind(nx) == PKK_P) {
            i64 c3 = ld64(pkx_t + nx * 8);
            if (((c3 >> 8) & 255) == 61 && (c3 >> 16) == 0 && (c3 & 255) != 61 && (c3 & 255) != 33
                && (c3 & 255) != 60 && (c3 & 255) != 62) return 0;                        // .= /= &= ...
            if ((c3 & 255) == 63 && ((c3 >> 8) & 255) == 63) return 0;                      // ?? and ??=
            if (pkx_isp(nx, "**=") || pkx_isp(nx, "<<=") || pkx_isp(nx, ">>=")) return 0;
        }
        if (!pkx_read_prev(i)) return 0;
        i = i + 1;
    }
    if (s == PKS_INULL && nasg != 1) return 0;
    return 1;
}

// Scan the body whose `{` the parser is on, and set pkx_names/pkx_inames.
void ph_pk_scan() {
    pkx_names = 0;
    pkx_inames = 0;
    pkx_bad = 0;
    pkx_n = 0;
    pkx_nv = 0;
    uptr src = p_cp();
    i64 len = p_src_end() - src;
    if (len <= 0) return;
    if (!pkx_k) {
        pkx_k = xalloc(PK_MAXT * 8);
        pkx_t = xalloc(PK_MAXT * 8);
        pkx_v = xalloc(PK_MAXT * 8);
        pkx_m = xalloc(PK_MAXT * 8);
        pkx_b = xalloc(PK_MAXT * 8);
        pkx_f = xalloc(PK_MAXT * 8);
        pkx_vi = xalloc(PK_MAXT * 8);
        pkx_vn = xalloc(PK_MAXV * 8);
        pkx_vs = xalloc(PK_MAXV * 8);
        pkx_vx = xalloc(PK_MAXV * 8);
    }
    pkx_lex(src, len);
    if (pkx_bad) return;
    pkx_nest();
    if (pkx_bad) return;
    // optimistic start: every name that opens with an array's initialisation
    // is a candidate, every other one an int; each check can only take a
    // status away, so the loop ends
    i64 v = 0;
    loop {
        if (v >= pkx_nv) break;
        i64 f = 0;
        loop { if (f >= pkx_n) break; if (pkx_kind(f) == PKK_VAR && ld64(pkx_vi + f * 8) == v) break; f = f + 1; }
        i64 s = PKS_INT;
        if (f < pkx_n && pkx_isp(f + 1, "=") && pkx_stmt_start(f)) {
            if (pkx_isp(f + 2, "[") || pkx_isid(f + 2, "array") || pkx_isid(f + 2, "array_fill")) s = PKS_CAND;
            if (pkx_kind(f + 2) == PKK_VAR && pkx_isp(f + 3, "[")) s = PKS_INULL;
        }
        st64(pkx_vs + v * 8, s);
        v = v + 1;
    }
    loop {
        i64 changed = 0;
        v = 0;
        loop {
            if (v >= pkx_nv) break;
            i64 s2 = ld64(pkx_vs + v * 8);
            // a failed PT_INULL may still be an int (`$t = $x[$i] + 1;`)
            if (s2 && !pkx_check(v, s2)) {
                i64 ns = 0;
                if (s2 == PKS_INULL) ns = PKS_INT;
                st64(pkx_vs + v * 8, ns);
                changed = 1;
            }
            v = v + 1;
        }
        if (!changed) break;
    }
    // the answer, as two 0-terminated lists
    pkx_names = xalloc(pkx_nv * 8 + 8);
    pkx_inames = xalloc(pkx_nv * 8 + 8);
    i64 a = 0;
    i64 b = 0;
    v = 0;
    loop {
        if (v >= pkx_nv) break;
        i64 s3 = ld64(pkx_vs + v * 8);
        if (s3 == PKS_CAND) { st64(pkx_names + a * 8, ld64(pkx_vn + v * 8)); a = a + 1; }
        if (s3 == PKS_INULL) { st64(pkx_inames + b * 8, ld64(pkx_vn + v * 8)); b = b + 1; }
        v = v + 1;
    }
    st64(pkx_names + a * 8, 0);
    st64(pkx_inames + b * 8, 0);
}

// a prediction the lowering does not meet: the scan above is wrong, and the
// program would be too -- stop, and say where
void ph_pk_disagree(uptr fl, i64 line, uptr what) {
    err_at2(fl, line, "mc-php: internal: src/packed.mc's proof disagrees with the lowering", what);
}

// ns.mc -- php namespaces: every name the source declares or names is
// resolved to the FULLY QUALIFIED one php would use, with php's rules.
//
// A namespace is per FILE in php (an included file starts in the global
// one), and so are its `use` imports: both are kept against the file they
// were written in (ph_tfile). What a declaration gets is `ns\name`; what a
// use site gets:
//
//   \A\B          A\B, whatever it names
//   namespace\B   ns\B
//   A\B           A's import (`use X\A;` or `use X\A as A;`) + \B, else ns\A\B
//   B, a class    its import, else ns\B -- a class name has no fallback
//   B, a function or a constant
//                 its `use function`/`use const` import; else ns\B when the
//                 source declares that; else the GLOBAL B (php's fallback,
//                 which is how `strlen()` inside a namespace is php's own)
//
// The lexer hands a qualified name over as ONE identifier, backslashes and
// all (src/lex.mc's ph_next), so every place that reads a name reads it whole.
// A name as the runtime and php see it never has the leading backslash.

#define PH_MAXNS  64
uptr ph_nsf[PH_MAXNS];                  // the file
uptr ph_nsn[PH_MAXNS];                  // its namespace, "" = the global one
i64  ph_nns;

#define PH_MAXUSE 256
uptr ph_usf[PH_MAXUSE];                 // the file
i64  ph_usk[PH_MAXUSE];                 // 0 a class or namespace, 1 a function, 2 a constant
uptr ph_usa[PH_MAXUSE];                 // the alias, lowercase for 0 and 1
uptr ph_ust[PH_MAXUSE];                 // what it stands for, fully qualified
i64  ph_nuse;

i64 ph_ns_bs(uptr s) {
    i64 i = 0;
    loop { i64 c = ld8(s + i); if (!c) break; if (c == 92) return i; i = i + 1; }
    return -1;
}

uptr ph_ns_lower(uptr s) {
    i64 n = cstrlen(s);
    uptr o = xalloc(n + 1);
    i64 i = 0;
    loop { if (i > n) break; i64 c = ld8(s + i); if (c >= 65 && c <= 90) c = c + 32; st8(o + i, c); i = i + 1; }
    return o;
}

// the namespace of the file being read, "" when it declared none
uptr ph_ns_cur() {
    i64 i = ph_nns;
    loop { if (i == 0) break; i = i - 1; if (str_eq(ld64(ph_nsf + i * 8), ph_tfile)) return ld64(ph_nsn + i * 8); }
    return "";
}

uptr ph_ns_join(uptr a, uptr b) {
    if (!ld8(a)) return b;
    uptr s = p_cat(a, "\\", 0, 1);
    return p_cat(s, b, 0, cstrlen(b));
}

// `namespace X;`: X for the rest of this file, and its imports forgotten
void ph_ns_set(uptr name, uptr fl, i64 line) {
    if (ph_nns >= PH_MAXNS) err_at(fl, line, "mc-php: too many namespace declarations");
    st64(ph_nsf + ph_nns * 8, ph_tfile);
    st64(ph_nsn + ph_nns * 8, name);
    ph_nns = ph_nns + 1;
    i64 i = 0;
    loop {
        if (i >= ph_nuse) break;
        if (str_eq(ld64(ph_usf + i * 8), ph_tfile)) st64(ph_usf + i * 8, "");
        i = i + 1;
    }
}

void ph_ns_use(i64 kind, uptr alias, uptr target, uptr fl, i64 line) {
    if (ph_nuse >= PH_MAXUSE) err_at(fl, line, "mc-php: too many use imports");
    st64(ph_usf + ph_nuse * 8, ph_tfile);
    st64(ph_usk + ph_nuse * 8, kind);
    if (kind != 2) alias = ph_ns_lower(alias);
    st64(ph_usa + ph_nuse * 8, alias);
    st64(ph_ust + ph_nuse * 8, target);
    ph_nuse = ph_nuse + 1;
}

uptr ph_ns_import(i64 kind, uptr alias) {
    if (kind != 2) alias = ph_ns_lower(alias);
    i64 i = ph_nuse;
    loop {
        if (i == 0) break;
        i = i - 1;
        if (ld64(ph_usk + i * 8) == kind && str_eq(ld64(ph_usf + i * 8), ph_tfile)
            && str_eq(ld64(ph_usa + i * 8), alias)) return ld64(ph_ust + i * 8);
    }
    return 0;
}

// the last segment: what `use A\B;` imports as
uptr ph_ns_last(uptr s) {
    i64 k = -1;
    i64 i = 0;
    loop { i64 c = ld8(s + i); if (!c) break; if (c == 92) k = i; i = i + 1; }
    return s + k + 1;
}

// A name with a namespace part, resolved the way every kind resolves one:
// \A\B, namespace\B, or A\B through A's import. 0 for an unqualified name.
uptr ph_ns_qual(uptr raw) {
    if (ld8(raw) == 92) return raw + 1;
    i64 k = ph_ns_bs(raw);
    if (k < 0) return 0;
    uptr head = xstrdup(raw, k);
    uptr rest = raw + k + 1;
    if (str_eq(ph_ns_lower(head), "namespace")) return ph_ns_join(ph_ns_cur(), rest);
    uptr t = ph_ns_import(0, head);
    if (t) return ph_ns_join(t, rest);
    return ph_ns_join(ph_ns_cur(), raw);
}

// a CLASS name as written, fully qualified
uptr ph_ns_class(uptr raw) {
    uptr q = ph_ns_qual(raw);
    if (q) return q;
    uptr l = ph_ns_lower(raw);
    if (str_eq(l, "self") || str_eq(l, "static") || str_eq(l, "parent")) return raw;
    uptr t = ph_ns_import(0, raw);
    if (t) return t;
    return ph_ns_join(ph_ns_cur(), raw);
}

// the name a declaration in this file gets
uptr ph_ns_decl(uptr name) { return ph_ns_join(ph_ns_cur(), name); }

i64 ph_ns_declared_fn(uptr fq) {
    if (ph_fn_find0(fq) >= 0) return 1;
    if (ph_decl_find(fq) >= 0) return 1;
    return 0;
}

// A FUNCTION or CONSTANT name as written. `*fb` is set to 1 when the answer
// is php's global fallback for an unqualified name inside a namespace, so a
// call php's function table answers can try `ns\name` first, as php does.
uptr ph_ns_fc(uptr raw, i64 cst, uptr fb) {
    st64(fb, 0);
    uptr q = ph_ns_qual(raw);
    if (q) return q;
    uptr t = ph_ns_import(1 + cst, raw);
    if (t) return t;
    uptr ns = ph_ns_cur();
    if (!ld8(ns)) return raw;
    uptr fq = ph_ns_join(ns, raw);
    if (cst && ph_const_find(fq) >= 0) return fq;
    if (!cst && ph_ns_declared_fn(fq)) return fq;
    st64(fb, 1);
    return raw;
}

// ---- the statements -----------------------------------------------------------
// Only a file's top level reads these (src/program.mc); in a block or a
// function body src/lvalue.mc refuses them. `namespace X;`, and the braced
// form `namespace X { ... }` / `namespace { }`: its statements are the
// file's top-level ones (src/program.mc's loop reads them, so a function
// declared in it is a top-level declaration), and its `}` puts the file back
// in the global namespace
//
// A braced block belongs to its FILE: a file required inside one declares its
// own namespace (and may open its own block), so the open blocks are a stack
// of the files that opened them, and only the file on top can close one.
#define PH_MAXBR 16
uptr ph_nsbr[PH_MAXBR];
i64  ph_nnsbr;
i64 ph_ns_open_here() { return ph_nnsbr > 0 && str_eq(ld64(ph_nsbr + (ph_nnsbr - 1) * 8), ph_tfile); }

void ph_ns_stmt(uptr fl, i64 line) {
    ph_next();
    uptr name = "";
    if (ph_tid == T_IDENT) { name = ph_tname; if (ld8(name) == 92) name = name + 1; ph_next(); }
    // checked before the namespace changes: src/program.mc's loop is the
    // only caller, so what is left to refuse is one inside a braced block
    if (ph_ns_open_here()) err_at(fl, line, "mc-php: a namespace declaration inside a braced namespace");
    // set before the next token is read: after the last token of a required
    // file, that token is the including file's
    ph_ns_set(name, fl, line);
    if (ph_at("{", 1)) {
        if (ph_nnsbr >= PH_MAXBR) err_at(fl, line, "mc-php: too many nested required files in braced namespaces");
        st64(ph_nsbr + ph_nnsbr * 8, fl);
        ph_nnsbr = ph_nnsbr + 1;
        ph_next();
        return;
    }
    ph_semi("expected ; after namespace");
}

// the `}` of a braced namespace, read by the top-level loop
i64 ph_ns_close() {
    if (!ph_ns_open_here() || !ph_at("}", 1)) return 0;
    ph_nnsbr = ph_nnsbr - 1;
    ph_ns_set("", ph_tfile, ph_tline);
    ph_next();
    return 1;
}

// `use A\B;`, `use A\B as C, D;`, `use function A\f;`, `use const A\X;`,
// `use A\{B, C as D};`
void ph_ns_use_stmt(uptr fl, i64 line) {
    ph_next();
    i64 kind = 0;
    if (ph_is("function")) { kind = 1; ph_next(); }
    else if (ph_is("const")) { kind = 2; ph_next(); }
    loop {
        if (ph_tid != T_IDENT) err_at2(fl, line, "mc-php: a name was expected after use", ph_tname);
        uptr t = ph_tname;
        if (ld8(t) == 92) t = t + 1;
        ph_next();
        if (ph_at("{", 1) || (ld8(t) && ph_at("\\", 1))) {
            // the group form: the prefix, then its members
            if (ph_accept("\\", 1)) {}
            ph_want("{", 1, "expected { in a group use");
            uptr pre = t;
            i64 n = cstrlen(pre);
            if (n && ld8(pre + n - 1) == 92) pre = xstrdup(pre, n - 1);
            loop {
                if (ph_at("}", 1)) break;
                i64 k2 = kind;
                if (ph_is("function")) { k2 = 1; ph_next(); }
                else if (ph_is("const")) { k2 = 2; ph_next(); }
                uptr m = ph_ns_join(pre, ph_tname);
                ph_next();
                uptr a = ph_ns_last(m);
                if (ph_is("as")) { ph_next(); a = ph_tname; ph_next(); }
                ph_ns_use(k2, a, m, fl, line);
                if (!ph_accept(",", 1)) break;
            }
            ph_want("}", 1, "expected } in a group use");
        } else {
            uptr a = ph_ns_last(t);
            if (ph_is("as")) { ph_next(); a = ph_tname; ph_next(); }
            ph_ns_use(kind, a, t, fl, line);
        }
        if (!ph_accept(",", 1)) break;
    }
    ph_semi("expected ; after use");
}

// ---- the lexer's half -------------------------------------------------------
// At q, a qualified name -- `\A`, `A\B`, `namespace\B` -- as one token: its
// end, or 0 when q starts no name that has a backslash in it.
uptr ph_ns_scan(uptr q, uptr e) {
    uptr p = q;
    i64 bs = 0;
    if (p < e && ld8(p) == 92) { p = p + 1; bs = 1; }
    loop {
        if (p >= e || !ph_name_byte(ld8(p), 1)) return 0;
        p = p + 1;
        loop { if (p >= e) break; if (!ph_name_byte(ld8(p), 0)) break; p = p + 1; }
        if (p + 1 < e && ld8(p) == 92 && ph_name_byte(ld8(p + 1), 1)) { p = p + 1; bs = 1; continue; }
        break;
    }
    if (!bs) return 0;
    return p;
}

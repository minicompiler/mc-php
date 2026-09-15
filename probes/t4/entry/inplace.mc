// Entry shape (iv): rewrite the entry IN PLACE, inside the on_source callback,
// in the buffer the lexer is about to read. No push, so no duplicate parse.

i64 ip_ends(uptr s, uptr sfx) {
    i64 n = cstrlen(s);
    i64 m = cstrlen(sfx);
    if (m > n) return 0;
    return str_eq(s + n - m, sfx);
}

void ip_source(uptr name, uptr src, i64 len) {
    if (!ip_ends(name, ".php")) return;
    i64 i = 0;
    i64 n = 0;
    loop {
        if (i >= len) break;
        i64 c = ld8(src + i);
        if (c == 39) { st8(src + i, 34); n = n + 1; }
        if (c == 35) { st8(src + i, 47); n = n + 1; }
        i = i + 1;
    }
    out_str(2, "  rewrote ");
    out_num(2, n);
    out_str(2, " bytes in ");
    out_str(2, name);
    out_str(2, "\n");
}

void user_init() { on_source(&ip_source); }

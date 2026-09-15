// Entry-shape probe: report every source the lexer pushes and whether the
// .php claim fires for it. Registrations only; nothing is parsed differently.

i64 ep_ends(uptr s, uptr sfx) {
    i64 n = cstrlen(s);
    i64 m = cstrlen(sfx);
    if (m > n) return 0;
    return str_eq(s + n - m, sfx);
}

void ep_source(uptr name, uptr src, i64 len) {
    out_str(2, "  source: ");
    out_str(2, name);
    out_str(2, " len=");
    out_num(2, len);
    out_str(2, "\n");
}

i64 ep_claim(uptr name) {
    i64 mine = ep_ends(name, ".php");
    out_str(2, "  claim: ");
    out_str(2, name);
    if (mine) out_str(2, " -> 1\n");
    if (!mine) out_str(2, " -> 0\n");
    return mine;
}

void user_init() {
    on_source(&ep_source);
    source_claim(&ep_claim);
}

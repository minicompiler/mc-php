// Entry shape (iii): capture the entry with on_source, rewrite it, push the
// rewritten text with p_push_source from user_init, and see what the parser
// reads -- the pushed text only, or the pushed text and then the original.

uptr px_src;
i64  px_len;
uptr px_name;

i64 px_ends(uptr s, uptr sfx) {
    i64 n = cstrlen(s);
    i64 m = cstrlen(sfx);
    if (m > n) return 0;
    return str_eq(s + n - m, sfx);
}

void px_source(uptr name, uptr src, i64 len) {
    if (px_ends(name, ".php")) {
        px_name = name;
        px_src  = src;
        px_len  = len;
    }
}

i64 px_claim(uptr name) {
    out_str(2, "  claim: ");
    out_str(2, name);
    out_str(2, "\n");
    return px_ends(name, ".php");
}

void user_init() {
    on_source(&px_source);
    source_claim(&px_claim);
    if (px_src) {
        // the crudest possible rewrite: ' -> " and # -> / (byte for byte, so
        // every line and column is preserved).
        uptr d = xalloc(px_len + 1);
        i64 i = 0;
        loop {
            if (i >= px_len) break;
            i64 c = ld8(px_src + i);
            if (c == 39) c = 34;
            if (c == 35) c = 47;
            st8(d + i, c);
            i = i + 1;
        }
        st8(d + px_len, 0);
        out_str(2, "  pushing rewritten ");
        out_str(2, px_name);
        out_str(2, "\n");
        p_push_source("rewritten.php", d, px_len);
    }
}

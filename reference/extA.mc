// Extension A publishes a plain C-level symbol. Nothing php-specific about it:
// mc emits it as a global, and `ld -bundle` exports every global by default.
u64 mA[21]; u64 fA[12]; u64 aiA[4];
i64 mcx_add(i64 a, i64 b) { return a + b; }
void zif_a_add(uptr ex, uptr rv) { st64(rv, mcx_add(ld64(ex + 80), ld64(ex + 96))); st32(rv + 8, 4); }
uptr get_module() {
    uptr fe = &fA;
    st64(fe + 0, "a_add"); st64(fe + 8, &zif_a_add); st64(fe + 16, &aiA); st32(fe + 24, 2);
    uptr m = &mA;
    st16(m + 0, 168); st32(m + 4, 20250925);
    st64(m + 32, "extA"); st64(m + 40, fe);
    st64(m + 88, "0.1.0"); st64(m + 160, "API20250925,NTS");
    return m;
}

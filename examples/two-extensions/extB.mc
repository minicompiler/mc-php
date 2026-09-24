// HAND-WRITTEN mc, not mc-php output -- README.md says why, and what the
// compiler is missing to write it from extB.php.
//
// Extension B reaches A's symbol through the loader, LATE -- at call time, not
// at MINIT, so the load order of the two extensions does not matter. With A
// not loaded at all, b_use answers -1.
//
// A TEMPLATE: tests/examples.sh fills @API@, @DEBUG@, @ZTS@ and @BUILDID@
// from `php -i`, and @RTLD_DEFAULT@ from the host: dlsym's "search every
// global image" handle is (void *)-2 on macOS and (void *)0 on Linux.
extern uptr dlsym(i64 h, uptr name);
u64 mB[21]; u64 fB[12]; u64 aiB[4];
void zif_b_use(uptr ex, uptr rv) {
    uptr f = dlsym(@RTLD_DEFAULT@, "mcx_add");
    if (f == 0) { st64(rv, 0 - 1); st32(rv + 8, 4); return; }
    st64(rv, callp(f, ld64(ex + 80), ld64(ex + 96))); st32(rv + 8, 4);
}
uptr get_module() {
    uptr fe = &fB;
    st64(fe + 0, "b_use"); st64(fe + 8, &zif_b_use); st64(fe + 16, &aiB); st32(fe + 24, 2);
    uptr m = &mB;
    st16(m + 0, 168); st32(m + 4, @API@);
    st8(m + 8, @DEBUG@); st8(m + 9, @ZTS@);
    st64(m + 32, "extB"); st64(m + 40, fe);
    st64(m + 88, "0.1.0"); st64(m + 160, "@BUILDID@");
    return m;
}

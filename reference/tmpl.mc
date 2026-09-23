// Generated shape of a php extension. Everything the target php decides --
// the API number, TS/NTS, debug -- is filled from `php -i` at build time.
#include <prelude>
extern void zend_type_error(uptr fmt);

u64 mcb_module[21];
u64 mcb_fns[18];
u64 mcb_ai[8];

i64 fib(i64 n) { if (n < 2) { return n; } return fib(n - 1) + fib(n - 2); }
i64 sum(i64 n) { i64 s = 0; i64 i = 1; while (i <= n) { s = s + i % 7; i = i + 1; } return s; }

void h_fib(uptr ex, uptr rv) {
    uptr a = ex + 80;
    if (ld32(a + 8) != 4) { zend_type_error("mcb_fib(): Argument #1 ($n) must be of type int"); st32(rv + 8, 1); return; }
    st64(rv, fib(ld64(a))); st32(rv + 8, 4);
}
void h_sum(uptr ex, uptr rv) {
    uptr a = ex + 80;
    if (ld32(a + 8) != 4) { zend_type_error("mcb_sum(): Argument #1 ($n) must be of type int"); st32(rv + 8, 1); return; }
    st64(rv, sum(ld64(a))); st32(rv + 8, 4);
}

void ent(uptr fe, i64 i, uptr name, uptr h, uptr ai) {
    uptr e = fe + i * 48;
    st64(e + 0, name); st64(e + 8, h); st64(e + 16, ai); st32(e + 24, 1);
}

uptr get_module() {
    uptr ai = &mcb_ai;
    st64(ai + 0, 1); st64(ai + 16, 16);
    st64(ai + 32, "n"); st64(ai + 48, 16);
    uptr fe = &mcb_fns;
    ent(fe, 0, "mcb_fib", &h_fib, ai);
    ent(fe, 1, "mcb_sum", &h_sum, ai);
    uptr me = &mcb_module;
    st16(me + 0, 168);
    st32(me + 4, @API@);
    st8(me + 8, @DEBUG@);          // zend_debug
    st8(me + 9, @ZTS@);            // zts
    st64(me + 32, "mcb"); st64(me + 40, fe);
    st64(me + 88, "0.1.0");
    st64(me + 160, "@BUILDID@");
    return me;
}

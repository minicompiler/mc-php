// T2 -- the mc side.
//
// Two questions in one binary:
//   (a) can a .so dlopen'd by this binary resolve a symbol this binary defines?
//   (b) can a function written in mc be called from C as a VARIADIC callee?
//
// (b) rests on one alignment of two documented facts on Apple arm64:
//   - a C caller of a variadic function puts every variadic argument on the
//     stack, 8 bytes each, starting at [sp] at the call (verified by
//     disassembling ext.so: `str x8, [x9]` / `str x8, [x9, #8]` with x9 = sp);
//   - an mc callee reads parameter 9 at [x29 + 16] and parameter 10 at
//     [x29 + 24] (mc docs/reference/objects.md § 4), and [x29 + 16] IS the
//     caller's sp, because `stp x29, x30, [sp, #-16]!` is what moved it.
// So variadic argument N lands in mc parameter 8 + N. Parameters 2..8 are read
// out of x1..x7, which a variadic caller never sets: they are junk and unused.

#include <sys>
#include <io>

extern uptr dlopen(uptr path, i64 mode);
extern uptr dlsym(uptr handle, uptr name);
extern uptr dlerror();

#define RTLD_NOW 2

void nl() { write(1, "\n", 1); }

// (a) a fixed-arity callee, the plain "export a symbol" case
i64 mcphp_cb(i64 a, i64 b) {
    return a + b;
}

// (b) the variadic callee. Called from C as mcphp_va("ll", 7, 35).
// v1 is parameter 9, v2 is parameter 10.
i64 mcphp_va(uptr fmt, i64 x1, i64 x2, i64 x3, i64 x4, i64 x5, i64 x6, i64 x7,
             i64 v1, i64 v2) {
    // fmt is real (x0). x1..x7 are junk and are not read.
    return v1 * 100 + v2;
}

// four variadic arguments: parameters 9, 10, 11 and 12. There is no
// parameter 13 in mc ("at most 12 parameters"), so four is the ceiling for a
// variadic callee with one named argument.
i64 mcphp_va4(uptr fmt, i64 x1, i64 x2, i64 x3, i64 x4, i64 x5, i64 x6, i64 x7,
              i64 v1, i64 v2, i64 v3, i64 v4) {
    return ((v1 * 10 + v2) * 10 + v3) * 10 + v4;
}

i64 report(uptr name, uptr h, i64 want) {
    uptr f = dlsym(h, name);
    if (f == 0) {
        puts("  ");
        puts(name);
        puts(": dlsym failed: ");
        puts(dlerror());
        nl();
        return 1;
    }
    i64 got = callp(f);
    puts("  ");
    puts(name);
    puts(" = ");
    putnum(got);
    puts(" (want ");
    putnum(want);
    puts(") ");
    if (got == want) puts("OK"); else puts("WRONG");
    nl();
    if (got == want) return 0;
    return 1;
}

i64 main(i64 argc, uptr argv) {
    if (argc < 2) {
        puts("usage: host <ext.so>\n");
        return 2;
    }
    uptr path = ld64(argv + 8);

    // keep both callees addressable even if the linker were to prune
    if (ld64(&mcphp_cb) == 0) return 9;
    if (ld64(&mcphp_va) == 0) return 9;
    if (ld64(&mcphp_va4) == 0) return 9;

    uptr h = dlopen(path, RTLD_NOW);
    if (h == 0) {
        puts("dlopen failed: ");
        puts(dlerror());
        nl();
        return 1;
    }
    puts("dlopen OK\n");

    i64 bad = 0;
    bad = bad + report("ext_call_cb", h, 42);       // mcphp_cb(7, 35)
    bad = bad + report("ext_call_va", h, 735);      // mcphp_va("ll", 7, 35)
    bad = bad + report("ext_call_c_va", h, 735);    // the C oracle, same call
    bad = bad + report("ext_call_va4", h, 1234);   // four variadic arguments
    bad = bad + report("ext_call_c_va4", h, 1234); // the C oracle, same call
    if (bad != 0) return 1;
    puts("T2 OK\n");
    return 0;
}

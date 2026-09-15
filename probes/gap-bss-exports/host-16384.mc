// Minimal reproducer: an mc --exe binary whose exported symbols become
// invisible to dlopen once its __bss reaches one page.
//
// 16384 is substituted by run.sh. Everything else is identical between the
// two builds.

#include <sys>
#include <io>

extern uptr dlopen(uptr path, i64 mode);
extern uptr dlsym(uptr handle, uptr name);
extern uptr dlerror();

u8 pad[16384];

i64 mc_answer() { return 42; }

i64 main(i64 argc, uptr argv) {
    if (argc < 2) return 2;
    // keep pad addressable so it cannot be optimised away
    st8(pad, 1);
    uptr h = dlopen(ld64(argv + 8), 2);
    if (h == 0) {
        puts("FAIL ");
        puts(dlerror());
        write(1, "\n", 1);
        return 1;
    }
    putnum(callp(dlsym(h, "go")));
    write(1, "\n", 1);
    return 0;
}

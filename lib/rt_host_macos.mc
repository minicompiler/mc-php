// rt_host_macos.mc -- the macOS half of the RUNTIME's system layer.
//
// This file is about the programs mc-php WRITES, not about the compiler that
// writes them. The compiler's own host layer is mc's (`#include <mc/host>` in
// src/mc-php.mc); this one is pushed, by src/program.mc, into every program
// the compiler compiles, ahead of lib/php_rt.mc.
//
// It is the shape mc gave its own host layer (src/host_macos.mc,
// src/host_linux*.mc): one file per operating system, chosen by the entry and
// never by a conditional, because there is no such thing in this language.
//
// Everything here was IN lib/php_rt.mc until the hosts branch: the
// `#include <sys>` at the top and the fourteen declarations plus the flags that
// sat above the stream table. Nothing about it changed for macOS -- the same
// calls, the same numbers, the same two struct stat offsets -- which is what
// makes the macOS grid and the macOS gates the regression proof for the split.
//
// These six are `#include <sys>`'s, written out instead of included, and the
// reason is what a PROGRAM needs and not what this file reads better as. Since
// mc's M52 `<sys>` is a LIBRARY name resolved out of a tree beside `mc`, and a
// runtime that names it makes every program mc-php compiles need that tree --
// `#include <sys>: not in this compiler and mc 1.1.0's library tree was not
// found: run mc install`, which is what the README used to have a section
// about. Declared here, mc-php needs nothing installed to compile a `.php`.
//
// lib/io.mc's strlen/puts/putnum come with `<sys>` and go with it; the runtime
// never called them (it has php_strlen and php_cstrlen of its own).
extern i64 open(uptr path, i64 flags, i64 mode);
extern i64 creat(uptr path, i64 mode);
extern i64 read(i64 fd, uptr buf, i64 n);
extern i64 write(i64 fd, uptr buf, i64 n);
extern i64 close(i64 fd);
extern void exit(i64 code);

// The five T8 declared for itself and the nine php's stream and filesystem
// functions need. Every one of them is in libSystem under this name with this
// signature.
extern i64 stat(uptr path, uptr buf);
extern i64 lseek(i64 fd, i64 off, i64 whence);
extern i64 access(uptr path, i64 mode);
extern uptr getenv(uptr name);
extern i64 unlink(uptr path);
extern i64 rename(uptr from, uptr to);
extern i64 mkdir(uptr path, i64 mode);
extern i64 rmdir(uptr path);
extern i64 getpid();
extern uptr getcwd(uptr buf, i64 n);
extern i64 chdir(uptr path);
extern i64 chmod(uptr path, i64 mode);
extern i64 putenv(uptr kv);
extern i64 unsetenv(uptr name);
// setlocale(3): the runtime has only the C locale (D10, byte-oriented), but
// whether a name it does not have is REFUSED is this host's libc's answer and
// not something a table here can hold -- macOS and glibc return NULL for an
// unknown locale and musl accepts any name and hands it back. php calls the
// same function, so asking it is the only way the two can agree on every host.
extern uptr setlocale(i64 category, uptr name);

// macOS sys/fcntl.h. They are per-system values -- Linux's O_CREAT is 0x40 and
// this one is 0x200 -- which is why they are in a host file at all.
#define O_RDONLY  0
#define O_WRONLY  1
#define O_CREAT   0x200
#define O_TRUNC   0x400
#define O_RDWR    2
#define O_APPEND  8
#define O_EXCL    0x800
#define S_IFMT    0xf000
#define S_IFREG   0x8000
#define S_IFDIR   0x4000

// struct stat's layout is the host's answer and nothing else's: on macOS
// st_mode is a 16-bit field at offset 4 and st_size a 64-bit one at 96. The
// two readers live here rather than in php_rt.mc so that the offsets and the
// declaration that produces the buffer are in one file.
i64 php_stat_mode(uptr p) {
    u8 sb[160];
    if (stat(p, sb) != 0) return 0 - 1;
    return ld16(sb + 4);
}

i64 php_stat_size(uptr p) {
    u8 sb[160];
    if (stat(p, sb) != 0) return 0 - 1;
    return ld64(sb + 96);
}

// php's path answers and php's setlocale, per host, because php's own differ
// per host: on Windows a backslash separates too (IS_SLASH in php-src), a
// root is written "\\" and "C:" is a drive, and setlocale refuses a name
// shaped like "xx_YY" before the C library sees it (ext/standard/string.c, a
// BC rule). Here every one of them is the plain POSIX answer.
i64 php_is_sep(i64 c) { return c == '/'; }
i64 php_dir_sep() { return '/'; }
i64 php_drive_len(uptr p, i64 n) { return 0; }
i64 php_base_colon(uptr s, i64 pos) { return 0; }
uptr php_setlocale(i64 cat, uptr name) { return setlocale(cat, name); }

// A symbol of the process by name: only the extension road asks, for the
// engine's executor_globals (lib/php_ext.mc § engine values). dlsym's "search
// every global image" handle is (void *)-2 here.
extern uptr dlsym(i64 h, uptr name);
uptr php_dlsym(uptr name) { return dlsym(0 - 2, name); }

// C's errno for the calling thread, which `#[Extern('c')] function errno(): int`
// reads (src/extern.mc): the macro is __error() here
extern uptr __error();
i64 php_c_errno() { return ld32(__error()); }

// ---- threads (lib/php_rt.mc § the thread block, § other threads) --------------
// The thread block of the calling thread, once a second thread runs compiled
// code: POSIX thread-specific data, one key made the first time.
extern i64 pthread_key_create(uptr key, uptr dtor);
extern uptr pthread_getspecific(i64 key);
extern i64 pthread_setspecific(i64 key, uptr v);
extern i64 pthread_attr_init(uptr attr);
extern i64 pthread_attr_setstacksize(uptr attr, i64 n);
extern i64 pthread_attr_destroy(uptr attr);
extern i64 pthread_create(uptr tid, uptr attr, uptr fn, uptr arg);
extern i64 pthread_join(uptr tid, uptr ret);
extern uptr mmap(uptr addr, i64 n, i64 prot, i64 flags, i64 fd, i64 off);
extern i64 munmap(uptr addr, i64 n);
i64 ph_tkey;
uptr ph_tget() { return pthread_getspecific(ph_tkey); }
void ph_tset(uptr b) { pthread_setspecific(ph_tkey, b); }
void ph_tinit() {
    u8 k[8];
    st64(k, 0);
    pthread_key_create(k, 0);
    ph_tkey = ld64(k);
}
// fresh zeroed pages (MAP_PRIVATE | MAP_ANON), 0 when the kernel says no
uptr ph_os_map(i64 n) {
    uptr p = mmap(0, n, 3, 0x1002, 0 - 1, 0);
    if (p + 1 == 0) return 0;
    return p;
}
void ph_os_unmap(uptr p, i64 n) { munmap(p, n); }
// the size of a thread's arena: reserved: pages are touched as used
i64 ph_os_arena() { return 268435456; }
// the process's virtual size in bytes, -1 when it cannot be read:
// MACH_TASK_BASIC_INFO's virtual_size (mcphp_vm(), a test gate)
extern i64 task_self_trap();
extern i64 task_info(i64 task, i64 flavor, uptr info, uptr count);
i64 ph_os_vm() {
    u8 b[48];
    u8 c[8];
    st64(c, 12);                                             // MACH_TASK_BASIC_INFO_COUNT
    if ((task_info(task_self_trap() & 0xffffffff, 20, b, c) & 0xffffffff) != 0) return 0 - 1;
    return ld64(b);
}
// a thread on an 8 MiB stack (a secondary thread's default is smaller than
// the booting one's, and compiled php recurses as deep); 0 when it started
i64 ph_thr_create(uptr fn, uptr arg, uptr h) {
    u8 attr[128];
    pthread_attr_init(attr);
    pthread_attr_setstacksize(attr, 8388608);
    i64 r = pthread_create(h, attr, fn, arg) & 0xffffffff;      // an int: 0 or an error number
    pthread_attr_destroy(attr);
    return r;
}
void ph_thr_join(uptr h) { pthread_join(ld64(h), 0); }

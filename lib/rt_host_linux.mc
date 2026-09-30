// rt_host_linux.mc -- the Linux half of the RUNTIME's system layer, shared by
// both architectures. See lib/rt_host_macos.mc for what a runtime host layer
// is and who pushes one.
//
// It is split for the reason mc split lib/sys_linux.mc: one answer below it
// depends on the ARCHITECTURE and not on the operating system -- the layout of
// `struct stat`, whose st_mode sits at offset 16 on aarch64 and 24 on x86-64.
// The file that carries it is lib/rt_host_linux_aarch64.mc or
// lib/rt_host_linux_x86_64.mc, and src/program.mc pushes that one beside this.
//
// Nothing here is includable on its own.
//
// There is no `#include <sys>`: that file is libSystem's, and its O_ flags are
// macOS's. Every name below is in musl and in glibc alike, under this name and
// with this signature, which is the whole reason the runtime needed no other
// change -- only these declarations did.

extern i64 open(uptr path, i64 flags, i64 mode);
extern i64 creat(uptr path, i64 mode);
extern i64 read(i64 fd, uptr buf, i64 n);
extern i64 write(i64 fd, uptr buf, i64 n);
extern i64 close(i64 fd);
extern void exit(i64 code);

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

// asm-generic/fcntl.h, which both architectures use. Four of these differ from
// macOS's and the difference is silent if it is got wrong: O_CREAT is 0x40
// here and 0x200 there, O_TRUNC 0x200 and 0x400, O_APPEND 0x400 and 8,
// O_EXCL 0x80 and 0x800.
#define O_RDONLY  0
#define O_WRONLY  1
#define O_RDWR    2
#define O_CREAT   0x40
#define O_TRUNC   0x200
#define O_APPEND  0x400
#define O_EXCL    0x80

// These three are the same everywhere POSIX is.
#define S_IFMT    0xf000
#define S_IFREG   0x8000
#define S_IFDIR   0x4000

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
// engine's executor_globals (lib/php_ext.mc § engine values). RTLD_DEFAULT is
// (void *)0 here.
extern uptr dlsym(i64 h, uptr name);
uptr php_dlsym(uptr name) { return dlsym(0, name); }

// C's errno for the calling thread, which `#[Extern('c')] function errno(): int`
// reads (src/extern.mc): the macro is __errno_location() here
extern uptr __errno_location();
i64 php_c_errno() { return ld32(__errno_location()); }

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
// Sleeping on a word (lib/php_rt.mc § native sync): ph_os_wait sleeps while
// the low 32 bits at `a` equal `v` (a spurious return is the caller's to
// retry), ph_os_wake wakes one sleeper, or all of them. futex(2), private to
// the process: FUTEX_WAIT_PRIVATE 128, FUTEX_WAKE_PRIVATE 129. The syscall's
// number is the architecture's (lib/rt_host_linux_*.mc, ph_sys_futex).
extern i64 syscall(i64 n, uptr a, i64 op, i64 v, uptr ts, uptr a2, i64 v3);
void ph_os_wait(uptr a, i64 v) { syscall(ph_sys_futex(), a, 128, v, 0, 0, 0); }
void ph_os_wake(uptr a, i64 all) {
    i64 n = 1;
    if (all) n = 0x7fffffff;
    syscall(ph_sys_futex(), a, 129, n, 0, 0, 0);
}
// a timed sleep on a word (lib/php_rt.mc § the blocking objects): sleep while
// the low 32 bits at `a` equal `v`, at most `ms` milliseconds (ms < 0: for
// ever). FUTEX_WAIT's timeout is a relative timespec against CLOCK_MONOTONIC,
// which is what ph_os_now_ms reads, so a spurious wake recomputes the
// remainder correctly. CLOCK_MONOTONIC is 1.
extern i64 clock_gettime(i64 clk, uptr ts);
i64 ph_os_now_ms() { u8 ts[16]; clock_gettime(1, ts); return ld64(ts) * 1000 + ld64(ts + 8) / 1000000; }
void ph_os_wait_ms(uptr a, i64 v, i64 ms) {
    if (ms < 0) { syscall(ph_sys_futex(), a, 128, v, 0, 0, 0); return; }
    u8 ts[16];
    st64(ts, ms / 1000);
    st64(ts + 8, (ms % 1000) * 1000000);
    syscall(ph_sys_futex(), a, 128, v, ts, 0, 0);
}
i64 ph_tkey;
uptr ph_tget() { return pthread_getspecific(ph_tkey); }
void ph_tset(uptr b) { pthread_setspecific(ph_tkey, b); }
void ph_tinit() {
    u8 k[8];
    st64(k, 0);
    pthread_key_create(k, 0);
    ph_tkey = ld64(k);
}
// the logical CPUs online (mcphp_hardware_concurrency): sysconf(_SC_NPROCESSORS_ONLN)
i64 ph_os_ncpu() { i64 n = sysconf(84) & 0xffffffff; if (n < 1) return 1; return n; }
// fresh zeroed pages (MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE: a thread's
// arena is reserved, not committed), 0 when the kernel says no
uptr ph_os_map(i64 n) {
    uptr p = mmap(0, n, 3, 0x4022, 0 - 1, 0);
    if (p + 1 == 0) return 0;
    return p;
}
void ph_os_unmap(uptr p, i64 n) { munmap(p, n); }
// the size of a thread's arena: reserved (MAP_NORESERVE): pages are touched as used
i64 ph_os_arena() { return 268435456; }
// the process's virtual size in bytes, -1 when it cannot be read: the first
// field of /proc/self/statm, in pages (mcphp_vm(), a test gate)
extern i64 sysconf(i64 name);
i64 ph_os_vm() {
    u8 b[128];
    i64 fd = open("/proc/self/statm", 0, 0) & 0xffffffff;
    if (fd == 0xffffffff) return 0 - 1;
    i64 n = read(fd, b, 127);
    close(fd);
    i64 v = 0;
    i64 i = 0;
    loop {
        if (i >= n) break;
        i64 c = ld8(b + i);
        if (c < 48 || c > 57) break;
        v = v * 10 + c - 48;
        i = i + 1;
    }
    if (i == 0) return 0 - 1;
    return v * sysconf(30);                                  // _SC_PAGESIZE
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

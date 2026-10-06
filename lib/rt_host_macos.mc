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
// Sleeping on a word (lib/php_rt.mc § native sync): ph_os_wait sleeps while
// the low 32 bits at `a` equal `v` (a spurious return is the caller's to
// retry), ph_os_wake wakes one sleeper, or all of them. __ulock_wait and
// __ulock_wake are libSystem's private interface -- the one libc++'s
// std::atomic::wait is built on, so it does not go away quietly:
// UL_COMPARE_AND_WAIT 1 | ULF_NO_ERRNO 0x01000000, ULF_WAKE_ALL 0x100, and a
// timeout of 0 is none.
// ponytail: private SPI; os_sync_wait_on_address/os_sync_wake_by_address_*
// (public since macOS 14.4) are the upgrade once the floor is 14.4.
extern i64 __ulock_wait(i64 op, uptr a, i64 v, i64 us);
extern i64 __ulock_wake(i64 op, uptr a, i64 wv);
void ph_os_wait(uptr a, i64 v) { __ulock_wait(0x01000001, a, v, 0); }
void ph_os_wake(uptr a, i64 all) {
    i64 op = 0x01000001;
    if (all) op = op | 0x100;
    __ulock_wake(op, a, 0);
}
// a timed sleep on a word (lib/php_rt.mc § the blocking objects): __ulock_wait
// takes a relative timeout in microseconds (0 = for ever), so ms < 0 passes 0
// and the caller never passes 0 (its deadline check returns first).
// clock_gettime_nsec_np is libSystem's; CLOCK_MONOTONIC is 6.
extern u64 clock_gettime_nsec_np(i64 clk);
i64 ph_os_now_ms() { return clock_gettime_nsec_np(6) / 1000000; }
void ph_os_wait_ms(uptr a, i64 v, i64 ms) {
    if (ms < 0) { __ulock_wait(0x01000001, a, v, 0); return; }
    if (ms == 0) return;
    __ulock_wait(0x01000001, a, v, ms * 1000);
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
extern i64 sysconf(i64 name);
i64 ph_os_ncpu() { i64 n = sysconf(58) & 0xffffffff; if (n < 1) return 1; return n; }
// fresh zeroed pages (MAP_PRIVATE | MAP_ANON), 0 when the kernel says no
uptr ph_os_map(i64 n) {
    uptr p = mmap(0, n, 3, 0x1002, 0 - 1, 0);
    if (p + 1 == 0) return 0;
    return p;
}
void ph_os_unmap(uptr p, i64 n) { munmap(p, n); }

// --- the event loop's fiber stacks and reactor (docs/threads.md § Step 5) ---
// A fiber's stack: n bytes, the lowest page PROT_NONE so a stack overflow
// (the stack grows down) faults instead of corrupting the page below. Lazily
// committed: MAP_NORESERVE, pages touched as used. 0 when the kernel says no.
// The page is 16 KiB on Apple Silicon; mprotect one page is enough.
extern i64 mprotect(uptr addr, i64 n, i64 prot);
uptr ph_os_map_stack(i64 n) {
    uptr p = mmap(0, n, 3, 0x1002, 0 - 1, 0);          // RW, PRIVATE|ANON
    if (p + 1 == 0) return 0;
    mprotect(p, 16384, 0);                             // PROT_NONE guard page
    return p;
}

// kqueue is the macOS reactor. ph_ev_arm registers a one-shot readable
// interest with udata = ud (the future to resume); the loop does the read on
// readiness (ph_ev_wait returns nbytes = -1, the reactor-emulation sentinel).
// struct kevent: ident 0, filter(i16) 8, flags(u16) 10, fflags 12, data 16,
// udata 24 -- 32 bytes. EVFILT_READ -1, EV_ADD 1 | EV_ONESHOT 0x10.
extern i64 kqueue();
extern i64 kevent(i64 kq, uptr cl, i64 nc, uptr el, i64 ne, uptr ts);
uptr ph_ev_create() { i64 k = kqueue(); if (k < 0) return 0; return k; }
i64 ph_ev_arm(uptr ev, i64 fd, uptr ud, uptr buf, i64 len) {
    u8 ke[32];
    i64 i = 0; loop { if (i >= 32) break; st8(ke + i, 0); i = i + 1; }
    st64(ke, fd);                                      // ident
    st16(ke + 8, 0xFFFF);                              // filter = EVFILT_READ (-1)
    st16(ke + 10, 0x0011);                             // EV_ADD | EV_ONESHOT
    st64(ke + 24, ud);                                 // udata
    if (kevent(ev, ke, 1, 0, 0, 0) < 0) return 1;
    return 0;
}
// ph_ev_wait: up to `max` ready events into `out` as (ud, nbytes) 16-byte
// pairs. ms < 0 blocks for ever, ms >= 0 waits that long. nbytes is -1 so the
// loop core reads the fd itself (the completion-shaped surface's POSIX half).
i64 ph_ev_wait(uptr ev, uptr out, i64 max, i64 ms) {
    if (max > 64) max = 64;
    u8 el[2048];                                       // 64 * 32
    u8 ts[16];
    uptr tsp = 0;
    if (ms >= 0) { st64(ts, ms / 1000); st64(ts + 8, (ms % 1000) * 1000000); tsp = ts; }
    i64 n = kevent(ev, 0, 0, el, max, tsp);
    if (n < 0) n = 0;
    i64 i = 0;
    loop {
        if (i >= n) break;
        st64(out + i * 16, ld64(el + i * 32 + 24));    // udata
        st64(out + i * 16 + 8, 0 - 1);                 // nbytes = -1: loop reads
        i = i + 1;
    }
    return n;
}
// close the kqueue fd when its loop is torn down (docs/threads.md § Step 5)
void ph_ev_close(uptr ev) { close(ev); }
// kqueue holds no user buffer across the wait (the loop does the read itself), so
// there is nothing the kernel can write after teardown: cancel/drain are no-ops.
void ph_ev_cancel(uptr ev, i64 fd) {}
void ph_ev_drain(uptr ev, i64 n) {}
// read a ready fd for the loop's reactor emulation: retry EINTR (4), signal -2
// on EAGAIN (35 on macOS: readiness was spurious, re-arm), -1 on any other
// error (a real failure, not a false EOF).
i64 ph_io_read_ready(i64 fd, uptr buf, i64 len) {
    loop {
        i64 n = read(fd, buf, len);
        if (n >= 0) return n;
        i64 e = php_c_errno();
        if (e == 4) continue;
        if (e == 35) return 0 - 2;
        return 0 - 1;
    }
}

// Test scaffolding (docs/threads.md § Step 5, the self-test): a pipe whose
// read end is non-blocking. NOT part of the step-5 surface -- users await
// file://sockets in 6b; the self-test needs a bare fd to await. [r, w] into
// out2 (two i64). fcntl F_SETFL 4, O_NONBLOCK 4 on macOS.
extern i64 pipe(uptr fds);
extern i64 fcntl(i64 fd, i64 cmd, i64 arg);
i64 ph_os_pipe(uptr out2) {
    u8 fds[8];
    if (pipe(fds) != 0) return 1;
    i64 r = ld32(fds) & 0xffffffff;
    i64 w = ld32(fds + 4) & 0xffffffff;
    fcntl(r, 4, 4);                                    // F_SETFL O_NONBLOCK
    st64(out2, r);
    st64(out2 + 8, w);
    return 0;
}

// --- cross-thread loop wake (docs/threads.md § Step 6b) ---------------------
// A self-pipe the loop arms PERSISTENTLY (EV_ADD without EV_ONESHOT) with
// udata = the loop's marker, so a worker on another thread can interrupt this
// loop's ph_ev_wait by writing one byte after it enqueued a completion. The
// handle is (read_fd << 32 | write_fd); 0 when the pipe cannot be made.
uptr ph_ev_wake_create(uptr ev, uptr marker) {
    u8 fds[16];
    if (ph_os_pipe(fds) != 0) return 0;
    i64 r = ld64(fds);
    i64 w = ld64(fds + 8);
    u8 ke[32];
    i64 i = 0; loop { if (i >= 32) break; st8(ke + i, 0); i = i + 1; }
    st64(ke, r);                                       // ident
    st16(ke + 8, 0xFFFF);                              // EVFILT_READ (-1)
    st16(ke + 10, 0x0001);                             // EV_ADD only: stays armed across waits
    st64(ke + 24, marker);                             // udata = the loop marker
    if (kevent(ev, ke, 1, 0, 0, 0) < 0) { close(r); close(w); return 0; }
    return (r << 32) | (w & 0xffffffff);
}
// post a wake from another thread: one byte on the write end (atomic)
void ph_ev_wake_post(uptr ev, uptr handle) {
    u8 one[1]; st8(one, 1);
    write(handle & 0xffffffff, one, 1);
}
// drain the pending wake bytes with ONE read: kqueue only reports the read end
// when it is readable, so this never blocks, and any bytes past the buffer
// re-fire the level interest and drain on the next turn. (A loop of reads would
// block on a second, empty read if the fd were not non-blocking.)
void ph_ev_wake_drain(uptr handle) {
    u8 buf[256];
    read(handle >> 32, buf, 256);
}
void ph_ev_wake_close(uptr ev, uptr handle) {
    close(handle >> 32);
    close(handle & 0xffffffff);
}

// --- non-blocking TCP, driven by the loop (docs/threads.md § Step 6b) --------
// A connect is submitted non-blocking and completed by the loop when the socket
// becomes WRITABLE (then SO_ERROR says connected or why not). A read reuses the
// readable arm-and-go of ph_ev_arm. The server side a self-test needs is one
// blocking accept on another thread. macOS: AF_INET 2, SOCK_STREAM 1,
// EINPROGRESS 36, SOL_SOCKET 0xffff, SO_ERROR 0x1007, SO_REUSEADDR 4,
// EVFILT_WRITE -2.
extern i64 socket(i64 dom, i64 type, i64 proto);
extern i64 connect(i64 fd, uptr addr, i64 len);
extern i64 bind(i64 fd, uptr addr, i64 len);
extern i64 listen(i64 fd, i64 backlog);
extern i64 accept(i64 fd, uptr addr, uptr alen);
extern i64 setsockopt(i64 fd, i64 level, i64 opt, uptr val, i64 len);
extern i64 getsockopt(i64 fd, i64 level, i64 opt, uptr val, uptr len);
extern i64 getsockname(i64 fd, uptr addr, uptr alen);
// a sockaddr_in for ip:port into sa[16]: sin_len, AF_INET, port and addr in
// network (big-endian) order
void ph_sa_in(uptr sa, i64 ip, i64 port) {
    i64 i = 0; loop { if (i >= 16) break; st8(sa + i, 0); i = i + 1; }
    st8(sa, 16);                                       // sin_len (macOS)
    st8(sa + 1, 2);                                    // AF_INET
    st8(sa + 2, (port >> 8) & 0xff); st8(sa + 3, port & 0xff);
    st8(sa + 4, (ip >> 24) & 0xff);  st8(sa + 5, (ip >> 16) & 0xff);
    st8(sa + 6, (ip >> 8) & 0xff);   st8(sa + 7, ip & 0xff);
}
// a non-blocking socket connecting to ip:port; the fd (>= 0) with the connect
// in progress (or already done), -1 on a hard failure
i64 ph_os_connect(i64 ip, i64 port) {
    i64 fd = socket(2, 1, 0);
    if (fd < 0) return 0 - 1;
    fcntl(fd, 4, 4);                                   // O_NONBLOCK
    u8 sa[16]; ph_sa_in(sa, ip, port);
    if (connect(fd, sa, 16) == 0) return fd;           // loopback can connect at once
    if (php_c_errno() == 36) return fd;                // EINPROGRESS
    close(fd); return 0 - 1;
}
// the pending socket error once a connect's socket is writable: 0 = connected
i64 ph_os_sockerr(i64 fd) {
    u8 e[8]; u8 l[8]; st64(e, 0); st64(l, 4);
    getsockopt(fd, 0xffff, 0x1007, e, l);              // SOL_SOCKET, SO_ERROR
    return ld32(e) & 0xffffffff;
}
// arm a one-shot WRITABLE interest (a connect completion). EVFILT_WRITE = -2.
i64 ph_ev_arm_w(uptr ev, i64 fd, uptr ud) {
    u8 ke[32];
    i64 i = 0; loop { if (i >= 32) break; st8(ke + i, 0); i = i + 1; }
    st64(ke, fd);
    st16(ke + 8, 0xFFFE);                              // EVFILT_WRITE (-2)
    st16(ke + 10, 0x0011);                             // EV_ADD | EV_ONESHOT
    st64(ke + 24, ud);
    if (kevent(ev, ke, 1, 0, 0, 0) < 0) return 1;
    return 0;
}
// a connect's socket is already associated to the port on Windows (IOCP); on
// POSIX this is the writable arm-and-go. Keeps the loop core backend-neutral.
i64 ph_ev_arm_connect(uptr ev, i64 fd, uptr ud, i64 ip, i64 port) { return ph_ev_arm_w(ev, fd, ud); }
// Test scaffolding: a blocking loopback listener on 127.0.0.1:port (0 =
// ephemeral); (listen_fd << 32 | the port actually bound), -1 on failure.
i64 ph_os_listen(i64 port) {
    i64 fd = socket(2, 1, 0);
    if (fd < 0) return 0 - 1;
    u8 one[4]; st32(one, 1);
    setsockopt(fd, 0xffff, 4, one, 4);                 // SO_REUSEADDR
    u8 sa[16]; ph_sa_in(sa, 0x7f000001, port);
    if (bind(fd, sa, 16) != 0) { close(fd); return 0 - 1; }
    if (listen(fd, 16) != 0) { close(fd); return 0 - 1; }
    u8 na[16]; u8 nl[8]; st64(nl, 16);
    getsockname(fd, na, nl);
    i64 ap = ((ld8(na + 2) & 0xff) << 8) | (ld8(na + 3) & 0xff);
    return (fd << 32) | (ap & 0xffffffff);
}
// Test scaffolding: accept ONE connection (blocking), write buf, close it.
i64 ph_os_accept_send(i64 lfd, uptr buf, i64 len) {
    i64 c = accept(lfd, 0, 0);
    if (c < 0) return 0 - 1;
    write(c, buf, len);
    close(c);
    return 0;
}

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

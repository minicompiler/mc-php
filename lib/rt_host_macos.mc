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

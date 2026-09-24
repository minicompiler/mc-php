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

// php's path separator test and php's setlocale, per host, because php's own
// differ per host: on Windows a backslash separates too (IS_SLASH in
// php-src), and setlocale refuses a name shaped like "xx_YY" before the C
// library sees it (ext/standard/string.c, a BC rule). Here both are the plain
// answer.
i64 php_is_sep(i64 c) { return c == '/'; }
uptr php_setlocale(i64 cat, uptr name) { return setlocale(cat, name); }

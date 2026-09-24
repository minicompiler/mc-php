// rt_host_windows.mc -- the Windows half of the RUNTIME's system layer,
// shared by both architectures. See lib/rt_host_macos.mc for what a runtime
// host layer is and who pushes one.
//
// The difference from the macOS and Linux layers is where the names COME FROM.
// There, every one below is in the C library under that name and this file only
// declares it. Windows has no C library a program is entitled to -- the
// documented boundary is kernel32.dll, which has no POSIX interface -- so the
// names the runtime calls are DEFINED here, over kernel32, the way mc's own
// lib/sys_windows.mc defines `write` and `open`. They are copied rather than
// included for the reason lib/rt_host_macos.mc gives about `<sys>`: a runtime
// that names a library needs mc's library tree beside every mc-php, and this
// one needs nothing.
//
// Two things are NOT kernel32's and come from ucrtbase.dll, the C runtime every
// Windows 10 and later carries in System32: setlocale(3), whose answer has to
// be the same C library php's answer comes from (php8.dll links the same
// runtime), and the libm names lib/php_rt.mc declares (sin, cos, ...). The
// `#dylib` at the bottom of this file is what makes them imports of that DLL on
// the one-step --exe road; on the object road the import library
// tests/winsys.sh builds says the same thing.
//
// No descriptors, handles: `open` hands back the HANDLE CreateFileA returned
// and every other call takes it back unchanged. 0, 1 and 2 are translated
// through GetStdHandle, which is safe because a real handle is never one of
// those three values (mc's lib/sys_windows.mc makes the same argument).
//
// The entry point is NOT here: lib/rt_host_windows_start.mc names `main`, and
// an extension has no `main` (src/program.mc pushes that file on the program
// road only).

extern uptr GetStdHandle(i64 nStdHandle);
extern i64  WriteFile(uptr h, uptr buf, i64 n, uptr written, uptr overlapped);
extern i64  ReadFile(uptr h, uptr buf, i64 n, uptr got, uptr overlapped);
extern uptr CreateFileA(uptr name, i64 access, i64 share, uptr sa,
                        i64 disposition, i64 flags, uptr tmpl);
extern i64  CloseHandle(uptr h);
extern void ExitProcess(i64 code);
extern uptr GetCommandLineA();
extern i64  SetFilePointerEx(uptr h, i64 dist, uptr newpos, i64 method);
extern i64  GetFileAttributesA(uptr name);
extern i64  GetFileAttributesExA(uptr name, i64 level, uptr info);
extern i64  SetFileAttributesA(uptr name, i64 attrs);
extern i64  GetEnvironmentVariableA(uptr name, uptr buf, i64 size);
extern i64  SetEnvironmentVariableA(uptr name, uptr value);
extern i64  DeleteFileA(uptr name);
extern i64  MoveFileExA(uptr from, uptr to, i64 flags);
extern i64  CreateDirectoryA(uptr name, uptr sa);
extern i64  RemoveDirectoryA(uptr name);
extern i64  GetCurrentProcessId();
extern i64  GetCurrentDirectoryA(i64 size, uptr buf);
extern i64  SetCurrentDirectoryA(uptr name);
extern i64  GetLastError();
extern void SetLastError(i64 code);

// The flags the runtime writes and only this file reads. They are the
// Microsoft C runtime's values (_O_*, and O_CREAT is mc's lib/sys_windows.mc
// value too), so a reader who knows fcntl.h on Windows recognises them.
#define O_RDONLY  0
#define O_WRONLY  1
#define O_RDWR    2
#define O_APPEND  8
#define O_CREAT   0x100
#define O_TRUNC   0x200
#define O_EXCL    0x400
#define S_IFMT    0xf000
#define S_IFREG   0x8000
#define S_IFDIR   0x4000

#define RTW_GENERIC_READ   0x80000000
#define RTW_GENERIC_WRITE  0x40000000
// GENERIC_WRITE without FILE_WRITE_DATA: a handle that may only APPEND, which
// is what POSIX O_APPEND means -- every write lands at the end, whatever the
// file pointer says.
#define RTW_APPEND_ONLY    0x120114
#define RTW_SHARE_ALL      7              // read | write | delete: unlink of an open file works
#define RTW_CREATE_NEW     1
#define RTW_CREATE_ALWAYS  2
#define RTW_OPEN_EXISTING  3
#define RTW_OPEN_ALWAYS    4
#define RTW_TRUNCATE_EXIST 5
#define RTW_ATTR_NORMAL    0x80
#define RTW_ATTR_READONLY  1
#define RTW_ATTR_DIRECTORY 0x10
#define RTW_INVALID        0xffffffff    // INVALID_FILE_ATTRIBUTES, read through c_int
#define RTW_BROKEN_PIPE    109
#define RTW_ENV_NOT_FOUND  203
// A BOOL is a 32-bit int, so the high half of every result below is not
// specified (mc's M45); every truth test masks it.
#define RTW_BOOL           0xffffffff

// mc's c_int(), which is <mc/core>'s and not in a program: the low 32 bits of
// a C `int` result, sign-extended.
i64 rtw_int(i64 v) {
    v = v & 0xffffffff;
    if (v & 0x80000000) return v - 0x100000000;
    return v;
}

u8 rtw_nio[8];                           // the DWORD out-parameter of Read/WriteFile

uptr rtw_handle(i64 fd) {
    if (fd == 0) return GetStdHandle(0 - 10);
    if (fd == 1) return GetStdHandle(0 - 11);
    if (fd == 2) return GetStdHandle(0 - 12);
    return fd;
}

i64 write(i64 fd, uptr buf, i64 n) {
    st64(rtw_nio, 0);
    if ((WriteFile(rtw_handle(fd), buf, n, rtw_nio, 0) & RTW_BOOL) == 0) return 0 - 1;
    return ld32(rtw_nio);
}

// A pipe whose writer has gone answers ERROR_BROKEN_PIPE where a POSIX read
// answers 0, end of file -- which is what the runtime's reader loops test for.
i64 read(i64 fd, uptr buf, i64 n) {
    st64(rtw_nio, 0);
    if ((ReadFile(rtw_handle(fd), buf, n, rtw_nio, 0) & RTW_BOOL) == 0) {
        if (rtw_int(GetLastError()) == RTW_BROKEN_PIPE) return 0;
        return 0 - 1;
    }
    return ld32(rtw_nio);
}

i64 open(uptr path, i64 flags, i64 mode) {
    i64 rw = flags & 3;
    i64 acc = RTW_GENERIC_READ;
    if (rw == O_WRONLY) acc = RTW_GENERIC_WRITE;
    if (rw == O_RDWR) acc = RTW_GENERIC_READ | RTW_GENERIC_WRITE;
    if (flags & O_APPEND) {
        acc = RTW_APPEND_ONLY;
        if (rw == O_RDWR) acc = RTW_APPEND_ONLY | RTW_GENERIC_READ;
    }
    i64 disp = RTW_OPEN_EXISTING;
    if (flags & O_CREAT) {
        disp = RTW_OPEN_ALWAYS;
        if (flags & O_TRUNC) disp = RTW_CREATE_ALWAYS;
        if (flags & O_EXCL) disp = RTW_CREATE_NEW;
    } else {
        if (flags & O_TRUNC) disp = RTW_TRUNCATE_EXIST;
    }
    uptr h = CreateFileA(path, acc, RTW_SHARE_ALL, 0, disp, RTW_ATTR_NORMAL, 0);
    if (h == 0 - 1) return 0 - 1;
    return h;
}

i64 creat(uptr path, i64 mode) {
    return open(path, O_WRONLY | O_CREAT | O_TRUNC, mode);
}

// A negative descriptor is refused and never reaches CloseHandle: -1 is also
// the pseudo-handle of the current process, and closing THAT succeeds (mc's
// lib/sys_windows.mc, found by its own Windows legs).
i64 close(i64 fd) {
    if (fd < 0) return 0 - 1;
    if (fd <= 2) return 0;
    if ((CloseHandle(fd) & RTW_BOOL) == 0) return 0 - 1;
    return 0;
}

void exit(i64 code) {
    ExitProcess(code);
}

// FILE_BEGIN, FILE_CURRENT and FILE_END are SEEK_SET, SEEK_CUR and SEEK_END's
// numbers, so `whence` passes through.
i64 lseek(i64 fd, i64 off, i64 whence) {
    u8 np[8];
    st64(np, 0);
    if ((SetFilePointerEx(rtw_handle(fd), off, np, whence) & RTW_BOOL) == 0) return 0 - 1;
    return ld64(np);
}

i64 rtw_attrs(uptr path) {
    i64 a = rtw_int(GetFileAttributesA(path));
    if (a == 0 - 1) return 0 - 1;
    return a & RTW_INVALID;
}

// What the Microsoft C runtime's _stat answers for the execute bit, and so
// what php on Windows answers: a directory, or a name ending in one of the
// four extensions the command interpreter runs.
i64 rtw_exec_name(uptr p) {
    i64 n = 0;
    loop { if (!ld8(p + n)) break; n = n + 1; }
    if (n < 4) return 0;
    if (ld8(p + n - 4) != '.') return 0;
    i64 a = ld8(p + n - 3) | 32;
    i64 b = ld8(p + n - 2) | 32;
    i64 c = ld8(p + n - 1) | 32;
    if (a == 'e' && b == 'x' && c == 'e') return 1;
    if (a == 'c' && b == 'o' && c == 'm') return 1;
    if (a == 'b' && b == 'a' && c == 't') return 1;
    if (a == 'c' && b == 'm' && c == 'd') return 1;
    return 0;
}

// access(2): F_OK 0, X_OK 1, W_OK 2, R_OK 4. Everything that exists is
// readable; a READONLY file is not writable; the execute bit is _stat's.
i64 access(uptr path, i64 mode) {
    i64 a = rtw_attrs(path);
    if (a < 0) return 0 - 1;
    if (mode & 2) {
        if ((a & RTW_ATTR_READONLY) && !(a & RTW_ATTR_DIRECTORY)) return 0 - 1;
    }
    if (mode & 1) {
        if (!(a & RTW_ATTR_DIRECTORY) && !rtw_exec_name(path)) return 0 - 1;
    }
    return 0;
}

// php_stat_mode and php_stat_size are the two readers lib/php_rt.mc calls,
// and on Windows they read WIN32_FILE_ATTRIBUTE_DATA rather than a struct
// stat: dwFileAttributes at 0, nFileSizeHigh at 28, nFileSizeLow at 32. The
// mode is built the way the Microsoft C runtime's _stat builds it.
i64 php_stat_mode(uptr p) {
    u8 fa[40];
    if ((GetFileAttributesExA(p, 0, fa) & RTW_BOOL) == 0) return 0 - 1;
    i64 a = ld32(fa);
    i64 m = S_IFREG | 292;                            // 0444
    if (a & RTW_ATTR_DIRECTORY) m = S_IFDIR | 292 | 73;   // + 0111
    if (!(a & RTW_ATTR_DIRECTORY)) { if (rtw_exec_name(p)) m = m | 73; }
    if (!(a & RTW_ATTR_READONLY)) m = m | 146;        // 0222
    return m;
}

i64 php_stat_size(uptr p) {
    u8 fa[40];
    if ((GetFileAttributesExA(p, 0, fa) & RTW_BOOL) == 0) return 0 - 1;
    if (ld32(fa) & RTW_ATTR_DIRECTORY) return 0;
    return (ld32(fa + 28) << 32) | ld32(fa + 32);
}

// The environment is the PROCESS's, read and written through kernel32, so a
// program this compiler writes and a child it starts see the same one. The
// answer lives in the runtime's arena (D7, never freed), which is what lets
// two getenv() results be alive at once.
uptr getenv(uptr name) {
    SetLastError(0);
    i64 n = rtw_int(GetEnvironmentVariableA(name, 0, 0));
    if (n == 0) {
        if (rtw_int(GetLastError()) == RTW_ENV_NOT_FOUND) return 0;
        uptr e = php_alloc(1);
        st8(e, 0);
        return e;
    }
    uptr b = php_alloc(n + 1);
    i64 m = rtw_int(GetEnvironmentVariableA(name, b, n + 1));
    if (m <= 0 || m > n) return 0;
    st8(b + m, 0);
    return b;
}

// "K=V": SetEnvironmentVariableA takes the two halves apart.
i64 putenv(uptr kv) {
    i64 i = 0;
    loop { if (!ld8(kv + i)) return 0 - 1; if (ld8(kv + i) == 61) break; i = i + 1; }
    uptr k = php_alloc(i + 1);
    i64 j = 0;
    loop { if (j >= i) break; st8(k + j, ld8(kv + j)); j = j + 1; }
    st8(k + i, 0);
    if ((SetEnvironmentVariableA(k, kv + i + 1) & RTW_BOOL) == 0) return 0 - 1;
    return 0;
}

i64 unsetenv(uptr name) {
    SetEnvironmentVariableA(name, 0);
    return 0;
}

i64 unlink(uptr path) { if ((DeleteFileA(path) & RTW_BOOL) == 0) return 0 - 1; return 0; }

// php's rename replaces an existing target on Windows too; MOVEFILE_COPY_ALLOWED
// is what lets it cross volumes, as rename(2) does not but php's does.
i64 rename(uptr from, uptr to) {
    if ((MoveFileExA(from, to, 3) & RTW_BOOL) == 0) return 0 - 1;
    return 0;
}

i64 mkdir(uptr path, i64 mode) { if ((CreateDirectoryA(path, 0) & RTW_BOOL) == 0) return 0 - 1; return 0; }
i64 rmdir(uptr path) { if ((RemoveDirectoryA(path) & RTW_BOOL) == 0) return 0 - 1; return 0; }
i64 getpid() { return rtw_int(GetCurrentProcessId()) & RTW_INVALID; }

uptr getcwd(uptr buf, i64 n) {
    i64 m = rtw_int(GetCurrentDirectoryA(n, buf));
    if (m <= 0 || m >= n) return 0;
    return buf;
}

i64 chdir(uptr path) { if ((SetCurrentDirectoryA(path) & RTW_BOOL) == 0) return 0 - 1; return 0; }

// NTFS has no mode bits. What the Microsoft C runtime's _chmod does -- and
// therefore what php's chmod does on Windows -- is the one bit it can map:
// without _S_IWRITE (0200) the file becomes READONLY, with it it stops being.
i64 chmod(uptr path, i64 mode) {
    i64 a = rtw_attrs(path);
    if (a < 0) return 0 - 1;
    if (mode & 128) a = a & (RTW_INVALID - RTW_ATTR_READONLY);
    else a = a | RTW_ATTR_READONLY;
    if ((SetFileAttributesA(path, a) & RTW_BOOL) == 0) return 0 - 1;
    return 0;
}

// From here on every `extern` -- the one below and the libm names
// lib/php_rt.mc declares after this file -- is an import of ucrtbase.dll on
// the one-step road. `#dylib` stays in effect across the pushed sources, which
// is the point: it is set once, here, and the runtime is not edited per host.
#dylib "ucrtbase.dll"
extern uptr setlocale(i64 category, uptr name);

// php's separator test on Windows: IS_SLASH is '/' or '\' (php-src
// Zend/zend_virtual_cwd.h), so basename() and dirname() split on both.
i64 php_is_sep(i64 c) { return c == '/' || c == 92; }

// DEFAULT_SLASH: the root dirname() writes, whichever separator the path used.
i64 php_dir_sep() { return 92; }

// php_basename's _is_basename_start (ext/standard/string.c): is the ':' at
// `pos` a drive's, one letter after the start of a name? Then basename() cuts
// there, so basename("C:foo") is "foo" and basename("C:") is "C".
i64 php_base_colon(uptr s, i64 pos) {
    if (pos < 1) return 0;
    if (php_is_sep(ld8(s + pos - 1))) return 0;
    if (pos == 1) return 1;
    i64 c = ld8(s + pos - 2);
    if (php_is_sep(c)) return 1;
    if (c == ':') return php_base_colon(s, pos - 2);
    return 0;
}

// "C:" -- zend_dirname keeps a drive spec as it is and dirnames the rest.
i64 php_drive_len(uptr p, i64 n) {
    if (n < 2) return 0;
    if (ld8(p + 1) != ':') return 0;
    i64 c = ld8(p) | 32;
    if (c >= 'a' && c <= 'z') return 2;
    return 0;
}

// php's setlocale on Windows (ext/standard/string.c): for backward
// compatibility a name shaped /^[a-z]{2}_[A-Z]{2}($|\..*)/ is refused before
// the C runtime sees it -- the C runtime would accept "zz_ZZ" -- except
// uk_UA/us_US's /^u[ks]_U[KS]$/. Measured on windows/x86_64:
// setlocale(LC_ALL, ["zz_ZZ", "C"]) is "C" under php and was "zz_ZZ" before
// this rule was here.
uptr php_setlocale(i64 cat, uptr p) {
    if (!p) return setlocale(cat, 0);
    i64 a = ld8(p);
    i64 b = 0; if (a) b = ld8(p + 1);
    i64 u = 0; if (b) u = ld8(p + 2);
    i64 c = 0; if (u) c = ld8(p + 3);
    i64 d = 0; if (c) d = ld8(p + 4);
    i64 e = 0; if (d) e = ld8(p + 5);
    if (u == '_' && a >= 'a' && a <= 'z' && b >= 'a' && b <= 'z'
        && c >= 'A' && c <= 'Z' && d >= 'A' && d <= 'Z' && (e == 0 || e == '.')) {
        if (!(a == 'u' && (b == 'k' || b == 's') && c == 'U' && (d == 'K' || d == 'S') && e == 0))
            return 0;
    }
    return setlocale(cat, p);
}

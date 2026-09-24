// host_extra_windows.mc -- what this compiler needs from a Windows host that
// mc's own Windows host layer does not declare: realpath(3), which
// src/stmt.mc calls once per source file (src/host_extra_linux.mc says why it
// is per entry and not in src/).
//
// Windows has no realpath. GetFullPathNameA is the part that makes a path
// absolute and removes `.` and `..`, and it answers with BACKSLASHES -- which
// is what php on Windows prints in "in FILE on line N" -- and
// GetFileAttributesA is the part that says the file exists, which realpath(3)
// also requires. Symlinks are not resolved; php on Windows does not print a
// resolved junction either for an ordinary script path.
extern i64 GetFullPathNameA(uptr name, i64 size, uptr buf, uptr filepart);
extern i64 GetFileAttributesA(uptr name);

uptr realpath(uptr path, uptr resolved) {
    i64 n = c_int(GetFullPathNameA(path, 4096, resolved, 0));
    if (n <= 0 || n >= 4096) return 0;
    if (c_int(GetFileAttributesA(resolved)) == 0 - 1) return 0;   // INVALID_FILE_ATTRIBUTES
    return resolved;
}

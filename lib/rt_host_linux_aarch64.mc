// rt_host_linux_aarch64.mc -- the ARCHITECTURE half of the Linux runtime host
// layer. The operating-system half is lib/rt_host_linux.mc, which declares
// stat() and everything else; this file is only the two answers that depend on
// the architecture, and they are both `struct stat`'s.
//
// linux/arch/arm64: st_dev 0, st_ino 8, st_mode 16 (u32), st_nlink 20,
// st_uid 24, st_gid 28, st_rdev 32, __pad1 40, st_size 48 (i64).
// The offsets are NOT x86-64's -- st_mode is at 24 there, because that
// architecture puts st_nlink before it. Getting this wrong reads st_ino's high
// half as a mode and answers `is_dir` at random, which is why it is a file of
// its own and not a number in a comment.
i64 php_stat_mode(uptr p) {
    u8 sb[160];
    if (stat(p, sb) != 0) return 0 - 1;
    return ld32(sb + 16);
}

i64 php_stat_size(uptr p) {
    u8 sb[160];
    if (stat(p, sb) != 0) return 0 - 1;
    return ld64(sb + 48);
}

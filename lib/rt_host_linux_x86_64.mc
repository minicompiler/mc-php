// rt_host_linux_x86_64.mc -- the ARCHITECTURE half of the Linux runtime host
// layer. The operating-system half is lib/rt_host_linux.mc, which declares
// stat() and everything else; this file is only the two answers that depend on
// the architecture, and they are both `struct stat`'s.
//
// linux/arch/x86: st_dev 0, st_ino 8, st_nlink 16, st_mode 24 (u32),
// st_uid 28, st_gid 32, __pad0 36, st_rdev 40, st_size 48 (i64).
// The offsets are NOT aarch64's -- st_mode is at 16 there, because that
// architecture puts it before st_nlink. Getting this wrong reads st_nlink as a
// mode and answers `is_dir` at random, which is why it is a file of its own
// and not a number in a comment.
i64 php_stat_mode(uptr p) {
    u8 sb[160];
    if (stat(p, sb) != 0) return 0 - 1;
    return ld32(sb + 24);
}

i64 php_stat_size(uptr p) {
    u8 sb[160];
    if (stat(p, sb) != 0) return 0 - 1;
    return ld64(sb + 48);
}

// build.mc -- `mc-php build`, and mc-php's own main.
//
// mc's `build` builds ONE output from one project file. `[php]
// thread_safety = "both"` asks for two -- the extension for an NTS php and the
// same extension for a ZTS php -- so mc-php registers its own `build` over
// mc's: for any other value it is mc's, unchanged; for "both" it runs mc's
// build of the NTS output in this process (src/ext.mc reads "both" as NTS),
// then the ZTS one in a second process, from a copy of the project file with
// three lines changed:
//
//   [php]     thread_safety = "zts"
//   [project] out = the NTS output's name with "-zts" before its extension
//             (build/hello.so -> build/hello-zts.so, build/hello.dll ->
//             build/hello-zts.dll)
//   [linker]  "php8.lib" -> "php8ts.lib" where it is a whole word, and only
//             for a Windows target (a ZTS php is php8ts.dll, and the import
//             library names it); nothing else in the file is touched
//
// The copy sits beside the file it copies, so every relative path in it means
// what it meant there, under a name of this process's own --
// `.mcphp-zts-<pid>-<file>`, so two builds of one project at once never share
// one -- and it is removed when the second build ends, however it ends. What
// no code here can clean is a process killed from outside (SIGKILL) while the
// copy exists: the name's `.mcphp-zts-` prefix is how to find it, and
// .gitignore keeps it out of a commit (docs/mcphp-toml.md § php.thread_safety).
// A second process because mc's tables are built once per process: two
// compilations do not fit in one (mc's own `[compiler]` road spawns for the
// same reason). mc freezes none of drv_build, drv_spawn or mc_main: they are
// in tests/mcnames.mc, which CI compiles against the pinned mc
// (docs/mc-internals.md).
//
// `<mc/core>` is mc's parts plus a main; mc-php's entries include the parts
// and this file is the main, the same main with ph_build_init() before the
// dispatch.

uptr ph_mc_build;                   // mc's own `build`

// the name the ZTS output takes: "-zts" before the last extension of the
// file's name, or at its end when it has none
uptr ph_ts_out(uptr out) {
    i64 n = cstrlen(out);
    i64 dot = 0 - 1;
    i64 i = 0;
    loop {
        if (i >= n) break;
        if (ld8(out + i) == 47 || ld8(out + i) == 92) dot = 0 - 1;   // / or \
        if (ld8(out + i) == 46) dot = i;                               // .
        i = i + 1;
    }
    if (dot <= 0) return p_cat(out, "-zts", 0, 4);
    return p_cat(p_cat(xstrdup(out, dot), "-zts", 0, 4), out + dot, 0, n - dot);
}

// a line's table header, when the line is one: `[name]` -> "name", else 0
uptr ph_tb_head(uptr s, i64 n) {
    i64 i = 0;
    loop { if (i >= n) break; if (ld8(s + i) != 32 && ld8(s + i) != 9) break; i = i + 1; }
    if (i >= n || ld8(s + i) != 91) return 0;                        // [
    i64 j = i + 1;
    loop { if (j >= n) break; if (ld8(s + j) == 93) break; j = j + 1; }
    if (j >= n) return 0;
    return xstrdup(s + i + 1, j - i - 1);
}

// does the line `s` (length n) set `key` -- its first word, before an `=`?
i64 ph_tb_key(uptr s, i64 n, uptr key) {
    i64 i = 0;
    loop { if (i >= n) break; if (ld8(s + i) != 32 && ld8(s + i) != 9) break; i = i + 1; }
    i64 k = cstrlen(key);
    if (i + k > n || !mem_eq(s + i, key, k)) return 0;
    i = i + k;
    loop { if (i >= n) break; if (ld8(s + i) != 32 && ld8(s + i) != 9) break; i = i + 1; }
    return i < n && ld8(s + i) == 61;                                 // =
}

// a byte that can be part of a file name's word: php8.lib is swapped only
// where it is a whole word -- a path component, a quoted argument -- and
// never inside a longer name (myphp8.lib, php8.lib.bak)
i64 ph_ts_namech(i64 c) {
    return (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122)
        || c == 95 || c == 46 || c == 45;
}

// the project file with the three lines of the ZTS build (the header says
// which), line by line; the [linker] swap only for a Windows target (win)
uptr ph_ts_config_text(uptr src, i64 n, uptr out, i64 win) {
    uptr b = xalloc(BUF_SIZE);
    buf_init(b);
    uptr tb = "";
    i64 i = 0;
    loop {
        if (i >= n) break;
        i64 e = i;
        loop { if (e >= n) break; if (ld8(src + e) == 10) break; e = e + 1; }
        uptr line = src + i;
        i64 ln = e - i;
        uptr h = ph_tb_head(line, ln);
        if (h) tb = h;
        if (str_eq(tb, "php") && ph_tb_key(line, ln, "thread_safety")) {
            buf_put(b, "thread_safety = \"zts\"", 21);
        } else if (str_eq(tb, "project") && ph_tb_key(line, ln, "out")) {
            buf_put(b, "out = \"", 7);
            buf_put(b, out, cstrlen(out));
            buf_put(b, "\"", 1);
        } else if (win && str_eq(tb, "linker")) {
            i64 k = 0;
            loop {
                if (k >= ln) break;
                if (k + 8 <= ln && mem_eq(line + k, "php8.lib", 8)
                    && (k == 0 || !ph_ts_namech(ld8(line + k - 1)))
                    && (k + 8 == ln || !ph_ts_namech(ld8(line + k + 8)))) {
                    buf_put(b, "php8ts.lib", 10); k = k + 8; continue;
                }
                buf_put(b, line + k, 1);
                k = k + 1;
            }
        } else buf_put(b, line, ln);
        if (e < n) buf_put(b, "\n", 1);
        i = e + 1;
    }
    return b;
}

i64 ph_build(i64 argc, uptr argv) {
    // the directory and the file, read as mc's own build reads them
    uptr dir = 0;
    uptr cfg = 0;
    i64 ci = 0 - 1;
    i64 i = 2;
    loop {
        if (i >= argc) break;
        uptr a = ld64(argv + i * 8);
        if (str_eq(a, "--config") && i + 1 < argc) { i = i + 1; ci = i; cfg = ld64(argv + i * 8); }
        else if ((str_eq(a, "--sysroot-dir") || str_eq(a, "--libs-dir")) && i + 1 < argc) i = i + 1;
        else if (ld8(a) != 45 && dir == 0) dir = a;
        i = i + 1;
    }
    if (dir == 0) dir = ".";
    if (cfg == 0) cfg = path_norm(p_cat(dir, "/mc.toml", 0, 8));
    // not a project file mc-php can read: mc's build says what is wrong
    if (!lex_readable(cfg)) return callp(ph_mc_build, argc, argv);
    toml_parse(cfg);
    uptr ts = toml_get("php.thread_safety");
    if (!ts || !str_eq(ts, "both")) return callp(ph_mc_build, argc, argv);
    uptr out = toml_get("project.out");
    if (!out) return callp(ph_mc_build, argc, argv);          // mc names what is missing
    i64 n = 0;
    uptr src = read_file(cfg, &n);
    uptr zout = ph_ts_out(out);
    uptr os = toml_get("target.os");
    if (!os) os = host_os();                                   // mc's rule: no [target] is the host
    uptr zb = ph_ts_config_text(src, n, zout, str_eq(os, "windows"));
    // beside the original: the same directory, so the same relative paths,
    // and a name of this process's own, so two builds of one project at once
    // do not share it: .mcphp-zts-<pid>-<the file's name>
    i64 cn = cstrlen(cfg);
    i64 bs = cn;
    loop { if (bs == 0) break; if (ld8(cfg + bs - 1) == 47 || ld8(cfg + bs - 1) == 92) break; bs = bs - 1; }
    uptr pid = php_dec(ph_pid());
    uptr zn = p_cat(p_cat(".mcphp-zts-", pid, 0, cstrlen(pid)), "-", 0, 1);
    uptr zcfg = path_join(cfg, p_cat(zn, cfg + bs, 0, cn - bs));
    // the NTS output, here
    i64 rc = callp(ph_mc_build, argc, argv);
    if (rc) return rc;
    // the ZTS output, in a process of its own, with argv's --config replaced
    write_file(zcfg, zb);
    uptr av = xalloc((argc + 3) * 8);
    i64 k = 0;
    i = 0;
    loop {
        if (i >= argc) break;
        if (i == ci) st64(av + k * 8, zcfg);
        else st64(av + k * 8, ld64(argv + i * 8));
        k = k + 1;
        i = i + 1;
    }
    if (ci < 0) { st64(av + k * 8, "--config"); st64(av + (k + 1) * 8, zcfg); k = k + 2; }
    st64(av + k * 8, 0);
    uptr self = host_self_path();
    st64(av, self);
    i64 zr = drv_spawn(self, av, 0);
    unlink(zcfg);
    return zr;
}

void ph_build_init() {
    ph_mc_build = &drv_build;
    subcommand("build", &ph_build,
        "usage: mc build [DIR] [--config FILE] [--sync [--yes]] [--compiler-only] [--limits|--fix-limits] [--sysroot-dir DIR] [--libs-dir DIR]\n");
}

// -- `mc-php prog.php [-o OUT]`: compile AND link, in one command ---------------
//
// mc's cli writes an OBJECT for a single-file compile; its only one-step
// program road, `--exe`, is gone (docs/plan.md). So that `mc-php prog.php`
// leaves a runnable PROGRAM and not a `.o`, mc-php's own main links it: it
// writes a `[project]` + `[linker]` next to the cwd and runs mc's build, the
// same object + platform-linker road the project road and tests/mcphp.sh take.
// mc expands `{obj}`/`{out}`/`{sdk}` and spawns the linker -- so the macOS SDK
// comes from mc's own `xcrun`, not from a path hard-coded here.
//
// Only macOS and Linux: a Windows program needs kernel32/ucrtbase import
// libraries that are not on a fixed path, so there it stays the project road
// (src/mc-php.windows-*.toml) or the object + lld-link steps the README gives.

i64 ph_link_wanted(i64 argc, uptr argv) {
    uptr os = host_os();
    if (!str_eq(os, "macos") && !str_eq(os, "linux")) return 0;
    uptr src = 0;
    uptr out = 0;
    i64 i = 1;
    loop {
        if (i >= argc) break;
        uptr a = ld64(argv + i * 8);
        if (ld8(a) == 45) {                                  // a flag
            if (str_eq(a, "-o") && i + 1 < argc) { out = ld64(argv + (i + 1) * 8); i = i + 2; continue; }
            // a mode that prints and does not build, or a project/other verb
            if (mem_eq(a, "--dump", 6)) return 0;
            if (str_eq(a, "--help") || str_eq(a, "-h") || str_eq(a, "--version")
                || str_eq(a, "--host") || str_eq(a, "--limits") || str_eq(a, "--fix-limits")
                || str_eq(a, "--sync") || str_eq(a, "--config")) return 0;
            if (str_eq(a, "--libs-dir") || str_eq(a, "--sysroot-dir")) { i = i + 2; continue; }
            i = i + 1;                                        // --opt=, --machine=, ...
            continue;
        }
        // a positional: a .php is a program to build; anything else (a
        // subcommand word, a .mc) is not this road
        i64 n = cstrlen(a);
        if (n >= 4 && mem_eq(a + n - 4, ".php", 4)) { if (src) return 0; src = a; i = i + 1; continue; }
        return 0;
    }
    if (!src) return 0;
    // an output that names an object is what a caller asked for: leave it
    if (out) {
        i64 n = cstrlen(out);
        if (n >= 2 && mem_eq(out + n - 2, ".o", 2)) return 0;
        if (n >= 4 && mem_eq(out + n - 4, ".obj", 4)) return 0;
    }
    return 1;
}

void ph_link_put(uptr b, uptr s) { buf_put(b, s, cstrlen(s)); }

// the [project] + host [linker] for a single-file program, in the cwd so entry
// and out resolve relative to it as the user typed them
uptr ph_link_cfg(uptr src, uptr out, uptr opt) {
    uptr b = xalloc(BUF_SIZE);
    buf_init(b);
    ph_link_put(b, "[project]\nentry = \"");
    ph_link_put(b, src);
    ph_link_put(b, "\"\nout = \"");
    ph_link_put(b, out);
    ph_link_put(b, "\"\nkind = \"exe\"\n");
    if (opt) { ph_link_put(b, "opt = "); ph_link_put(b, opt); ph_link_put(b, "\n"); }
    if (str_eq(host_os(), "macos")) {
        ph_link_put(b, "\n[linker]\ncmd = \"ld\"\nargs = [\"{obj}\", \"-lSystem\", \"-syslibroot\", \"{sdk}\", \"-o\", \"{out}\"]\n");
    } else {
        // Linux: pick the libc the HOST actually has, the way mc's own sandbox
        // does (src/sandbox.mc). The CONFIGURED libc of this compiler (gnu/musl)
        // is a build-time toml choice, not an mc host answer -- there is no
        // host_libc() -- so the loader present on disk is the signal. The musl
        // loader present -> the musl crt + ld.lld, exactly as before; otherwise
        // the platform compiler driver links, so the crt objects and the dynamic
        // linker are the ones IT ships and no glibc path is hard-coded here.
        uptr arch = host_arch();
        uptr musl = p_cat(p_cat("/lib/ld-musl-", arch, 0, cstrlen(arch)), ".so.1", 0, 5);
        if (lex_readable(musl)) {
            ph_link_put(b, "\n[linker]\ncmd = \"ld.lld\"\nargs = [\"-dynamic-linker\", \"/lib/ld-musl-");
            ph_link_put(b, arch);
            ph_link_put(b, ".so.1\", \"-L/usr/lib\", \"/usr/lib/crt1.o\", \"/usr/lib/crti.o\", \"{obj}\", \"-lc\", \"/usr/lib/crtn.o\", \"-o\", \"{out}\"]\n");
        } else {
            ph_link_put(b, "\n[linker]\ncmd = \"cc\"\nargs = [\"{obj}\", \"-o\", \"{out}\"]\n");
        }
    }
    return b;
}

// an unsupported flag on the single-file road is an error, not a silently-built
// binary: a typo (--libz-dir) would otherwise produce a program (exit 2).
i64 ph_link_badopt(uptr a) {
    write(2, "mc-php: unsupported option: ", 28);
    write(2, a, cstrlen(a));
    write(2, "\n", 1);
    return 2;
}

i64 ph_link_single(i64 argc, uptr argv) {
    uptr src = 0;
    uptr out = 0;
    uptr opt = 0;
    uptr ldir = 0;                    // --libs-dir value, forwarded to mc build
    uptr sdir = 0;                    // --sysroot-dir value, forwarded to mc build
    i64 i = 1;
    loop {
        if (i >= argc) break;
        uptr a = ld64(argv + i * 8);
        if (ld8(a) == 45) {                              // a flag
            if (str_eq(a, "-o")) {
                if (i + 1 >= argc) return ph_link_badopt(a);
                out = ld64(argv + (i + 1) * 8); i = i + 2; continue;
            }
            if (mem_eq(a, "--opt=", 6)) { opt = a + 6; i = i + 1; continue; }
            if (str_eq(a, "--libs-dir")) {
                if (i + 1 >= argc) return ph_link_badopt(a);
                ldir = ld64(argv + (i + 1) * 8); i = i + 2; continue;
            }
            if (str_eq(a, "--sysroot-dir")) {
                if (i + 1 >= argc) return ph_link_badopt(a);
                sdir = ld64(argv + (i + 1) * 8); i = i + 2; continue;
            }
            return ph_link_badopt(a);                    // every other flag: reject it
        }
        src = a;
        i = i + 1;
    }
    // no -o: the program takes the source's name without its .php extension
    if (!out) {
        i64 n = cstrlen(src);
        i64 bgn = n;
        loop { if (bgn == 0) break; i64 c = ld8(src + bgn - 1); if (c == 47 || c == 92) break; bgn = bgn - 1; }
        i64 bn = n - bgn;
        if (bn >= 4 && mem_eq(src + bgn + bn - 4, ".php", 4)) bn = bn - 4;
        out = xstrdup(src + bgn, bn);
    }
    uptr b = ph_link_cfg(src, out, opt);
    uptr pid = php_dec(ph_pid());
    uptr cfg = p_cat(p_cat(".mcphp-link-", pid, 0, cstrlen(pid)), ".toml", 0, 5);
    write_file(cfg, b);
    // mc build . --config cfg, carrying the toolchain-path options the caller gave
    i64 na = 5;
    if (ldir) na = na + 2;
    if (sdir) na = na + 2;
    uptr av = xalloc((na + 1) * 8);
    i64 k = 0;
    st64(av + k * 8, "mc-php"); k = k + 1;
    st64(av + k * 8, "build");  k = k + 1;
    st64(av + k * 8, ".");      k = k + 1;
    st64(av + k * 8, "--config"); k = k + 1;
    st64(av + k * 8, cfg);      k = k + 1;
    if (ldir) { st64(av + k * 8, "--libs-dir");    k = k + 1; st64(av + k * 8, ldir); k = k + 1; }
    if (sdir) { st64(av + k * 8, "--sysroot-dir"); k = k + 1; st64(av + k * 8, sdir); k = k + 1; }
    st64(av + k * 8, 0);
    i64 rc = callp(&drv_build, k, av);
    unlink(cfg);
    // mc wrote <out>.o beside the program; drop it
    unlink(p_cat(out, ".o", 0, 2));
    return rc;
}

i64 main(i64 argc, uptr argv, uptr envp) {
    host_init(envp);
    // argv, for ph_dump_machine (src/program.mc): the atomics file follows
    // --machine= in a dump mode
    ph_argc = argc;
    ph_argv = argv;
    mc_machines_init();
    mc_writers_init();
    mc_bundle_init();
    mc_build_init();
    mc_pkg_init();
    mc_sandbox_init();
    ph_build_init();
    // `mc-php prog.php [-o OUT]` compiles AND links; everything else is mc's
    if (ph_link_wanted(argc, argv)) return ph_link_single(argc, argv);
    return mc_main(argc, argv, envp);
}

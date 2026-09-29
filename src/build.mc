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
//   [linker]  every "php8.lib" -> "php8ts.lib" (Windows: a ZTS php is
//             php8ts.dll, and the import library names it)
//
// The copy sits beside the file it copies, so every relative path in it means
// what it meant there, and it is removed when the second build ends. A second
// process because mc's tables are built once per process: two compilations do
// not fit in one (mc's own `[compiler]` road spawns for the same reason).
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

// the project file with the three lines of the ZTS build (the header says
// which), line by line
uptr ph_ts_config_text(uptr src, i64 n, uptr out) {
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
        } else if (str_eq(tb, "linker")) {
            i64 k = 0;
            loop {
                if (k >= ln) break;
                if (k + 8 <= ln && mem_eq(line + k, "php8.lib", 8)) { buf_put(b, "php8ts.lib", 10); k = k + 8; continue; }
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
    uptr zb = ph_ts_config_text(src, n, zout);
    // beside the original: the same directory, so the same relative paths
    i64 cn = cstrlen(cfg);
    i64 bs = cn;
    loop { if (bs == 0) break; if (ld8(cfg + bs - 1) == 47 || ld8(cfg + bs - 1) == 92) break; bs = bs - 1; }
    uptr zcfg = path_join(cfg, p_cat(p_cat(".", cfg + bs, 0, cn - bs), ".zts", 0, 4));
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

i64 main(i64 argc, uptr argv, uptr envp) {
    host_init(envp);
    mc_machines_init();
    mc_writers_init();
    mc_bundle_init();
    mc_build_init();
    mc_pkg_init();
    mc_sandbox_init();
    ph_build_init();
    return mc_main(argc, argv, envp);
}

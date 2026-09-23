// host_extra_linux.mc -- what this compiler needs from the Linux host that
// mc's own Linux host layer does not declare.
//
// mc's host layers are mc's: they carry what mc's compiler calls, and nothing
// says a consumer needs the same set. src/host_macos.mc declares realpath(3)
// because mc uses it; src/host_linux.mc does not, because mc does not. mc-php
// does -- src/stmt.mc resolves a script's path at compile time, so that a
// diagnostic under a symlinked directory names the file php would name.
//
// A second `extern` of a name the host layer already declared is `function
// declared twice`, so this cannot simply be declared in src/ for every host.
// It is per-entry, exactly like the host layer it completes, and there is no
// macOS twin because the macOS host layer already has the one name in it.
//
// The consequence, measured natively with mc 1.1.0 on linux/aarch64 rather
// than reasoned about: `mc build` -- which is src/mc-php.mc, the `<mc/host>`
// entry -- fails there with `src/stmt.mc:195: call to unknown function`, and
// `mc build src --config src/mc-php.linux-aarch64.toml` succeeds. So the
// per-host config is the NATIVE road on Linux as well as the cross one, and
// mc.toml, src/mc-php.mc and the README all say so.
extern uptr realpath(uptr path, uptr resolved);

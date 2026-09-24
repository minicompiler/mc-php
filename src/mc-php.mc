// mc-php.mc -- the compiler's entry point.
//
// mc's own core, the float library (php's `float` is <float>'s f64, and the
// two float machines are what lower it on arm64 and x86-64), and this
// repository's module. `mc build` reads mc.toml and writes build/mc-php.
//
// `<mc/host>` is the host layer of the compiler DOING the build, so this entry
// is the native one -- for a host whose mc layer declares everything mc-php
// calls. That is macOS today and it is NOT Linux: `src/stmt.mc` calls
// realpath(3), which only src/host_macos.mc declares, and a second `extern` of
// a name the host layer already has is `function declared twice`, so it cannot
// be declared here for everyone. On Linux this entry is
// `src/stmt.mc:195: call to unknown function` -- measured, natively, with mc
// 1.1.0 for linux/aarch64 -- and the entry to build there is the one for your
// architecture, which is a native build and not a cross one:
//
//     mc build src --config src/mc-php.linux-aarch64.toml
//     mc build src --config src/mc-php.linux-x86_64.toml
//
// Those two include src/host_extra_linux.mc, which is the one declaration mc's
// Linux host layer does not carry. Windows has an entry per architecture too
// (src/mc-php-windows-*.mc), built on Windows only.
#include <mc/host>
#include <mc/core>
#include <float>
#include <machine_arm64_float>
#include <machine_x86_64_float>
#include "php.mc"

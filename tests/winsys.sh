#!/bin/sh
# The Windows link inputs, built on the machine that links.
#
#     sh tests/winsys.sh ARCH        # aarch64 | x86_64  ->  build/win-ARCH/
#
# Windows has no C library a program is entitled to, so everything a link
# needs besides the object mc wrote is made here, from files in this
# repository and mc's library tree, with two tools -- `mc` and `lld-link`:
#
#   kernel32.lib  ucrtbase.lib  php8.lib  php8ts.lib
#       IMPORT libraries: a list of names, nothing from the DLL. `lld-link
#       -lib -def:` writes one from src/win/*.def, so no Windows SDK, no php
#       development pack and no llvm-dlltool.
#   mcrt.obj      mc's POSIX shims over kernel32 (<sys_windows_host>), which
#                 the COMPILER links next to itself: mc's core declares
#                 open/write/... `extern` and this object defines them.
#   winstart.obj  mc's entry point, mc_start, for the compiler.
#
# A PROGRAM mc-php writes needs neither object -- its runtime defines its own
# (lib/rt_host_windows*.mc) -- only kernel32.lib and ucrtbase.lib, and only on
# the object road (windows/aarch64; windows/x86_64 has mc's one-step PE writer).
# An EXTENSION needs php8.lib (or php8ts.lib for a thread-safe php) as well.
#
# src/mc-php.windows-ARCH.toml and examples/hello/mcphp.windows.toml name
# this directory in [sysroot].
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/.." && pwd)
cd "$root"
arch=${1:?usage: tests/winsys.sh aarch64|x86_64}
MC=${MC:-mc}
case "$arch" in
    aarch64) m=arm64; be=coff-obj-arm64 ;;
    x86_64)  m=x64;   be=coff-obj-x86_64 ;;
    *) echo "tests/winsys.sh: unknown arch: $arch" >&2; exit 2 ;;
esac
d=build/win-$arch
mkdir -p "$d"
for lib in kernel32 ucrtbase php8 php8ts; do
    lld-link -lib -machine:$m -def:src/win/$lib.def -out:$d/$lib.lib
done
"$MC" --backend=$be src/win/mcrt.mc -o $d/mcrt.obj
"$MC" --backend=$be src/win/winstart.mc -o $d/winstart.obj
ls -l "$d"

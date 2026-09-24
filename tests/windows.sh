#!/bin/sh
# Prove a WINDOWS mc-php by RUNNING it, on the Windows host it is for.
#
#     sh tests/windows.sh [aarch64|x86_64]
#
# tests/linux.sh's sibling and the same gate -- tests/fixtures.sh unchanged,
# then tests/ext.sh -- against the php of THIS host, so every fixture is graded
# against what php on Windows prints (PHP_OS "WINNT", PHP_EOL "\r\n", a
# backslash in every path) and not against a recording made elsewhere.
#
# Run from Git Bash, after the compiler was built ON this host:
#
#     sh tests/winsys.sh ARCH
#     mc build src --config src/mc-php.windows-ARCH.toml
#     sh tests/winsys.sh x86_64          # the extension's, see below
#
# Two things differ per architecture, both mc's and both said here rather than
# hidden:
#
#   aarch64  mc has no one-step PE writer for windows/aarch64 (its exe slot is
#            0), so a PROGRAM is an object linked with lld-link -- MCPHP_WINLINK
#            tells tests/mcphp.sh which import libraries to use.
#   both     php publishes no arm64 Windows build, so the php on a Windows-on-
#            ARM machine is the x64 build, emulated, and the EXTENSION it loads
#            is an x64 DLL: examples/hello/mcphp.windows.toml says x86_64 on
#            both hosts and the arm64 compiler cross-compiles across
#            ARCHITECTURES for it.
set -u
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/.." && pwd)
cd "$root"
arch=${1:-x86_64}
case "$arch" in
    aarch64|x86_64) ;;
    *) echo "tests/windows.sh: unknown arch: $arch (aarch64 or x86_64)" >&2; exit 2 ;;
esac
BIN=build/mc-php-windows-$arch.exe
[ -f "$BIN" ] || {
    echo "tests/windows.sh: no $BIN" >&2
    echo "  sh tests/winsys.sh $arch && mc build src --config src/mc-php.windows-$arch.toml" >&2
    exit 2
}
export BIN
PHP=${PHP:-php}
# the form the NATIVE programs read: MSYS's /d/a/... means nothing to them
rootn=$(cygpath -m "$root" 2>/dev/null || echo "$root")
if [ "$arch" = aarch64 ]; then
    MCPHP_WINLINK=$rootn/build/win-aarch64
    export MCPHP_WINLINK
fi
fail=0

echo "== windows/$arch: $BIN =="
echo "  uname:  $(uname -srm)"
echo "  php:    $("$PHP" -v | head -1)"
echo "  mc-php: $("$BIN" --version)"
"$BIN" --host | sed 's/^/  /'

echo ""
echo "== it loads and it compiles and the program runs =="
. "$here/tmp.sh"
mcphp_tmp_init mcphp-win
tmp=$MCPHP_TMP
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/smoke.php" <<'PHP'
<?php
echo PHP_OS, "|", PHP_OS_FAMILY, "|", DIRECTORY_SEPARATOR, "|", PATH_SEPARATOR, "|", strlen(PHP_EOL), "\n";
var_dump(is_dir("."), is_file(__FILE__), filesize(__FILE__) > 0, strlen(getcwd()) > 0);
var_dump(getenv("MCPHP_WIN_SMOKE"), sin(0.5), round(sqrt(2.0), 6));
PHP
PHPINI="-d display_errors=1 -d log_errors=1 -d html_errors=0 -d error_reporting=E_ALL"
MCPHP_WIN_SMOKE=yes MCPHP_OUT=$tmp/smoke.bin MCPHP_BIN=$BIN \
    sh tests/mcphp.sh "$tmp/smoke.php" > "$tmp/m.out" 2>&1; mrc=$?
MCPHP_WIN_SMOKE=yes "$PHP" $PHPINI "$tmp/smoke.php" > "$tmp/p.out" 2>&1; prc=$?
sed 's/^/  mc-php  /' "$tmp/m.out"
sed 's/^/  php     /' "$tmp/p.out"
if cmp -s "$tmp/m.out" "$tmp/p.out" && [ "$mrc" = "$prc" ]; then
    echo "  the two agree, exit $mrc"
else
    echo "  THEY DIFFER (mc-php exit $mrc, php exit $prc)"; fail=1
fi

echo ""
echo "== the fixture gate, on this host =="
sh tests/fixtures.sh || fail=1

echo ""
echo "== the extension road, on this host =="
WINDOWS=1 sh tests/ext.sh || fail=1

echo ""
echo "== the examples, on this host =="
WINDOWS=1 sh tests/examples.sh || fail=1

[ "$fail" = 0 ] || { echo "windows: something failed"; exit 1; }
echo "windows/$arch: green"

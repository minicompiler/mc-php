#!/bin/sh
# Prove a LINUX mc-php by RUNNING it, not by linking it.
#
#     sh tests/linux.sh [aarch64|x86_64]
#
# It runs the SAME gate the macOS host runs -- tests/fixtures.sh, unchanged --
# inside a container that has php 8.5.10 of its own, so every fixture is
# compared against php ON THE HOST THAT RAN IT and not against a recording made
# somewhere else. A Linux PHP_OS is "Linux" and a macOS one is "Darwin"; a gate
# that compared one host's php against the other host's mc-php would grade that
# difference as a failure and hide the ones that matter.
#
# What is NOT proved here and is said rather than implied: this does not build
# the compiler. Cross-build it first, on any host, and this runs it:
#
#     mc build src --config src/mc-php.linux-aarch64.toml
#     mc build src --config src/mc-php.linux-x86_64.toml
#
# Needs docker and nothing else. On a macOS host with a Linux VM, run it INSIDE
# the VM against the same path -- the repository is mounted there:
#
#     limactl shell mc-k7 -- sh "$PWD/tests/linux.sh" aarch64
#
# perl is what tests/lim.sh bounds every fixture with, and the php image does
# not carry it; it is the one package this adds, so that the gate stays the
# gate instead of a Linux fork of it. lld is the second, and it is the LINKER:
# php loads a shared object and mc writes an ELF executable, so the [linker]
# road is the only road here as it is on macOS (docs/php-extension.md).
set -u
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/.." && pwd)
cd "$root"

arch=${1:-aarch64}
case "$arch" in
    aarch64) nick=arm64;  plat=linux/arm64 ;;
    x86_64)  nick=x86_64; plat=linux/amd64 ;;
    *) echo "tests/linux.sh: unknown arch: $arch (aarch64 or x86_64)" >&2; exit 2 ;;
esac
bin=build/mc-php-linux-$nick
[ -f "$bin" ] || {
    echo "tests/linux.sh: no $bin" >&2
    echo "  mc build src --config src/mc-php.linux-$arch.toml" >&2
    exit 2
}
img=${MCPHP_LINUX_IMAGE:-php:8.5-alpine}
# mc itself, for the hand-written examples: a released mc for this host,
# unpacked where CI unpacks it (build/mc-linux-<nick>/mc). It is a static
# binary and runs in the container as it is.
mc=$root/build/mc-linux-$nick/mc
[ -x "$mc" ] || mc=mc-not-installed

echo "== linux/$arch: $bin in $img =="
file "$bin" 2>/dev/null | sed 's/^/  /'

# `--network` is left alone on purpose: apk needs it. Everything else is the
# repository, mounted at the path it already has, because tests/mcphp.sh
# resolves its own root from $0 and a different mount point would make the
# binaries it writes land somewhere the gate does not sweep.
exec docker run --rm --platform "$plat" \
    -v "$root:$root" -w "$root" \
    -e BIN="$bin" -e MC="$mc" -e MCPHP_TMP=/tmp/mcphp-linux \
    "$img" sh -c '
set -u
mkdir -p /tmp/mcphp-linux
apk add --no-cache perl lld >/dev/null 2>&1 || { echo "  cannot install perl and lld"; exit 2; }
echo ""
echo "  uname:  $(uname -srm)"
echo "  php:    $(php -v | head -1)"
echo "  mc-php: $("$BIN" --version)"

echo ""
echo "== it loads and it compiles and the program runs =="
cat > /tmp/hosts-smoke.php <<"EOF"
<?php
echo PHP_OS, "|", PHP_OS_FAMILY, "|", DIRECTORY_SEPARATOR, "|", PATH_SEPARATOR, "\n";
var_dump(is_dir("/tmp"), is_file("/etc/hosts"), filesize("/etc/hosts") > 0, strlen(getcwd()) > 0);
EOF
"$BIN" --exe /tmp/hosts-smoke.php -o /tmp/hosts-smoke || exit 1
/tmp/hosts-smoke > /tmp/hosts-smoke.mc 2>&1; mrc=$?
php -d display_errors=1 -d log_errors=1 -d html_errors=0 -d error_reporting=E_ALL \
    /tmp/hosts-smoke.php > /tmp/hosts-smoke.php.out 2>&1; prc=$?
sed "s/^/  mc-php  /" /tmp/hosts-smoke.mc
sed "s/^/  php     /" /tmp/hosts-smoke.php.out
if cmp -s /tmp/hosts-smoke.mc /tmp/hosts-smoke.php.out && [ "$mrc" = "$prc" ]; then
    echo "  the two agree, exit $mrc"
else
    echo "  THEY DIFFER (mc-php exit $mrc, php exit $prc)"; exit 1
fi

echo ""
echo "== the fixture gate, on this host =="
sh tests/fixtures.sh || exit 1

echo ""
echo "== the fixture gate again, every string counted (MCPHP_RC=check) =="
# tests/run.sh says why: the string discipline of the extension road, graded on
# the program road by poisoning a string that reaches zero
MCPHP__RC=check sh tests/fixtures.sh || exit 1

echo ""
echo "== the extension road, on this host =="
# The same six steps the macOS gate runs, with examples/hello/mcphp.linux.toml
# for the [linker]. The .so is loaded by the php IN THIS CONTAINER and graded
# against that php -- which is the whole reason this script exists.
LINUX=1 sh tests/ext.sh || exit 1

echo ""
echo "== the examples, on this host =="
# The hand-written halves are PLAIN mc (tests/examples.sh says why) and want
# an mc for this host beside the compiler; without one they skip by name.
LINUX=1 sh tests/examples.sh
'

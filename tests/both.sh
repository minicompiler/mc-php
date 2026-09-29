#!/bin/sh
# `[php] thread_safety = "both"`: one project, two outputs, each loaded by the
# php it is for.
#
#     sh tests/both.sh [aarch64|x86_64]
#
# examples/hello is built once with a copy of its Linux project file that says
# "both", inside php's NTS image; that writes build/hello.so and
# build/hello-zts.so (src/build.mc). Then:
#
#   php:8.5-alpine      loads hello.so, runs check.php, and REFUSES hello-zts.so
#   php:8.5-zts-alpine  loads hello-zts.so, runs check.php, and REFUSES hello.so
#
# and the two check.php outputs are the same bytes. A refusal is php's own
# (`Unable to initialize module`, the two build ids): the module header is what
# the loader compares, and the header is the only thing the two differ in
# besides the engine's globals.
#
# Needs docker and a cross-built compiler (tests/linux.sh says how); on a macOS
# host, run it inside the Linux VM, as tests/linux.sh is run.
set -u
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/.." && pwd)
cd "$root"

arch=${1:-aarch64}
case "$arch" in
    aarch64) nick=arm64;  plat=linux/arm64 ;;
    x86_64)  nick=x86_64; plat=linux/amd64 ;;
    *) echo "tests/both.sh: unknown arch: $arch (aarch64 or x86_64)" >&2; exit 2 ;;
esac
bin=build/mc-php-linux-$nick
[ -f "$bin" ] || { echo "tests/both.sh: no $bin" >&2; exit 2; }
EX=examples/hello
cfg=$EX/.mcphp.linux.toml.both-test
sed 's/^thread_safety = .*/thread_safety = "both"/' $EX/mcphp.linux.toml > "$cfg"
fail=0
say() { printf '  %s\n' "$*"; }
bad() { printf '  FAIL %s\n' "$*"; fail=1; }
run() { # IMAGE SCRIPT: sh -c in the image, the repository mounted where it is
    docker run --rm --platform "$plat" -v "$root:$root" -w "$root" "$1" sh -c "$2"
}

# the outputs are written by the container's root: removed from inside one
clean() { run php:8.5-alpine "rm -rf $EX/build"; rm -f "$cfg"; }
trap clean EXIT
run php:8.5-alpine "rm -rf $EX/build"

echo "== thread_safety = \"both\", linux/$arch =="
if run php:8.5-alpine "apk add --no-cache lld >/dev/null 2>&1; $bin build $EX --config $cfg" > /tmp/both.build 2>&1; then
    sed 's/^/  /' /tmp/both.build
else
    bad "the build:"; sed 's/^/      /' /tmp/both.build; exit 1
fi
for f in hello.so hello-zts.so; do
    [ -f "$EX/build/$f" ] || { bad "no $EX/build/$f"; exit 1; }
done
say "two outputs: hello.so $(wc -c < $EX/build/hello.so | tr -d ' ') bytes, hello-zts.so $(wc -c < $EX/build/hello-zts.so | tr -d ' ') bytes"

# IMAGE SO: loaded, extension_loaded() true, check.php's output kept
load() {
    run "$1" "php -d extension=$root/$EX/build/$2 -r 'exit(extension_loaded(\"hello\") ? 0 : 3);' && php -d extension=$root/$EX/build/$2 $EX/check.php" > "/tmp/both.$2.out" 2>&1
}
# IMAGE SO: refused by php, by name
refuse() {
    run "$1" "php -d extension=$root/$EX/build/$2 -r 'echo extension_loaded(\"hello\") ? \"loaded\" : \"not loaded\", PHP_EOL;'" > "/tmp/both.$2.ref" 2>&1
    if grep -q 'Unable to initialize module' "/tmp/both.$2.ref" && grep -q '^not loaded' "/tmp/both.$2.ref"; then
        say "$1 refuses $2: $(grep 'Module compiled with' "/tmp/both.$2.ref" | tr -s ' ')"
    else
        bad "$1 did not refuse $2:"; sed 's/^/      /' "/tmp/both.$2.ref"
    fi
}
if load php:8.5-alpine hello.so; then say "php:8.5-alpine loads hello.so: check.php $(wc -l < /tmp/both.hello.so.out | tr -d ' ') lines"
else bad "php:8.5-alpine and hello.so:"; sed 's/^/      /' /tmp/both.hello.so.out; fi
if load php:8.5-zts-alpine hello-zts.so; then say "php:8.5-zts-alpine loads hello-zts.so: check.php $(wc -l < /tmp/both.hello-zts.so.out | tr -d ' ') lines"
else bad "php:8.5-zts-alpine and hello-zts.so:"; sed 's/^/      /' /tmp/both.hello-zts.so.out; fi
if cmp -s /tmp/both.hello.so.out /tmp/both.hello-zts.so.out; then say "the two check.php outputs are the same bytes"
else bad "the two check.php outputs differ"; diff /tmp/both.hello.so.out /tmp/both.hello-zts.so.out | sed -n '1,12p' | sed 's/^/      /'; fi
refuse php:8.5-alpine hello-zts.so
refuse php:8.5-zts-alpine hello.so

[ "$fail" = 0 ] || { echo "  both: something failed"; exit 1; }
echo "  both: each output loads in its php and only there"

#!/bin/sh
# The LEAK check: every string, zval, array and chunk an extension allocates
# comes from Zend's allocator, and a php built with --enable-debug names each
# block still allocated when a request ends -- "Freeing 0x... (N bytes)" and
# "=== Total N memory leaks detected ===" -- where a release php frees them in
# silence. So the modules below are loaded into a DEBUG php, run, and that
# report must be empty.
#
#     sh tests/leaks.sh [aarch64|x86_64]
#
# Needs docker and a Linux mc-php, cross-built on any host:
#
#     mc build src --config src/mc-php.linux-aarch64.toml
#
# On a macOS host with a Linux VM, run it inside the VM against the same path:
#
#     limactl shell mc-k7 -- sh "$PWD/tests/leaks.sh" aarch64
#
# The debug php is built once, from the php:8.5-alpine image's own source
# (--enable-debug --disable-all: the standard extension is always there, and
# nothing these modules call is anywhere else), and cached as the image
# mc-php-phpdbg. It takes a few minutes the first time.
#
# What it runs, each in ONE request of the debug php:
#   examples/decimal: check.php (the differential's calls, every error path
#   included), soak.php with 100 000 calls, and bench.php;
#   the ownership shapes of tests/ext.sh steps 11 to 13 -- in-place growth, a
#   loop that builds strings inside one call, a string shared by two names, a
#   parameter written, strings kept by an array, a closure and a static, an
#   exception thrown from the middle of a loop -- and a function that pins
#   (a static and a global), whose references live until RSHUTDOWN.
# A module built for this php has to say so: [php].debug = true and a build
# id ending ",debug", or the loader refuses it by name.
set -u
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/.." && pwd)
cd "$root"

arch=${1:-aarch64}
case "$arch" in
    aarch64) nick=arm64;  plat=linux/arm64 ;;
    x86_64)  nick=x86_64; plat=linux/amd64 ;;
    *) echo "tests/leaks.sh: unknown arch: $arch (aarch64 or x86_64)" >&2; exit 2 ;;
esac
bin=build/mc-php-linux-$nick
[ -f "$bin" ] || { echo "tests/leaks.sh: no $bin -- mc build src --config src/mc-php.linux-$arch.toml" >&2; exit 2; }
img=mc-php-phpdbg-$nick
if ! docker image inspect "$img" > /dev/null 2>&1; then
    echo "== building $img (php 8.5, --enable-debug) =="
    printf '%s\n' \
        'FROM php:8.5-alpine' \
        'RUN apk add --no-cache $PHPIZE_DEPS bison re2c linux-headers lld \' \
        ' && docker-php-source extract && cd /usr/src/php \' \
        ' && ./configure --prefix=/opt/phpdbg --enable-debug --disable-all --disable-cgi --disable-phpdbg --without-pear > /dev/null \' \
        ' && make -j4 > /dev/null && make install > /dev/null && /opt/phpdbg/bin/php -v' \
        | docker build --platform "$plat" -t "$img" - || exit 2
fi

exec docker run --rm --platform "$plat" -v "$root:$root" -w "$root" -e BIN="$bin" "$img" sh -c '
set -u
PHP=/opt/phpdbg/bin/php
fail=0
say() { printf "  %s\n" "$*"; }
bad() { printf "  FAIL %s\n" "$*"; fail=1; }
echo "  php:    $($PHP -v | head -1)"
bid=$($PHP -i | sed -n "s/^PHP Extension Build => //p")
api=$($PHP -i | sed -n "s/^PHP API => //p")
echo "  build:  $bid"
t=/tmp/mcphp-leaks
rm -rf "$t"; mkdir -p "$t"
# the project file for THIS php, from the Linux one
dbg() { sed "s/^build_id = .*/build_id = \"$bid\"/; s/^debug = .*/debug = true/; s/^api = .*/api = $api/" "$1"; }

# one run: the answer must be what the release php printed, and the debug
# allocator must have nothing to report
leakfree() {
    name=$1; shift
    "$PHP" -d report_memleaks=1 "$@" > "$t/out" 2> "$t/err"; rc=$?
    # every request here is expected to succeed: a module that does not load,
    # or a php that dies, prints no leak report and is not leak-free
    if [ "$rc" != 0 ]; then
        bad "$name: exit $rc"
        tail -5 "$t/out" "$t/err" | sed "s/^/      /"
        return
    fi
    if grep -q "memory leaks detected\|Freeing 0x" "$t/out" "$t/err"; then
        bad "$name: the debug allocator reports blocks still allocated:"
        grep -h "Freeing\|leaks detected" "$t/out" "$t/err" | head -8 | sed "s/^/      /"
        return
    fi
    say "$name: exit 0, no block left at the end of the request"
}

cp -R examples/decimal "$t/decimal"
dbg examples/decimal/mcphp.linux.toml > "$t/decimal/dbg.toml"
rm -rf "$t/decimal/build"
if "$BIN" build "$t/decimal" --config "$t/decimal/dbg.toml" > "$t/b.out" 2>&1; then
    so=$t/decimal/build/decimal.so
    leakfree "decimal check.php" -d extension="$so" "$t/decimal/check.php"
    leakfree "decimal soak.php 100000" -d extension="$so" "$t/decimal/soak.php" 100000
    leakfree "decimal bench.php" -d extension="$so" "$t/decimal/bench.php"
else
    bad "decimal: it would not build"; sed "s/^/      /" "$t/b.out"
fi

mkdir -p "$t/own"
{ printf "<?php\n"; awk "/^echo /{exit} /^function /{p=1} p" tests/g/111-string-ownership.php
  printf "%s\n" \
    "function churn(int \$n): int { \$t = 0; for (\$i = 0; \$i < \$n; \$i++) { \$s = str_repeat(\"y\", 1000) . \$i; \$t += strlen(\$s); } return \$t; }" \
    "function pinned(string \$s): string { global \$last; static \$all = \"\"; \$all .= \$s; \$prev = \$last ?? \"\"; \$last = \$s . \"!\"; return \$prev . \"|\" . \$all; }"
} > "$t/own/r.php"
sed "s|^entry = .*|entry = \"r.php\"|; s|^out = .*|out = \"build/r.so\"|" examples/hello/mcphp.linux.toml | dbg /dev/stdin > "$t/own/r.toml"
cat > "$t/own/run.php" <<"EOF"
<?php
for ($k = 0; $k < 3; $k++) {
    echo strlen(grow(1000)), " ", alias(), " ", self_cat("ab"), " ", param("x$k"), " ", keep_last("a", "b$k"), " ", keepers(), " ", counter("t$k"), " ", pinned("p$k"), "\n";
    try { echo thrower($k), "\n"; } catch (RuntimeException $e) { echo $e->getMessage(), "\n"; }
}
echo churn(20000), "\n";
EOF
if "$BIN" build "$t/own" --config "$t/own/r.toml" > "$t/o.out" 2>&1; then
    leakfree "the ownership shapes, a pinned call and a loop inside one call" -d extension="$t/own/build/r.so" "$t/own/run.php"
else
    bad "the ownership shapes: it would not build"; sed "s/^/      /" "$t/o.out"
fi
[ "$fail" = 0 ] || { echo "  leaks: something failed"; exit 1; }
echo "  leaks: every request ended with nothing of the module still allocated"
'

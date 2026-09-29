#!/bin/sh
# A ZTS module under a REAL threaded SAPI: FrankenPHP (docker image
# dunglas/frankenphp:php8.5-alpine, a thread-safe php 8.5 with a pool of php
# threads), hit with concurrent requests.
#
#     sh tests/frankenphp.sh [aarch64|x86_64] [REQUESTS] [PARALLEL]
#
# tests/ext/zts/zts.php is built as a ZTS module by the cross-built compiler
# (tests/linux.sh says how to build it) and loaded by FrankenPHP with
# MCPHP_ZTS_READONLY=1, which makes MINIT's memory read-only in the module
# (lib/php_zts.mc): a request that wrote it would fault on the spot. Then:
#
#   * every answer is the one the formula in check() says -- each request
#     starts from what MINIT left (a global array, an object, a static
#     property, a constant) and sees only its own writes, a static starts at
#     0, a constant a request defines is its own, a call through php's
#     function table reaches THIS request's function;
#   * the answers came from more than one php thread (mcphp_thread());
#   * FrankenPHP's resident memory after the whole load is within a bound of
#     what it was after a warm-up: no leak across requests.
#
# Needs docker; on a macOS host run it inside the Linux VM, as tests/linux.sh.
set -u
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/.." && pwd)
cd "$root"
arch=${1:-aarch64}
reqs=${2:-4000}
par=${3:-32}
case "$arch" in
    aarch64) nick=arm64;  plat=linux/arm64 ;;
    x86_64)  nick=x86_64; plat=linux/amd64 ;;
    *) echo "tests/frankenphp.sh: unknown arch: $arch" >&2; exit 2 ;;
esac
bin=build/mc-php-linux-$nick
[ -f "$bin" ] || { echo "tests/frankenphp.sh: no $bin" >&2; exit 2; }
D=tests/ext/zts
name=mcphp-fp-$$
fail=0
say() { printf '  %s\n' "$*"; }
bad() { printf '  FAIL %s\n' "$*"; fail=1; }
# the module's files are written by a container's root: removed by one
clean() {
    docker rm -f "$name" >/dev/null 2>&1
    docker run --rm --platform "$plat" -v "$root:$root" -w "$root" php:8.5-zts-alpine rm -rf "$D/build" "$D/.mcphp-test-zts.toml" "$D/out" >/dev/null 2>&1
}
trap clean EXIT
clean

echo "== a ZTS module under FrankenPHP, linux/$arch =="
sed -e 's|^entry = .*|entry = "zts.php"|' -e 's|^out = .*|out = "build/zts.so"|' \
    -e 's/^thread_safety = .*/thread_safety = "zts"/' examples/hello/mcphp.linux.toml > "$D/.mcphp-test-zts.toml"
if ! docker run --rm --platform "$plat" -v "$root:$root" -w "$root" php:8.5-zts-alpine sh -c \
    "apk add --no-cache lld >/dev/null 2>&1; $bin build $D --config $D/.mcphp-test-zts.toml" > /tmp/fp.build.$$ 2>&1; then
    bad "the build:"; sed 's/^/      /' /tmp/fp.build.$$; rm -f /tmp/fp.build.$$; exit 1
fi
rm -f /tmp/fp.build.$$
say "built: $(wc -c < $D/build/zts.so | tr -d ' ') bytes"

threads=8
docker run -d --name "$name" --platform "$plat" -v "$root:$root" \
    -e MCPHP_ZTS_READONLY=1 -e MCPHP_FP_THREADS=$threads -e MCPHP_FP_ROOT="$root/$D" \
    dunglas/frankenphp:php8.5-alpine sh -c \
    "echo 'extension=$root/$D/build/zts.so' > /usr/local/etc/php/conf.d/zz-mcphp.ini; exec frankenphp run --config $root/$D/Caddyfile" >/dev/null
# up when it answers
up=0
i=0
while [ $i -lt 60 ]; do
    if docker exec "$name" curl -fs "http://127.0.0.1:8080/?n=0" > /dev/null 2>&1; then up=1; break; fi
    sleep 1; i=$((i + 1))
done
if [ "$up" != 1 ]; then bad "FrankenPHP did not answer:"; docker logs "$name" 2>&1 | tail -20 | sed 's/^/      /'; exit 1; fi
say "php: $(docker exec "$name" php -r 'echo PHP_VERSION, " ", PHP_ZTS ? "ZTS" : "NTS";'), FrankenPHP with $threads php threads, MCPHP_ZTS_READONLY=1"

rss() { docker exec "$name" sh -c 'grep VmRSS /proc/1/status' | awk '{print $2}'; }
# LOAD N P TAG: N requests, P at once, n = k % 50; every answer kept
load() {
    docker exec "$name" sh -c "seq 1 $1 | awk '{print \$1 % 50}' | xargs -P $2 -I{} curl -fs 'http://127.0.0.1:8080/?n={}'" > "/tmp/fp.$3.$$" 2>/dev/null
}
load 400 $par warm
r0=$(rss)
load "$reqs" "$par" run
r1=$(rss)

# the formula: n|1|1+n|3|1|1|7|<s>|2n|n|n+1000|thread|3n
check() {
    awk -F'|' '
    function s(n,   c) { c = sprintf("%c", 97 + n % 26); return c c c ":{\"n\":" n "}!" (n % 2 ? "odd " n : "even") }
    NF != 13 { bad++; if (shown++ < 3) print "      got  " $0 > "/dev/stderr"; next }
    {
        n = $1
        want = n "|1|" (1 + n) "|3|1|1|7|" s(n) "|" (2 * n) "|" n "|" (n + 1000) "|" (3 * n)
        got = $1; for (i = 2; i <= 11; i++) got = got "|" $i; got = got "|" $13
        if (got != want) { bad++; if (shown++ < 3) print "      want " want "\n      got  " got > "/dev/stderr" }
        ok++; t[$12] = 1
    }
    END { nt = 0; for (k in t) nt++; print ok + 0, bad + 0, nt }' "$1"
}
set -- $(check "/tmp/fp.run.$$")
ok=$1; wrong=$2; nthreads=$3
lines=$(wc -l < "/tmp/fp.run.$$" | tr -d ' ')
if [ "$lines" = "$reqs" ] && [ "$wrong" = 0 ]; then
    say "$reqs requests, $par at a time: every answer the formula's"
else
    bad "$lines answers of $reqs, $wrong wrong"
    docker logs "$name" 2>&1 | tail -10 | sed 's/^/      /'
fi
if [ "$nthreads" -ge 2 ]; then say "the answers came from $nthreads php threads"
else bad "the answers came from $nthreads php thread(s): no concurrency was measured"; fi
grow=$(( (r1 - r0) / 1024 ))
if [ "$grow" -lt 32 ]; then say "resident memory: ${r0} KiB after the warm-up, ${r1} KiB after $reqs more requests (+${grow} MiB)"
else bad "resident memory grew ${grow} MiB over $reqs requests (${r0} -> ${r1} KiB)"; fi
if docker logs "$name" 2>&1 | grep -qi "segmentation\|fatal\|signal"; then
    bad "FrankenPHP logged a fault:"; docker logs "$name" 2>&1 | grep -i "segmentation\|fatal\|signal" | head -5 | sed 's/^/      /'
fi
rm -f /tmp/fp.warm.$$ /tmp/fp.run.$$
[ "$fail" = 0 ] || { echo "  frankenphp: something failed"; exit 1; }
echo "  frankenphp: a ZTS module under $threads php threads, every answer its own request's"

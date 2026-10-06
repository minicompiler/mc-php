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
#   * with MCPHP_ZTS_EGX_WRONG=1 every php thread starts from a WRONG offset
#     of EG(exception), and each measures its own at its first call: the
#     warm-up's requests -- every thread's first ones, 32 at a time -- must
#     all see an exception php's engine throws, as the later ones must;
#   * FrankenPHP's resident memory after the whole load is within a bound of
#     what it was after a warm-up: no leak across requests.
#   * threads step 3b: threads.php starts two php callables on threads of
#     their own per request (opcache on, FrankenPHP's default), from every
#     php thread at once -- every answer the formula's, memory bounded -- and
#     with opcache off the same page is refused, by name.
#   * threads step 4: sync.php makes a mutex and an atomic per request, from
#     every php thread at once -- every count exact, the table's slots reused
#     across requests, and an atomic made at MINIT counting all of them.
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
    -e MCPHP_ZTS_READONLY=1 -e MCPHP_ZTS_EGX_WRONG=1 -e MCPHP_FP_THREADS=$threads -e MCPHP_FP_ROOT="$root/$D" \
    dunglas/frankenphp:php8.5-alpine sh -c \
    "echo 'extension=$root/$D/build/zts.so' > /usr/local/etc/php/conf.d/zz-mcphp.ini; exec frankenphp run --config $root/$D/Caddyfile" >/dev/null
# up when it answers
up=0
i=0
while [ $i -lt 60 ]; do
    if docker exec "$name" curl -fs --max-time 10 "http://127.0.0.1:8080/up.php" > /dev/null 2>&1; then up=1; break; fi
    sleep 1; i=$((i + 1))
done
if [ "$up" != 1 ]; then bad "FrankenPHP did not answer:"; docker logs "$name" 2>&1 | tail -20 | sed 's/^/      /'; exit 1; fi
say "php: $(docker exec "$name" php -r 'echo PHP_VERSION, " ", PHP_ZTS ? "ZTS" : "NTS";'), FrankenPHP with $threads php threads, MCPHP_ZTS_READONLY=1 MCPHP_ZTS_EGX_WRONG=1"

rss() { docker exec "$name" sh -c 'grep VmRSS /proc/1/status' | awk '{print $2}'; }
# LOAD N P TAG: N requests, P at once, n = k % 50; every answer kept
load() {
    docker exec "$name" sh -c "seq 1 $1 | awk '{print \$1 % 50}' | xargs -P $2 -I{} curl -fs --max-time 30 'http://127.0.0.1:8080/?n={}'" > "/tmp/fp.$3.$$" 2>/dev/null
}
load 400 $par warm
r0=$(rss)
load "$reqs" "$par" run
r1=$(rss)

# the formula: n|1|1+n|3|1|1|77|<s>|2n|n|n+1000|b<n>:<strrev(z<n>)>|4n+1|thread|3n
check() {
    awk -F'|' '
    function rv(x,   i, o) { o = ""; for (i = length(x); i > 0; i--) o = o substr(x, i, 1); return o }
    function s(n,   c) { c = sprintf("%c", 97 + n % 26); return c c c ":{\"n\":" n "}!" (n % 2 ? "odd " n : "even") }
    NF != 15 { bad++; if (shown++ < 3) print "      got  " $0 > "/dev/stderr"; next }
    {
        n = $1
        want = n "|1|" (1 + n) "|3|1|1|77|" s(n) "|" (2 * n) "|" n "|" (n + 1000) "|b" n ":" rv("z" n) "|" (4 * n + 1) "|" (3 * n)
        got = $1; for (i = 2; i <= 13; i++) got = got "|" $i; got = got "|" $15
        if (got != want) { bad++; if (shown++ < 3) print "      want " want "\n      got  " got > "/dev/stderr" }
        ok++; t[$14] = 1
    }
    END { nt = 0; for (k in t) nt++; print ok + 0, bad + 0, nt }' "$1"
}
set -- $(check "/tmp/fp.warm.$$")
wlines=$(wc -l < "/tmp/fp.warm.$$" | tr -d ' ')
if [ "$wlines" = 400 ] && [ "$2" = 0 ]; then
    say "the warm-up, every php thread's first requests at once from a wrong EG(exception) offset: 400 answers, every one the formula's, from $3 php threads"
else
    bad "the warm-up: $wlines answers of 400, $2 wrong"
fi
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
# threads step 3b: php callables on threads of their own, two per request,
# from every php thread at once (opcache is on: FrankenPHP's default). The
# answer: "w<n>;" the first worker echoed, then 3n, then [n+1, "q" x (n+1)%5].
docker exec "$name" sh -c "seq 1 $reqs | awk '{print \$1 % 50}' | xargs -P $par -I{} curl -fs --max-time 30 'http://127.0.0.1:8080/threads.php?n={}'" > "/tmp/fp.thr.$$" 2>/dev/null
set -- $(awk '
    function q(k,   o, i) { o = ""; for (i = 0; i < k; i++) o = o "q"; return o }
    {
        if (!match($0, /^w[0-9]+;/)) { bad++; if (shown++ < 3) print "      got  " $0 > "/dev/stderr"; next }
        n = substr($0, 2, RLENGTH - 2) + 0
        want = "w" n ";|" (3 * n) "|[" (n + 1) ",\"" q((n + 1) % 5) "\"]"
        if ($0 != want) { bad++; if (shown++ < 3) print "      want " want "\n      got  " $0 > "/dev/stderr" }
        ok++
    }
    END { print ok + 0, bad + 0 }' "/tmp/fp.thr.$$")
tl=$(wc -l < "/tmp/fp.thr.$$" | tr -d ' ')
if [ "$tl" = "$reqs" ] && [ "$2" = 0 ]; then
    say "php callables on threads: $reqs requests, $par at a time, two php workers each, every answer the formula's (the request's own code, a worker's echo in the response)"
else
    bad "php callables on threads: $tl answers of $reqs, $2 wrong"
    docker logs "$name" 2>&1 | tail -10 | sed 's/^/      /'
fi
# threads step 4: native sync under the same load -- every answer n|n+2 (two
# adds under a request's mutex, one from a compiled thread), the handles'
# slots reused (a request's objects are freed at its end, so the largest
# index stays small), and the atomic made at MINIT counting every request
docker exec "$name" sh -c "seq 1 $reqs | awk '{print \$1 % 50}' | xargs -P $par -I{} curl -fs --max-time 30 'http://127.0.0.1:8080/sync.php?n={}'" > "/tmp/fp.sy.$$" 2>/dev/null
set -- $(awk -F'|' '{ if (NF != 3 || $2 != $1 + 2) { bad++; if (shown++ < 3) print "      got  " $0 > "/dev/stderr" } if ($3 + 0 > mx) mx = $3 + 0; ok++ }
    END { print ok + 0, bad + 0, mx + 0 }' "/tmp/fp.sy.$$")
hits=$(docker exec "$name" curl -fs --max-time 10 "http://127.0.0.1:8080/sync.php?hits=1" 2>/dev/null)
if [ "$1" = "$reqs" ] && [ "$2" = 0 ] && [ "$3" -lt 40 ] && [ "$hits" = "$reqs" ]; then
    say "native sync: $reqs requests, $par at a time, a mutex and an atomic each, every answer exact; largest handle index $3 (slots reused), the MINIT atomic counted $hits"
else
    bad "native sync: $1 answers of $reqs, $2 wrong, largest index $3, the MINIT atomic counted '$hits'"
fi
rm -f "/tmp/fp.sy.$$"
# step 6b: a compiled worker drives the event loop inside a request -- a fiber
# awaits a timer, another a non-blocking pipe read -- from every php thread at
# once. Every answer is n+7 (the worker's result), and at the worker's reap the
# loop is torn down and every fiber stack unmapped (the memory bound below is
# what proves nothing leaks).
docker exec "$name" sh -c "seq 1 $reqs | awk '{print \$1 % 50}' | xargs -P $par -I{} curl -fs --max-time 30 'http://127.0.0.1:8080/awio.php?n={}'" > "/tmp/fp.aw.$$" 2>/dev/null
# request i (1..reqs) asks n = i % 50 and the worker answers n+7, so the sorted
# responses must EQUAL the sorted expected values -- not merely "every response
# is some int >= 7" (which 4000 responses of "7" would satisfy while n+7 is broken)
seq 1 "$reqs" | awk '{ print ($1 % 50) + 7 }' | sort -n > "/tmp/fp.awx.$$"
sort -n "/tmp/fp.aw.$$" > "/tmp/fp.aws.$$"
awl=$(wc -l < "/tmp/fp.aw.$$" | tr -d ' ')
if [ "$awl" = "$reqs" ] && cmp -s "/tmp/fp.awx.$$" "/tmp/fp.aws.$$"; then
    say "step 6b: a compiled worker drives the loop (timer + pipe read): $reqs requests, $par at a time, every answer its own n+7 (multiset exact)"
else
    bad "step 6b await_io: $awl answers of $reqs, response multiset mismatch"
    diff "/tmp/fp.awx.$$" "/tmp/fp.aws.$$" | sed -n '1,6p' | sed 's/^/      /'
    docker logs "$name" 2>&1 | tail -10 | sed 's/^/      /'
fi
rm -f "/tmp/fp.aw.$$" "/tmp/fp.awx.$$" "/tmp/fp.aws.$$"
r2=$(rss)
grow2=$(( (r2 - r1) / 1024 ))
if [ "$grow2" -lt 64 ]; then say "resident memory after them: ${r2} KiB (+${grow2} MiB)"
else bad "resident memory grew ${grow2} MiB over the php-callable requests (${r1} -> ${r2} KiB)"; fi
rm -f "/tmp/fp.thr.$$"
if docker logs "$name" 2>&1 | grep -qi "segmentation\|fatal\|signal"; then
    bad "FrankenPHP logged a fault:"; docker logs "$name" 2>&1 | grep -i "segmentation\|fatal\|signal" | head -5 | sed 's/^/      /'
fi
rm -f /tmp/fp.warm.$$ /tmp/fp.run.$$
# and the same page with opcache off: the start is refused, by name
docker rm -f "$name" >/dev/null 2>&1
docker run -d --name "$name" --platform "$plat" -v "$root:$root" \
    -e MCPHP_FP_THREADS=$threads -e MCPHP_FP_ROOT="$root/$D" \
    dunglas/frankenphp:php8.5-alpine sh -c \
    "printf 'extension=$root/$D/build/zts.so\nopcache.enable=0\n' > /usr/local/etc/php/conf.d/zz-mcphp.ini; exec frankenphp run --config $root/$D/Caddyfile" >/dev/null
i=0
off=
while [ $i -lt 60 ]; do
    off=$(docker exec "$name" curl -fs --max-time 10 "http://127.0.0.1:8080/threads.php?n=4" 2>/dev/null) && break
    sleep 1; i=$((i + 1))
done
want="E:mc-php: a php callable runs on another thread only when opcache caches the code it can reach: enable opcache (opcache.enable=1, and opcache.enable_cli=1 on the command line)"
if [ "$off" = "$want" ]; then say "php callables on threads, opcache off: refused by name"
else bad "php callables on threads, opcache off: got \"$off\""; fi
[ "$fail" = 0 ] || { echo "  frankenphp: something failed"; exit 1; }
echo "  frankenphp: a ZTS module under $threads php threads, every answer its own request's"

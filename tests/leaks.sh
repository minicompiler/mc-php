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
#   (a static and a global), whose references live until RSHUTDOWN;
#   examples/two-extensions (check.php, alone.php, bench.php) and a call
#   through php's function table with strings and exceptions both ways.
# A module built for this php has to say so: [php].debug = true and a build
# id ending ",debug", or the loader refuses it by name.
#
# ZTS=1 runs the THREAD modules against a thread-safe debug php instead (the
# image mc-php-phpdbg-zts, --enable-zts): the compiled threads and the thread
# API as above, and php callables on threads of their own (tests/ext.sh step
# 20c, threads step 3b) with opcache on -- a worker is a php request of its
# own, and the debug allocator reports each thread's request when it ends.
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
zts=${ZTS:-0}
img=mc-php-phpdbg-$nick
base=php:8.5-alpine
cfz=
if [ "$zts" = 1 ]; then img=mc-php-phpdbg-zts-$nick; base=php:8.5-zts-alpine; cfz=--enable-zts; fi
if ! docker image inspect "$img" > /dev/null 2>&1; then
    echo "== building $img (php 8.5, --enable-debug $cfz) =="
    printf '%s\n' \
        "FROM $base" \
        'RUN apk add --no-cache $PHPIZE_DEPS bison re2c linux-headers lld \' \
        ' && docker-php-source extract && cd /usr/src/php \' \
        " && ./configure --prefix=/opt/phpdbg --enable-debug $cfz --disable-all --disable-cgi --disable-phpdbg --without-pear > /dev/null \\" \
        ' && make -j4 > /dev/null && make install > /dev/null && /opt/phpdbg/bin/php -v' \
        | docker build --platform "$plat" -t "$img" - || exit 2
fi

exec docker run --rm --platform "$plat" -v "$root:$root" -w "$root" -e BIN="$bin" -e ZTS="$zts" "$img" sh -c '
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
tsv=nts; [ "$ZTS" = 1 ] && tsv=zts
dbg() { sed "s/^build_id = .*/build_id = \"$bid\"/; s/^debug = .*/debug = true/; s/^api = .*/api = $api/; s/^thread_safety = .*/thread_safety = \"$tsv\"/" "$1"; }

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

# the THREAD modules only on a ZTS php (ZTS=1, the header says why)
if [ "$ZTS" != 1 ]; then
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
cp -R examples/two-extensions "$t/two"
rm -rf "$t/two/build"
dbg examples/two-extensions/extA.linux.toml > "$t/two/dbgA.toml"
dbg examples/two-extensions/extB.linux.toml > "$t/two/dbgB.toml"
if "$BIN" build "$t/two" --config "$t/two/dbgA.toml" > "$t/b.out" 2>&1 &&
   "$BIN" build "$t/two" --config "$t/two/dbgB.toml" >> "$t/b.out" 2>&1; then
    a=$t/two/build/extA.so; b=$t/two/build/extB.so
    leakfree "two-extensions check.php" -d extension="$a" -d extension="$b" "$t/two/check.php"
    leakfree "two-extensions alone.php (an undefined function, twice)" -d extension="$b" "$t/two/alone.php"
    leakfree "two-extensions bench.php" -d extension="$a" -d extension="$b" "$t/two/bench.php"
else
    bad "two-extensions: it would not build"; sed "s/^/      /" "$t/b.out"
fi

# a call through the php function table with strings both ways and an
# exception the callee throws, caught in the module and uncaught across it
# (tests/ext.sh step 14 is the differential of the same road)
mkdir -p "$t/ft"
cat > "$t/ft/r.php" <<"EOF"
<?php
function ft_str(string $s): string { return cb_str($s) . "|" . cb_str($s . "x"); }
function ft_catch(int $n): string {
    try { return "no " . cb_throw($n); }
    catch (InvalidArgumentException $e) { return "caught " . $e->getMessage() . " " . $e->getCode(); }
}
function ft_uncaught(int $n): int { return cb_throw($n); }
EOF
cat > "$t/ft/run.php" <<"EOF"
<?php
function cb_str(string $s): string { return strtoupper($s) . str_repeat("-", 40); }
function cb_throw(int $n) { throw new InvalidArgumentException("bad $n", 40 + $n); }
for ($k = 0; $k < 200; $k++) {
    $s = ft_str("ab$k") . ft_catch($k);
    try { ft_uncaught($k); } catch (InvalidArgumentException $e) { $s .= $e->getMessage(); }
}
echo $s, "\n";
EOF
sed "s|^entry = .*|entry = \"r.php\"|; s|^out = .*|out = \"build/r.so\"|" examples/hello/mcphp.linux.toml | dbg /dev/stdin > "$t/ft/r.toml"
if "$BIN" build "$t/ft" --config "$t/ft/r.toml" > "$t/f.out" 2>&1; then
    leakfree "a call through the function table: strings, a caught and an uncaught exception" -d extension="$t/ft/build/r.so" "$t/ft/run.php"
else
    bad "the function-table calls: it would not build"; sed "s/^/      /" "$t/f.out"
fi
# php arrays and objects inside the module (the module of tests/ext.sh step 17):
# every reference a proxy or a copy took is given back when the call ends,
# and an array through the function table both ways
mkdir -p "$t/val"
cp tests/ext/values/values.php "$t/val/r.php"
{ cat tests/ext/values/check.php
  printf "%s\n" "function cb_twice(\$a) { return [\$a, \$a]; }" \
    "for (\$k = 0; \$k < 300; \$k++) { xa\\wrap(new M); xa\\keys([\$k => [\$k], \"s\" => \"v\$k\"]); xa\\prop(new M); xa\\va(\",\", \$k, \"x\"); xa\\unser(xa\\ser([\$k, [\"x\" => \$k]])); }"
} > "$t/val/run.php"
sed -i "s#__DIR__ . \x27/values.php\x27#__DIR__ . \x27/r.php\x27#" "$t/val/run.php"
sed "s|^entry = .*|entry = \"r.php\"|; s|^out = .*|out = \"build/r.so\"|" examples/hello/mcphp.linux.toml | dbg /dev/stdin > "$t/val/r.toml"
if "$BIN" build "$t/val" --config "$t/val/r.toml" > "$t/v.out" 2>&1; then
    leakfree "arrays, objects and a callable across the boundary (tests/ext/values), 300 rounds" -d extension="$t/val/build/r.so" "$t/val/run.php"
else
    bad "the values module: it would not build"; sed "s/^/      /" "$t/v.out"
fi
# a module that publishes a class: engine objects the module makes and php
# makes, their properties and methods, 300 rounds
mkdir -p "$t/cls"
cp tests/ext/classes/classes.php "$t/cls/r.php"
{ cat tests/ext/classes/check.php
  printf "%s\n" "for (\$k = 0; \$k < 300; \$k++) { \$b = pc\\make(\$k); \$b->add(1); pc\\bump(\$b); \$c = new pc\\Box(\$k, \"s\$k\"); \$c->describe(); }"
} > "$t/cls/run.php"
sed -i "s#__DIR__ . \x27/classes.php\x27#__DIR__ . \x27/r.php\x27#" "$t/cls/run.php"
sed "s|^entry = .*|entry = \"r.php\"|; s|^out = .*|out = \"build/r.so\"|" examples/hello/mcphp.linux.toml | dbg /dev/stdin > "$t/cls/r.toml"
if "$BIN" build "$t/cls" --config "$t/cls/r.toml" > "$t/c.out" 2>&1; then
    leakfree "a published class, made by the module and by php (tests/ext/classes), 300 rounds" -d extension="$t/cls/build/r.so" "$t/cls/run.php"
else
    bad "the classes module: it would not build"; sed "s/^/      /" "$t/c.out"
fi
# a module that calls php callables and hands throwables back (the module of
# tests/ext.sh step 19), 300 rounds -- a throwable class the engine does not
# know among them, which crosses by a fallback lookup
mkdir -p "$t/cal"
cp tests/ext/callables/callables.php "$t/cal/r.php"
{ cat tests/ext/callables/check.php
  printf "%s\n" "for (\$k = 0; \$k < 300; \$k++) { pk\\call(\"strrev\", \"s\$k\"); pk\\call([new Svc, \"shout\"], \"x\"); pk\\call(fn(\$a) => \$a + 1, \$k); pk\\caught(function () { throw new LogicException(\"lx\"); }); pk\\keep(); pk\\wrapped(fn() => intdiv(1, 0)); try { pk\\callm(\"nope\"); } catch (Error \$x) {} pk\\oops(); try { pk\\thrown(); } catch (Exception \$x) {} }"
} > "$t/cal/run.php"
sed -i "s#__DIR__ . \x27/callables.php\x27#__DIR__ . \x27/r.php\x27#" "$t/cal/run.php"
sed "s|^entry = .*|entry = \"r.php\"|; s|^out = .*|out = \"build/r.so\"|" examples/hello/mcphp.linux.toml | dbg /dev/stdin > "$t/cal/r.toml"
if "$BIN" build "$t/cal" --config "$t/cal/r.toml" > "$t/k.out" 2>&1; then
    leakfree "php callables called by the module, throwables both ways (tests/ext/callables), 300 rounds" -d extension="$t/cal/build/r.so" "$t/cal/run.php"
else
    bad "the callables module: it would not build"; sed "s/^/      /" "$t/k.out"
fi
fi
# compiled functions on several OS threads at once (the module of tests/ext.sh
# step 20): each thread bumps an arena of its own, and nothing php allocates may be
# left by it, 30 rounds of 4 threads
mkdir -p "$t/thr"
cp tests/ext/threads/threads.php "$t/thr/r.php"
{ cat tests/ext/threads/check.php
  printf "%s\n" "for (\$k = 0; \$k < 30; \$k++) { th\\run(4, 50); }"
} > "$t/thr/run.php"
sed "s|^entry = .*|entry = \"r.php\"|; s|^out = .*|out = \"build/r.so\"|" examples/hello/mcphp.linux.toml | dbg /dev/stdin > "$t/thr/r.toml"
if "$BIN" build "$t/thr" --config "$t/thr/r.toml" > "$t/th.out" 2>&1; then
    leakfree "compiled functions on OS threads (tests/ext/threads), 30 rounds of 4" -d extension="$t/thr/build/r.so" "$t/thr/run.php"
    # the thread API (tests/ext.sh step 20b): shared mode defers every free of
    # a string to the end of the request, which must still leave nothing;
    # native sync (step 4) in every round, its refusals once
    { cat tests/ext/threads/api.php
      printf "%s\n" "for (\$k = 0; \$k < 30; \$k++) { th\\api(4, 50); th\\keep(4); th\\rethrow(); th\\sy_count(4, 100); }"
    } > "$t/thr/api.php"
    leakfree "the thread API (tests/ext/threads/api.php), 30 rounds" -d extension="$t/thr/build/r.so" "$t/thr/api.php"
    # step 6b: a compiled worker drives the event loop inside a request -- a
    # fiber awaits a timer, another a non-blocking pipe read -- and at the
    # worker reap the loop is torn down and every fiber stack unmapped. 20
    # rounds of 4 workers each; nothing of the loop may be left allocated.
    printf "%s\n" "<?php for (\$k = 0; \$k < 20; \$k++) th\\await_io(4);" > "$t/thr/awio.php"
    leakfree "step 6b: a compiled worker drives the loop (timer + pipe read), 20 rounds of 4" -d extension="$t/thr/build/r.so" "$t/thr/awio.php"
    # php callables on threads of their own (tests/ext.sh step 20c): results
    # a string, an array and an object, copied out of the heap of each worker
    # before its request ends, a fatal error and exit() in a worker, and a
    # detached one -- 10 rounds, opcache on
    if [ "$ZTS" = 1 ]; then
        { cat tests/ext/threads/php.php
          printf "%s\n" "for (\$k = 0; \$k < 10; \$k++) { th\\prun1(fn(int \$n) => str_repeat(\"ab\", \$n), \$k); th\\prun1(fn(int \$n) => [\$n, [\"k\" => \"v\$n\"]], \$k); th\\prun1(fn(\$p) => [\$p, new Pt(\$k, 1)], \$o); err(fn() => th\\prun0(function () { throw new DomainException(\"d\"); })); }"
        } > "$t/thr/php.php"
        leakfree "php callables on threads (tests/ext/threads/php.php), opcache on, 10 more rounds" -d opcache.enable_cli=1 -d extension="$t/thr/build/r.so" "$t/thr/php.php"
    fi
else
    bad "the threads module: it would not build"; sed "s/^/      /" "$t/th.out"
fi
[ "$fail" = 0 ] || { echo "  leaks: something failed"; exit 1; }
echo "  leaks: every request ended with nothing of the module still allocated"
'

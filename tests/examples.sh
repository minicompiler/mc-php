#!/bin/sh
# The example gates: every directory under examples/ but hello (tests/ext.sh
# grades that one), each compiled and compared with something php produced.
#
#     sh tests/examples.sh               # on the host it is on
#     BIN=/path/to/mc-php MC=/path/to/mc sh tests/examples.sh
#     LINUX=1 sh tests/examples.sh       # the mcphp.linux.toml files
#     WINDOWS=1 sh tests/examples.sh     # the mcphp.windows.toml files
#
#   decimal          PHP compiled by mc-php. The DIFFERENTIAL (check.php with
#                    the module, then with decimal.php required, byte for byte
#                    on both streams and the exit), bcmath as a second oracle
#                    where the host php has it, and the bench row against the
#                    interpreted source -- whose ratio is printed, not gated.
#   two-extensions   PHP compiled by mc-php: extA and extB, where B calls A
#                    through php's function table. The differential in BOTH
#                    load orders and B alone, the C twins graded the same way,
#                    and the bench row against the interpreted source and the
#                    twins -- printed, not gated. Then hello and decimal, two
#                    mc-php extensions that do not call each other, together.
#   awaitable        hand-written mc: check.php against check.expect, and the
#                    demo; then awaitable.src.php's first refusal, pinned.
#
# The HAND-WRITTEN halves are compiled by plain mc ($MC), not by mc-php: every
# source mc-php compiles gets the php runtime pushed into it, which is right
# for PHP and wrong for a file that is its own module. They are POSIX only
# (dlsym, pthreads, fork) and skip on Windows with the reason printed, and
# they skip -- again saying why -- where there is no mc beside the compiler.
#
# A PINNED refusal is the build each hand-written example is waiting for: it
# must fail, with exactly the recorded message. The day the compiler can
# build it, this fails and says so, and the hand-written file retires.
#
# Exits 0 only when every step that ran passed.
set -u
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/.." && pwd)
cd "$root"
PHP=${PHP:-php}
BIN=${BIN:-build/mc-php}
MC=${MC:-mc}
host=macos; sx=so; suf=
[ "${LINUX:-0}" = 1 ] && { host=linux; suf=.linux; }
[ "${WINDOWS:-0}" = 1 ] && { host=windows; suf=.windows; sx=dll; }
fail=0
# the form a NATIVE php.exe reads: MSYS's /d/a/... means nothing to it
rootn=$(cygpath -m "$root" 2>/dev/null || echo "$root")

[ -x "$BIN" ] || { echo "  no $BIN"; exit 1; }
. "$here/tmp.sh"
mcphp_tmp_init mcphp-examples
tmp=$MCPHP_TMP
trap 'rm -rf "$tmp"' EXIT
trap 'exit 130' INT

say()  { printf '  %s\n' "$*"; }
bad()  { printf '  FAIL %s\n' "$*"; fail=1; }
skip() { printf '  SKIPPED %s\n' "$*"; }

# build EX CFG ART: mc-php build, the artefact removed first so a failed
# build is never graded on an old one (tests/ext.sh, the reviewer of #15).
build() {
    rm -f "$1/build/$3"
    if "$BIN" build "$1" --config "$2" > "$tmp/build.out" 2>&1 && [ -f "$1/build/$3" ]; then
        return 0
    fi
    bad "mc-php build $2:"; sed 's/^/      /' "$tmp/build.out"
    return 1
}

# differential NAME SCRIPT ARGS...: run php twice on the same script -- the first run with
# the extension arguments given, the second with none -- and require the same
# bytes on each stream and the same exit.
differential() {
    name=$1; script=$2; shift 2
    "$PHP" "$@" "$script" > "$tmp/n.out" 2> "$tmp/n.err"; nrc=$?
    "$PHP" "$script"      > "$tmp/i.out" 2> "$tmp/i.err"; irc=$?
    ok=1
    cmp -s "$tmp/n.out" "$tmp/i.out" || { ok=0; bad "$name: stdout differs"
        diff -u "$tmp/i.out" "$tmp/n.out" | sed -n '3,20p' | sed 's/^/      /'; }
    cmp -s "$tmp/n.err" "$tmp/i.err" || { ok=0; bad "$name: stderr differs"
        diff -u "$tmp/i.err" "$tmp/n.err" | sed -n '3,20p' | sed 's/^/      /'; }
    [ "$nrc" = "$irc" ] || { ok=0; bad "$name: exit $nrc native, $irc interpreted"; }
    [ "$ok" = 1 ] && say "$name: $(wc -l < "$tmp/n.out" | tr -d ' ') lines, byte for byte php's own, exit $nrc"
}

# pin EX WANT: the build this example waits for is refused, and its last line
# is exactly "EX/WANT" -- equality, not a substring, so a changed suffix or a
# second message on the line is a moved refusal (the reviewer of #18).
pin() {
    "$BIN" build "$1" --config "$1/mcphp.toml" > "$tmp/pin.out" 2>&1; rc=$?
    got=$(tail -1 "$tmp/pin.out" | tr -d '\r')
    if [ "$rc" = 0 ]; then
        bad "$1: the pinned build SUCCEEDED -- the compiler can do it now; retire the hand-written file"
    elif [ "$got" = "$1/$2" ]; then
        say "pinned (exit $rc): $2"
    else
        bad "$1: the pinned refusal moved"; printf '      want %s\n      got  %s\n' "$1/$2" "$got"
    fi
    rm -rf "$1/build"
}

# The hand-written half: the target php's four module-header values, the
# host's dlsym handle, plain mc, and the host's link.
pv() { "$PHP" -i | tr -d '\r' | sed -n "s/^$1 => //p" | head -1; }
api=$(pv 'PHP API'); bid=$(pv 'PHP Extension Build')
zts=0; [ "$(pv 'Thread Safety')" = enabled ] && zts=1
dbg=0; [ "$(pv 'Debug Build')" = yes ] && dbg=1
rtld='0 - 2'; [ "$host" = linux ] && rtld=0
# a C variadic argument: on the stack after eight registers on Apple arm64, in
# the next register everywhere else (examples/awaitable/awaitable.mc)
vdecl='i64 a, i64 b, i64 c, i64 d, i64 e, i64 f, '; vpad='0, 0, 0, 0, 0, 0, '
[ "$host" = linux ] && { vdecl=; vpad=; }
hand_ok() {
    [ "$host" = windows ] && { skip "$1 on Windows: dlsym, pthreads and fork are POSIX, and a DLL publishes only what -export names (README.md)"; return 1; }
    command -v "$MC" >/dev/null 2>&1 || { skip "$1: no mc here ($MC) -- the hand-written files are plain mc, not mc-php input"; return 1; }
    return 0
}
# handbuild SRC OUT: fill the template, compile with mc, link a loadable module
handbuild() {
    sed -e "s/@API@/$api/g; s/@ZTS@/$zts/g; s/@DEBUG@/$dbg/g; s/@BUILDID@/$bid/g; s/@RTLD_DEFAULT@/$rtld/g; s/@VARDECL@/$vdecl/g; s/@VARPAD@/$vpad/g" \
        "$1" > "$tmp/gen.mc"
    rm -f "$2"
    "$MC" "$tmp/gen.mc" -o "$tmp/gen.o" > "$tmp/hb.out" 2>&1 || { bad "mc $1:"; sed 's/^/      /' "$tmp/hb.out"; return 1; }
    if [ "$host" = linux ]; then
        ld.lld -shared -Bsymbolic -o "$2" "$tmp/gen.o" > "$tmp/hb.out" 2>&1
    else
        ld -bundle -undefined dynamic_lookup -arch arm64 -platform_version macos 13.0 13.0 \
           -syslibroot "$(xcrun --show-sdk-path)" -lSystem -o "$2" "$tmp/gen.o" > "$tmp/hb.out" 2>&1
    fi || { bad "link $1:"; sed 's/^/      /' "$tmp/hb.out"; return 1; }
}

# --- decimal: PHP compiled by mc-php ------------------------------------------
echo "  -- decimal"
EX=examples/decimal
dso=$rootn/$EX/build/decimal.$sx
if build "$EX" "$EX/mcphp$suf.toml" "decimal.$sx"; then
    say "built: $(wc -c < "$dso" | tr -d ' ') bytes from $EX/decimal.php"
    differential check.php "$EX/check.php" -d extension="$dso"
    # the _dec_* helpers are module-private (a leading underscore): php sees
    # the six dec_* functions and nothing else
    vis=$("$PHP" -d extension="$dso" -r '$f = get_extension_funcs("decimal"); sort($f); echo implode(" ", $f);' 2>&1 | tr -d '\r')
    if [ "$vis" = "dec_add dec_cmp dec_div dec_mul dec_round dec_sub" ]; then
        say "published: the six dec_* functions and none of the _dec_* helpers"
    else
        bad "published: want the six dec_* functions, got: $vis"
    fi
    if "$PHP" -m | tr -d '\r' | grep -qix bcmath; then
        # the exit AND the exact summary: a weakened oracle that checked less
        # must not pass (the reviewer of #18)
        if "$PHP" -d extension="$dso" "$EX/bccheck.php" > "$tmp/bc.out" 2>&1 &&
           [ "$(tr -d '\r' < "$tmp/bc.out")" = "bcmath agrees: 1219 results, 0 wrong" ]; then
            say "$(tr -d '\r' < "$tmp/bc.out")"
        else
            bad "bccheck.php:"; sed 's/^/      /' "$tmp/bc.out"
        fi
    else
        skip "the bcmath cross-check: this php has no bcmath"
    fi
    # 1 000 000 calls in ONE request: every string a call builds is a Zend
    # block freed when its last reference goes, so php's own usage does not
    # move and its peak moves only as far as a call's temporaries grow with the
    # accumulator's digits (soak.php says why): a kilobyte is allowed, and one
    # leaked string a call would be tens of megabytes. The module used to
    # allocate out of a fixed arena and died near 29 000 calls.
    set -- $("$PHP" -d extension="$dso" "$EX/soak.php" 1000000 2>&1 | tr -d '\r')
    if [ "${2:-}" = 1000000 ] && [ "${4:-}" = 12500000.00 ] \
       && [ $((${8:-99999999} - ${6:-0})) -lt 1024 ] && [ $((${12:-99999999} - ${10:-0})) -lt 1024 ]; then
        say "soak: 1000000 dec_add calls in one request, usage $6 -> $8 bytes, peak ${10} -> ${12}"
    else
        bad "soak.php: want 1000000 calls, 12500000.00, and usage and peak that move under 1 KiB, got: $*"
    fi
    # How many strings a call BUILDS (MCPHP_STATS=1 counts every _emalloc of
    # one, a copy included): 100 calls of each operation on the bench's own
    # kind of arguments. Each is an exact number and a ceiling at once -- a
    # lowering that stopped reading substr() windows in place, answering an
    # empty concatenation side or a one-byte result without a new string, or
    # a chr() without one, moves it up. Before those (main at #22) the counts
    # were 800, 1000, 1300, 200 and 3400. decimal.php is c/decimal.c's
    # algorithm since the same-algorithm rewrite, which moved them: dec_div's
    # long division by repeated subtraction builds a remainder per step where
    # the twin subtracts in its one buffer -- a PHP string is a value, and a
    # helper cannot write into its caller's. decimal-2x moved them down from
    # 700, 700, 800, 300 and 10700: _dec_fmt's answer is one string (src/opt.mc's
    # rope) and `$d . str_repeat('0', n)` one (php_str_catrep); and dec_div's
    # from 10300 to 1300 when _dec_udivmod took the twin's one remainder
    # buffer, compared and subtracted in place; and 400 400 500 200 1200 when
    # _dec_fmt carried the index of its first kept digit, as the twin moves
    # its pointer, instead of a substr() of the rest.
    sb=
    for op in "dec_add('123456.78', '1093.75', 2)" "dec_sub('123456.78', '2682.24', 2)" \
              "dec_mul('123456.78', '0.004375000000', 2)" "dec_cmp('123456.78', '0')" "dec_div('5.25', '1200', 12)"; do
        n=$(MCPHP_STATS=1 "$PHP" -d extension="$dso" -r "for (\$i = 0; \$i < 100; \$i++) $op;" 2>&1 | tr -d '\r' | sed -n 's/.*strings built //p')
        sb="$sb${sb:+ }${n:-?}"
    done
    if [ "$sb" = "400 400 500 200 1200" ]; then
        say "strings: 100 calls of add, sub, mul, cmp, div build $sb strings"
    else
        bad "strings: 100 calls of add, sub, mul, cmp, div built $sb strings (want 400 400 500 200 1200)"
    fi
    # the C twin (c/decimal.c): the same six functions written the ordinary
    # way, graded by the same check.php, and the reference the bench compares
    # against. It needs php-config and a C compiler; the COMPILER needs
    # neither, so without them this says so and the bench has two columns.
    cso=
    CC=${CC:-cc}
    if command -v php-config >/dev/null 2>&1 && command -v "$CC" >/dev/null 2>&1; then
        inc=$(php-config --includes)
        if "$CC" -O2 -bundle -undefined dynamic_lookup -o "$tmp/c-decimal.so" "$EX/c/decimal.c" $inc 2>"$tmp/c.err" ||
           "$CC" -O2 -shared -fPIC -o "$tmp/c-decimal.so" "$EX/c/decimal.c" $inc 2>>"$tmp/c.err"; then
            cso=$tmp/c-decimal.so
            differential "check.php (the C twin)" "$EX/check.php" -d extension="$cso"
        else
            bad "the C twin would not build:"; sed 's/^/      /' "$tmp/c.err"
        fi
    else
        skip "the C twin: no php-config or no $CC here -- the bench has no C column"
    fi
    # the bench row: three rounds, the processes interleaved, minimums
    bi=; bc=; bt=; ai=; ac=
    for r in 1 2 3; do
        set -- $("$PHP" "$EX/bench.php" | tr -d '\r')
        [ "$1" = interpreted ] || { bad "bench.php (interpreted): $*"; break; }
        bi=$(awk -v a="$bi" -v b="$2" 'BEGIN { print (a == "" || b < a) ? b : a }'); shift 2; ai=$*
        set -- $("$PHP" -d extension="$dso" "$EX/bench.php" | tr -d '\r')
        [ "$1" = compiled ] || { bad "bench.php (compiled): $*"; break; }
        bc=$(awk -v a="$bc" -v b="$2" 'BEGIN { print (a == "" || b < a) ? b : a }'); shift 2; ac=$*
        [ "$ai" = "$ac" ] || bad "bench.php: the two answers differ: $ai / $ac"
        if [ -n "$cso" ]; then
            set -- $("$PHP" -d extension="$cso" "$EX/bench.php" c | tr -d '\r')
            [ "$1" = c ] || { bad "bench.php (the C twin): $*"; break; }
            bt=$(awk -v a="$bt" -v b="$2" 'BEGIN { print (a == "" || b < a) ? b : a }'); shift 2
            [ "$ai" = "$*" ] || bad "bench.php: the C twin's answer differs: $*"
        fi
    done
    if [ -n "$bc" ]; then
        row="interpreted $bi ms, compiled $bc ms $(awk -v i="$bi" -v c="$bc" 'BEGIN { printf "(%.2fx)", i / c }')"
        [ -n "$bt" ] && row="$row, C twin $bt ms $(awk -v i="$bi" -v c="$bt" 'BEGIN { printf "(%.2fx)", i / c }')"
        say "bench: $row -- best of nine, three rounds interleaved; not gated"
    fi
fi

# --- two-extensions -------------------------------------------------------------
# Two extensions compiled from PHP, and B calls a function A publishes and
# B's source does not declare: looked up in php's function table when the
# call runs, as php does and as the C twins (c/extA.c, c/extB.c) do.
echo "  -- two-extensions"
EX=examples/two-extensions
aso=$rootn/$EX/build/extA.$sx; bso=$rootn/$EX/build/extB.$sx
if build "$EX" "$EX/extA$suf.toml" "extA.$sx" && build "$EX" "$EX/extB$suf.toml" "extB.$sx"; then
    say "built: extA $(wc -c < "$aso" | tr -d ' ') and extB $(wc -c < "$bso" | tr -d ' ') bytes from $EX/extA.php and extB.php"
    differential "check.php (A then B)" "$EX/check.php" -d extension="$aso" -d extension="$bso"
    differential "check.php (B then A)" "$EX/check.php" -d extension="$bso" -d extension="$aso"
    # B alone: php's own Error, "Call to undefined function a_add()", twice
    # (a failed lookup caches nothing)
    differential "alone.php (B without A)" "$EX/alone.php" -d extension="$bso"
    cao=; cbo=
    CC=${CC:-cc}
    if command -v php-config >/dev/null 2>&1 && command -v "$CC" >/dev/null 2>&1; then
        inc=$(php-config --includes)
        for x in A B; do
            if "$CC" -O2 -bundle -undefined dynamic_lookup -o "$tmp/c-ext$x.so" "$EX/c/ext$x.c" $inc 2>"$tmp/c.err" ||
               "$CC" -O2 -shared -fPIC -o "$tmp/c-ext$x.so" "$EX/c/ext$x.c" $inc 2>>"$tmp/c.err"; then
                :
            else
                bad "the C twin ext$x would not build:"; sed 's/^/      /' "$tmp/c.err"
            fi
        done
        if [ -f "$tmp/c-extA.so" ] && [ -f "$tmp/c-extB.so" ]; then
            cao=$tmp/c-extA.so; cbo=$tmp/c-extB.so
            differential "check.php (the C twins)" "$EX/check.php" -d extension="$cao" -d extension="$cbo"
            differential "alone.php (the C twin of B)" "$EX/alone.php" -d extension="$cbo"
        fi
    else
        skip "the C twins: no php-config or no $CC here -- the bench has no C column"
    fi
    # the bench row: the call through B into A, three rounds, the processes
    # interleaved, minimums; and the same work straight into A beside it
    bi=; bc=; bt=; di=; dc=; dt=; ai=
    for r in 1 2 3; do
        set -- $("$PHP" "$EX/bench.php" | tr -d '\r')
        [ "$1" = interpreted ] || { bad "bench.php (interpreted): $*"; break; }
        bi=$(awk -v a="$bi" -v b="$2" 'BEGIN { print (a == "" || b < a) ? b : a }')
        di=$(awk -v a="$di" -v b="$3" 'BEGIN { print (a == "" || b < a) ? b : a }'); shift 3; ai=$*
        set -- $("$PHP" -d extension="$aso" -d extension="$bso" "$EX/bench.php" | tr -d '\r')
        [ "$1" = compiled ] || { bad "bench.php (compiled): $*"; break; }
        bc=$(awk -v a="$bc" -v b="$2" 'BEGIN { print (a == "" || b < a) ? b : a }')
        dc=$(awk -v a="$dc" -v b="$3" 'BEGIN { print (a == "" || b < a) ? b : a }'); shift 3
        [ "$ai" = "$*" ] || bad "bench.php: the two answers differ: $ai / $*"
        if [ -n "$cao" ]; then
            set -- $("$PHP" -d extension="$cao" -d extension="$cbo" "$EX/bench.php" c | tr -d '\r')
            [ "$1" = c ] || { bad "bench.php (the C twins): $*"; break; }
            bt=$(awk -v a="$bt" -v b="$2" 'BEGIN { print (a == "" || b < a) ? b : a }')
            dt=$(awk -v a="$dt" -v b="$3" 'BEGIN { print (a == "" || b < a) ? b : a }'); shift 3
            [ "$ai" = "$*" ] || bad "bench.php: the C twins' answer differs: $*"
        fi
    done
    if [ -n "$bc" ]; then
        row="through B: interpreted $bi ms, compiled $bc ms $(awk -v i="$bi" -v c="$bc" 'BEGIN { printf "(%.2fx)", i / c }')"
        [ -n "$bt" ] && row="$row, C twins $bt ms $(awk -v i="$bi" -v c="$bt" 'BEGIN { printf "(%.2fx)", i / c }')"
        say "bench: $row -- best of nine, three rounds interleaved; not gated"
        row="straight into A: interpreted $di ms, compiled $dc ms"
        [ -n "$dt" ] && row="$row, C twin $dt ms"
        say "bench: $row"
    fi
fi
# two mc-php extensions that do NOT call each other, in one php: each carries
# the whole runtime, and each must keep using its own.
hso=$rootn/examples/hello/build/hello.$sx
# Built here and not reused: a .so an earlier run left behind may be another
# host's (the checkout is shared with the Linux container).
if build examples/hello "examples/hello/mcphp$suf.toml" "hello.$sx" && [ -f "$dso" ]; then
    for order in "$hso $dso" "$dso $hso"; do
        set -- $order
        got=$("$PHP" -d extension="$1" -d extension="$2" -r \
            'echo hello_greet(dec_add("40", "2.5", 1)), " ", dec_mul(hello_greet("x") === "hi x" ? "3" : "0", "7", 0);' 2>&1)
        if [ "$got" = "hi 42.5 21" ]; then
            say "hello and decimal in one php, $(basename "$1") first: both answer"
        else
            bad "hello and decimal in one php, $(basename "$1") first: want 'hi 42.5 21', got '$got'"
        fi
    done
fi

# --- awaitable -----------------------------------------------------------------
echo "  -- awaitable"
EX=examples/awaitable
if hand_ok "awaitable.mc"; then
    if ! "$PHP" -m | tr -d '\r' | grep -qix curl; then
        skip "awaitable.mc: this php has no curl, and the module resolves libcurl from php's own process"
    elif handbuild "$EX/awaitable.mc" "$tmp/awaitable.$sx"; then
        "$PHP" -d extension="$tmp/awaitable.$sx" "$EX/check.php" > "$tmp/aw.out" 2>&1; awrc=$?
        if [ "$awrc" = 0 ] && cmp -s "$tmp/aw.out" "$EX/check.expect"; then
            say "check.php: $(wc -l < "$tmp/aw.out" | tr -d ' ') lines, every one check.expect's"
        else
            bad "check.php exited $awrc, or differs from $EX/check.expect:"
            diff -u "$EX/check.expect" "$tmp/aw.out" | sed -n '3,24p' | sed 's/^/      /'
        fi
        "$PHP" -d extension="$tmp/awaitable.$sx" "$EX/demo.php" > "$tmp/demo.out" 2>&1; demorc=$?
        if [ "$demorc" = 0 ] && grep -q '^same results: true$' "$tmp/demo.out"; then
            say "demo.php: $(sed -n 2p "$tmp/demo.out" | tr -s ' ')"
        else
            bad "demo.php (exit $demorc):"; sed -n '1,12p' "$tmp/demo.out" | sed 's/^/      /'
        fi
    fi
fi
# the C twin (c/awaitable.c): the same extension written the ordinary way,
# the specification the compiled module is measured against, graded by the
# same check.php against the same check.expect
CC=${CC:-cc}
if [ "$host" = windows ]; then
    skip "the C twin of awaitable on Windows: fork, pipe and pthreads are POSIX (README.md)"
elif command -v php-config >/dev/null 2>&1 && command -v "$CC" >/dev/null 2>&1; then
    inc=$(php-config --includes)
    if "$CC" -O2 -bundle -undefined dynamic_lookup -o "$tmp/c-awaitable.so" "$EX/c/awaitable.c" $inc -lcurl 2>"$tmp/c.err" ||
       "$CC" -O2 -shared -fPIC -o "$tmp/c-awaitable.so" "$EX/c/awaitable.c" $inc -lcurl -lpthread 2>>"$tmp/c.err"; then
        "$PHP" -d extension="$tmp/c-awaitable.so" "$EX/check.php" > "$tmp/awc.out" 2>&1; awcrc=$?
        if [ "$awcrc" = 0 ] && cmp -s "$tmp/awc.out" "$EX/check.expect"; then
            say "check.php (the C twin): $(wc -l < "$tmp/awc.out" | tr -d ' ') lines, every one check.expect's"
        else
            bad "check.php (the C twin) exited $awcrc, or differs from $EX/check.expect:"
            diff -u "$EX/check.expect" "$tmp/awc.out" | sed -n '3,24p' | sed 's/^/      /'
        fi
    else
        bad "the C twin of awaitable would not build:"; sed 's/^/      /' "$tmp/c.err"
    fi
else
    skip "the C twin of awaitable: no php-config or no $CC here"
fi
# The build this example is working toward: awaitable.src.php through mc-php,
# loaded, and check.php run against check.expect. How many of its lines
# already agree -- the leading ones, up to the first that does not -- is the
# example's PROGRESS, recorded here: fewer is a regression, more is a gain to
# record in the same commit, and all of them means the hand-written
# awaitable.mc can retire. Windows refuses #[Extern] by name (src/extern.mc),
# so there the first C declaration's refusal is pinned.
AW_PROGRESS=9
if [ "$host" = windows ]; then
    pin "$EX" "awaitable.src.php:14: mc-php: an #[Extern] function on Windows: the link names no library for it: awaitable\\curl_easy_init"
elif ! "$PHP" -m | tr -d '\r' | grep -qix curl; then
    skip "awaitable.src.php compiled: this php has no curl, and the module resolves libcurl from php's own process"
elif build "$EX" "$EX/mcphp$suf.toml" "awaitable.$sx"; then
    "$PHP" -d extension="$EX/build/awaitable.$sx" "$EX/check.php" > "$tmp/awp.out" 2>&1
    n=$(awk 'NR == FNR { w[FNR] = $0; next } $0 != w[FNR] { exit } { k = FNR } END { print k + 0 }' \
        "$EX/check.expect" "$tmp/awp.out")
    total=$(wc -l < "$EX/check.expect" | tr -d ' ')
    if [ "$n" = "$AW_PROGRESS" ]; then
        say "awaitable.src.php compiled: check.php agrees with check.expect for $n of $total lines"
    else
        bad "awaitable.src.php compiled: check.php agrees for $n of $total lines, the recording says $AW_PROGRESS (record it)"
        diff "$EX/check.expect" "$tmp/awp.out" | sed -n '1,8p' | sed 's/^/      /'
    fi
    rm -rf "$EX/build"
fi

[ "$fail" = 0 ] || { echo "  examples: something failed"; exit 1; }
echo "  examples: green"

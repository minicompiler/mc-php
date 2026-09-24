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
#   two-extensions   (a) hand-written mc: extA and extB loaded into one php in
#                    BOTH orders, differential against extA.php + extB.php,
#                    and B alone; (b) two mc-php extensions -- hello and
#                    decimal -- loaded together; (c) extB.php's refusal, pinned.
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
    # block the call frees, so php's own peak does not move. The module used
    # to allocate out of a fixed arena and died near 29 000 calls.
    set -- $("$PHP" -d extension="$dso" "$EX/soak.php" 1000000 2>&1 | tr -d '\r')
    if [ "${2:-}" = 1000000 ] && [ "${4:-}" = 12500000.00 ] && [ "${10:-x}" = "${12:-y}" ]; then
        say "soak: 1000000 dec_add calls in one request, usage $6 -> $8 bytes, peak ${10} -> ${12}"
    else
        bad "soak.php: want 1000000 calls, 12500000.00 and an unmoved peak, got: $*"
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
echo "  -- two-extensions"
EX=examples/two-extensions
if hand_ok "the hand-written pair"; then
    a=$tmp/extA.$sx; b=$tmp/extB.$sx
    if handbuild "$EX/extA.mc" "$a" && handbuild "$EX/extB.mc" "$b"; then
        differential "check.php (A then B)" "$EX/check.php" -d extension="$a" -d extension="$b"
        differential "check.php (B then A)" "$EX/check.php" -d extension="$b" -d extension="$a"
        got=$("$PHP" -d extension="$b" -r 'echo b_use(2, 3);' 2>&1)
        [ "$got" = -1 ] && say "B alone: b_use answers -1, found nothing to call" \
            || bad "B alone: want -1, got $got"
    fi
fi
# (b) two mc-php extensions in one php: each carries the whole runtime, and
# each must keep using its own.
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
pin "$EX" "extB.php:8: mc-php: a php function mc-php does not have: a_add is not implemented yet (probes/t10/RESULTS.md)"

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
pin "$EX" "awaitable.src.php:7: mc-php: a namespace in an extension source is not implemented yet (probes/t10/RESULTS.md)"

[ "$fail" = 0 ] || { echo "  examples: something failed"; exit 1; }
echo "  examples: green"

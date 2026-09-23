#!/bin/sh
# The extension gate: a .php compiled into a .so that php LOADS, and its
# answers compared with php's own.
#
#     sh tests/ext.sh                    # on the host it is on
#     BIN=/path/to/mc-php sh tests/ext.sh
#     LINUX=1 sh tests/ext.sh            # use examples/hello/mcphp.linux.toml
#
# Six steps, and every one of them is a comparison against something php
# produced rather than against a number written here:
#
#   1  the LAYOUT gate. tests/ext/abi.c prints every offset lib/php_ext.mc
#      names, from the installed php headers, and every `#define` that names
#      one must match. Skipped -- with the reason printed -- where there is no
#      php-config or no C compiler; the COMPILER needs neither, and a gate's
#      oracle is not a dependency of the thing it grades.
#   2  the four [php] values in the project file are the target php's. A
#      committed file goes stale when the target's minor moves, and the answer
#      is to re-measure, never to loosen the comparison.
#   3  the build: mc-php build, and the artefact is a real loadable module.
#   4  the DIFFERENTIAL. examples/hello/check.php is run twice -- once with
#      hello.so loaded, once with hello.php required -- and the two must print
#      the same bytes on each stream and exit the same.
#   5  the wrong-call behaviour, against examples/hello/errors.expect, which
#      tests/ext/refx.c re-measures here wherever it can be built: an
#      extension's function is an INTERNAL function and php does not report a
#      bad call to one the way it reports a bad call to a userland one.
#   6  the REFUSALS. Every signature outside this back end's scope is declined
#      by name at the declaration's own position, never lowered in silence.
#
# Exits 0 only when all of them passed.
set -u
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/.." && pwd)
cd "$root"
PHP=${PHP:-php}
BIN=${BIN:-build/mc-php}
CC=${CC:-cc}
EX=examples/hello
cfg=$EX/mcphp.toml
[ "${LINUX:-0}" = 1 ] && cfg=$EX/mcphp.linux.toml
fail=0

[ -x "$BIN" ] || { echo "  no $BIN"; exit 1; }
. "$here/tmp.sh"
mcphp_tmp_init mcphp-ext
tmp=$MCPHP_TMP
trap 'rm -rf "$tmp"' EXIT
trap 'exit 130' INT

say() { printf '  %s\n' "$*"; }
bad() { printf '  FAIL %s\n' "$*"; fail=1; }

# --- 1. the layout gate ----------------------------------------------------
if command -v php-config >/dev/null 2>&1 && command -v "$CC" >/dev/null 2>&1 \
   && "$CC" -o "$tmp/abi" tests/ext/abi.c $(php-config --includes) 2>"$tmp/cc.err"
then
    "$tmp/abi" > "$tmp/abi.txt"
    n=0; b=0
    while read -r name val; do
        mine=$(sed -n "s/^#define  *$name  *\([0-9][0-9]*\).*/\1/p" lib/php_ext.mc | head -1)
        [ -n "$mine" ] || { bad "layout: lib/php_ext.mc has no $name"; continue; }
        n=$((n + 1))
        [ "$mine" = "$val" ] || bad "layout $name: php_ext.mc says $mine, the header says $val"
    done < "$tmp/abi.txt"
    say "layout: $n offsets and constants, every one the installed php header's"
else
    say "layout: SKIPPED (no php-config or no $CC -- the COMPILER needs neither)"
fi

# --- 2. the project file names the php it is being graded against ----------
pv() { "$PHP" -i | sed -n "s/^$1 => //p" | head -1; }
tv() { sed -n "s/^$1 = *\(.*\)\$/\1/p" "$cfg" | head -1 | tr -d '"'; }
api=$(pv 'PHP API'); bid=$(pv 'PHP Extension Build')
zts=false; [ "$(pv 'Thread Safety')" = enabled ] && zts=true
dbg=false; [ "$(pv 'Debug Build')" = yes ] && dbg=true
for pair in "api:$api" "build_id:$bid" "thread_safety:$zts" "debug:$dbg"; do
    k=${pair%%:*}; want=${pair#*:}
    got=$(tv "$k")
    [ "$got" = "$want" ] || bad "$cfg: php.$k is $got, this php says $want (re-measure: php -i)"
done
say "php: api $api, build $bid, zts $zts, debug $dbg -- and $cfg says so"

# --- 3. the build ----------------------------------------------------------
out=$tmp/hello.so
rm -f "$out"
if "$BIN" build "$EX" --config "$cfg" > "$tmp/build.out" 2>&1; then
    # the artefact is named by [project].out, which is relative to the config
    cp "$EX/build/hello.so" "$out" 2>/dev/null || bad "no $EX/build/hello.so"
else
    bad "mc-php build:"; sed 's/^/      /' "$tmp/build.out"
fi
[ -f "$out" ] || { echo "  (nothing to grade)"; exit 1; }
say "built: $(wc -c < "$out" | tr -d ' ') bytes"

# php refuses a bundle whose header it does not recognise by NAME, and prints
# nothing else; loading it is the only way to know the header is right.
if "$PHP" -d extension="$out" -r 'exit(extension_loaded("hello") ? 0 : 1);' \
        > "$tmp/load.out" 2>&1
then
    say "loaded: extension_loaded(\"hello\") is true"
else
    bad "php would not load it:"; sed 's/^/      /' "$tmp/load.out"
fi

# --- 4. the differential ---------------------------------------------------
# NATIVE: hello.so loaded, so check.php's own `require` is skipped.
# INTERPRETED: no extension, so the same check.php requires hello.php and the
# functions are php's. Same file, same php, same streams.
"$PHP" -d extension="$out" "$EX/check.php" > "$tmp/n.out" 2> "$tmp/n.err"; nrc=$?
"$PHP" "$EX/check.php"                     > "$tmp/i.out" 2> "$tmp/i.err"; irc=$?
ok=1
cmp -s "$tmp/n.out" "$tmp/i.out" || { ok=0; bad "check.php: stdout differs"
    diff -u "$tmp/i.out" "$tmp/n.out" | sed -n '3,20p' | sed 's/^/      /'; }
cmp -s "$tmp/n.err" "$tmp/i.err" || { ok=0; bad "check.php: stderr differs"
    diff -u "$tmp/i.err" "$tmp/n.err" | sed -n '3,20p' | sed 's/^/      /'; }
[ "$nrc" = "$irc" ] || { ok=0; bad "check.php: exit $nrc native, $irc interpreted"; }
[ "$ok" = 1 ] && say "check.php: $(wc -l < "$tmp/n.out" | tr -d ' ') lines, byte for byte php's own, exit $nrc"

# --- 5. the wrong call, against a reference extension ----------------------
if command -v php-config >/dev/null 2>&1 && command -v "$CC" >/dev/null 2>&1 \
   && "$CC" -shared -fPIC -o "$tmp/refx.so" tests/ext/refx.c $(php-config --includes) \
        2>"$tmp/refx.err" \
   || { command -v php-config >/dev/null 2>&1 && command -v "$CC" >/dev/null 2>&1 \
        && "$CC" -bundle -undefined dynamic_lookup -o "$tmp/refx.so" tests/ext/refx.c \
             $(php-config --includes) 2>>"$tmp/refx.err"; }
then
    "$PHP" -d extension="$tmp/refx.so" "$EX/errors.php" > "$tmp/r.out" 2>&1
    if cmp -s "$tmp/r.out" "$EX/errors.expect"; then
        say "errors.expect: still what a C extension of the same signatures says"
    else
        bad "errors.expect is stale -- re-measure it:"
        diff -u "$EX/errors.expect" "$tmp/r.out" | sed -n '3,14p' | sed 's/^/      /'
    fi
else
    say "the C reference: SKIPPED (no php-config or no $CC) -- errors.expect stands"
fi
"$PHP" -d extension="$out" "$EX/errors.php" > "$tmp/e.out" 2>&1
if cmp -s "$tmp/e.out" "$EX/errors.expect"; then
    say "errors.php: $(wc -l < "$tmp/e.out" | tr -d ' ') wrong calls, every message php's own"
else
    bad "errors.php differs from examples/hello/errors.expect:"
    diff -u "$EX/errors.expect" "$tmp/e.out" | sed -n '3,20p' | sed 's/^/      /'
fi

# --- 6. the refusals -------------------------------------------------------
# Out of scope is NAMED, at the declaration's own position. A silent lowering
# here would publish a signature php does not have.
sed 's|^entry = .*|entry = "r.php"|; s|^out = .*|out = "build/r.so"|' "$cfg" > "$tmp/r.toml"
nref=0
refuse() {
    nref=$((nref + 1))
    printf '<?php\ndeclare(strict_types=1);\n%s\n' "$1" > "$tmp/r.php"
    got=$("$BIN" build "$tmp" --config "$tmp/r.toml" 2>&1 | tail -1)
    case $got in
        *"$2"*) ;;
        *) bad "refusal: $1"; printf '      want ...%s...\n      got  %s\n' "$2" "$got" ;;
    esac
}
refuse 'function f(mixed $x): int { return 1; }'     'parameter whose type is not a declared scalar'
refuse 'function f($x): int { return 1; }'           'parameter whose type is not a declared scalar'
refuse 'function f(int $x = 1): int { return $x; }'  'parameter whose type is not a declared scalar'
refuse 'function f(int ...$x): int { return 1; }'    'a variadic parameter in an exported function'
refuse 'function f(int $x): array { return []; }'    'return type is not a declared scalar'
refuse 'function &f(int $x): int { return $x; }'     'a by-reference return in an exported function'
refuse 'namespace aw; function f(): int { return 1; }' 'a namespace in an extension source'
# php HOISTS a global function, so this is ordinary php -- and D4 builds the
# call against a zval signature and widens the declaration to match, which the
# back end cannot export. The refusal has to say THAT and not "not a declared
# scalar", which is what it would otherwise print.
refuse 'function a(int $n): int { return b($n); }
function b(int $n): int { return $n; }' 'called before it is declared'
rm -rf "$tmp/build"
say "refusals: $nref signatures outside the scope, each declined by name"

[ "$fail" = 0 ] || { echo "  ext: something failed"; exit 1; }
echo "  ext: the extension road is green"

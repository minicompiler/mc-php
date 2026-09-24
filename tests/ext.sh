#!/bin/sh
# The extension gate: a .php compiled into a .so that php LOADS, and its
# answers compared with php's own.
#
#     sh tests/ext.sh                    # on the host it is on
#     BIN=/path/to/mc-php sh tests/ext.sh
#     LINUX=1 sh tests/ext.sh            # use examples/hello/mcphp.linux.toml
#     WINDOWS=1 sh tests/ext.sh          # examples/hello/mcphp.windows.toml,
#                                        # after tests/winsys.sh x86_64
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
#      hello.$sx loaded, once with hello.php required -- and the two must print
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
# The artefact's suffix is the platform's: php loads a .dll on Windows.
sx=so
[ "${WINDOWS:-0}" = 1 ] && { cfg=$EX/mcphp.windows.toml; sx=dll; }
fail=0

[ -x "$BIN" ] || { echo "  no $BIN"; exit 1; }
. "$here/tmp.sh"
mcphp_tmp_init mcphp-ext
tmp=$MCPHP_TMP
trap 'rm -rf "$tmp"' EXIT
trap 'exit 130' INT

say() { printf '  %s\n' "$*"; }
bad() { printf '  FAIL %s\n' "$*"; fail=1; }

# The two steps below need a C compiler and php-config, and the COMPILER needs
# neither -- that is the claim of this repository, so they SKIP with the reason
# printed rather than failing. A gate's oracle is not a dependency of the thing
# it grades (probes/t3 made the same call for the same reason).
have_cc() {
    command -v php-config >/dev/null 2>&1 || return 1
    command -v "$CC" >/dev/null 2>&1 || return 1
    return 0
}

# --- 1. the layout gate ----------------------------------------------------
if have_cc && "$CC" -o "$tmp/abi" tests/ext/abi.c $(php-config --includes) 2>"$tmp/cc.err"
then
    "$tmp/abi" > "$tmp/abi.txt"
    n=0
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
# php -i writes CRLF on Windows; the values are compared without it.
pv() { "$PHP" -i | tr -d '\r' | sed -n "s/^$1 => //p" | head -1; }
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
out=$tmp/hello.$sx
rm -f "$out"
# The artefact named by [project].out, which is relative to the CONFIG's
# directory -- removed before the build and not only after, or a build that
# fails is graded on the .so an earlier run left there (found by the reviewer
# of #15). mc's own driver unlinks its output for a different reason (the
# cached-signature SIGKILL); this is the gate not trusting that.
rm -f "$EX/build/hello.$sx"
if "$BIN" build "$EX" --config "$cfg" > "$tmp/build.out" 2>&1; then
    cp "$EX/build/hello.$sx" "$out" 2>/dev/null || bad "no $EX/build/hello.$sx"
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
# NATIVE: hello.$sx loaded, so check.php's own `require` is skipped.
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
# A bundle is what an extension IS on macOS, and `-shared` is what makes one
# everywhere else; try them in that order rather than switching on the host.
build_ref() {
    have_cc || return 1
    inc=$(php-config --includes)
    "$CC" -bundle -undefined dynamic_lookup -o "$tmp/refx.so" tests/ext/refx.c $inc \
        2>"$tmp/refx.err" && return 0
    "$CC" -shared -fPIC -o "$tmp/refx.so" tests/ext/refx.c $inc 2>>"$tmp/refx.err"
}
if build_ref
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
# [sysroot] is relative to the config's own directory and this copy lives in
# $tmp, so the directory it names comes along. Not an absolute path: mc joins
# a Windows one (D:/...) onto the config's directory as if it were relative.
if grep -q '^\[sysroot\]' "$cfg"; then
    cp -R build/win-x86_64 "$tmp/sysroot"
fi
sed "s|^entry = .*|entry = \"r.php\"|; s|^out = .*|out = \"build/r.$sx\"|; s|^path = .*|path = \"sysroot\"|" "$cfg" > "$tmp/r.toml"
nref=0
# A refusal is three things and the gate checks all three: the build FAILS,
# the last line names the reason, and it carries the classification. This
# repository distinguishes two (docs/plan.md): `is refused by design` with
# exit 3 is a DESIGN answer, and `is not implemented yet` with exit 1 is a
# construct that has not been built. These eight are the second kind -- the
# schema promises them -- so that is what is required, and a message alone is
# not enough (found by the reviewer of #15: a compile error that happened to
# contain the phrase passed).
refuse() {
    nref=$((nref + 1))
    printf '<?php\n%s\n' "$1" > "$tmp/r.php"
    rm -f "$tmp/build/r.$sx"
    # NOT `got=$(... | tail -1); rc=$?` -- that reads tail's status, which is
    # always 0, and every refusal then reported "it BUILT".
    "$BIN" build "$tmp" --config "$tmp/r.toml" > "$tmp/r.out" 2>&1; rc=$?
    got=$(tail -1 "$tmp/r.out")
    if [ "$rc" = 0 ]; then bad "refusal: $1"; echo "      it BUILT (exit 0)"; return; fi
    case $got in
        *"$2"*) ;;
        *) bad "refusal: $1"; printf '      want ...%s...\n      got  %s\n' "$2" "$got"; return ;;
    esac
    case $got in
        *"is not implemented yet"*) ;;
        *) bad "refusal: $1"; printf '      unclassified: %s\n' "$got" ;;
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

# --- 7. the two the reviewer of #15 found, each reproduced before it was fixed
# (a) a `function` NESTED in an exported one used to steal the export row, so
#     the module published the nested declaration and lost the outer one.
#     php declares a nested function only when the outer RUNS, so the module
#     must publish the outer and not the nested.
printf '<?php\nfunction outer(int $n): int { function nested(int $m): int { return $m * 3; } return nested($n) + 1; }\n' > "$tmp/r.php"
rm -f "$tmp/build/r.$sx"
if "$BIN" build "$tmp" --config "$tmp/r.toml" > "$tmp/n.build" 2>&1; then
    got=$("$PHP" -d extension="$tmp/build/r.$sx" \
        -r 'printf("%d%d%d", function_exists("outer"), function_exists("nested"), outer(7));' 2>&1)
    [ "$got" = "1022" ] || bad "a nested function: want 1022 (outer yes, nested no, outer(7)=22), got $got"
else
    bad "a nested function: it would not build"; sed 's/^/      /' "$tmp/n.build"
fi

# (b) an [extension] table whose `name` is missing or misspelt used to fall
#     through to the PROGRAM road in silence and write an executable.
sed 's/^name = /nmae = /' "$tmp/r.toml" > "$tmp/noname.toml"
rm -f "$tmp/build/r.$sx"
"$BIN" build "$tmp" --config "$tmp/noname.toml" > "$tmp/nn.out" 2>&1; rc=$?
got=$(tail -1 "$tmp/nn.out")
case "$rc:$got" in
    0:*) bad "a nameless [extension]: it built anyway" ;;
    *"extension.name"*) ;;
    *) bad "a nameless [extension]: want ...extension.name..., got $got" ;;
esac
[ ! -f "$tmp/build/r.$sx" ] || bad "a nameless [extension]: it wrote an artefact"
rm -rf "$tmp/build"
say "the two of review #15: a nested function, and a nameless [extension]"

[ "$fail" = 0 ] || { echo "  ext: something failed"; exit 1; }
echo "  ext: the extension road is green"

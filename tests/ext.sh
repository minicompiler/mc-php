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
        mine=$(sed -n "s/^#define  *$name  *\([0-9][0-9]*\).*/\1/p" lib/php_ext.mc lib/php_rt.mc | head -1)
        [ -n "$mine" ] || { bad "layout: neither lib/php_ext.mc nor lib/php_rt.mc has $name"; continue; }
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

# --- 8. a declared scalar RETURN is checked, in the module as interpreted -----
# php throws its own TypeError for `return "x";` from `: int`; the module used
# to answer int(0) (docs/plan.md § 7). The message crosses the boundary as a
# TypeError because the engine has that class.
printf '<?php\nfunction rbad(): int { $s = "x"; return $s; }\nfunction rnum(): int { $s = "7"; return $s; }\n' > "$tmp/r.php"
cat > "$tmp/rcall.php" <<'EOF2'
<?php
if (!function_exists('rbad')) { require __DIR__ . '/r.php'; }
var_dump(rnum());
try { rbad(); } catch (TypeError $e) { echo get_class($e), ": ", $e->getMessage(), "\n"; }
EOF2
rm -f "$tmp/build/r.$sx"
if "$BIN" build "$tmp" --config "$tmp/r.toml" > "$tmp/rb.build" 2>&1; then
    rn=$("$PHP" -d extension="$tmp/build/r.$sx" "$tmp/rcall.php" 2>&1 | tr -d '\r')
    ri=$("$PHP" "$tmp/rcall.php" 2>&1 | tr -d '\r')
    if [ "$rn" = "$ri" ]; then
        say "a return type: the module throws php's own TypeError, as interpreted"
    else
        bad "a return type: module and interpreted differ"; printf '      module:      %s\n      interpreted: %s\n' "$rn" "$ri"
    fi
else
    bad "a return type: it would not build"; sed 's/^/      /' "$tmp/rb.build"
fi
rm -rf "$tmp/build"

# --- 9. a leading underscore is module-private -------------------------------
# Published: every function without one. Not published: _helper, and _arr,
# whose array signature an EXPORTED function could not have -- unpublished, it
# is not the boundary's (docs/php-extension.md § What is published).
printf '<?php\nfunction _helper(int $n): int { return $n * 2; }\nfunction _arr(array $a): array { return $a; }\nfunction pub(int $n): int { return _helper($n) + count(_arr([1, 2])); }\n' > "$tmp/r.php"
rm -f "$tmp/build/r.$sx"
if "$BIN" build "$tmp" --config "$tmp/r.toml" > "$tmp/pv.build" 2>&1; then
    got=$("$PHP" -d extension="$tmp/build/r.$sx" \
        -r 'printf("%d%d%d %d", function_exists("pub"), function_exists("_helper"), function_exists("_arr"), pub(4));' 2>&1 | tr -d '\r')
    if [ "$got" = "100 10" ]; then
        say "private: pub is published, _helper and _arr are not, and pub(4) calls both"
    else
        bad "private: want '100 10' (pub yes, _helper no, _arr no, pub(4)=10), got $got"
    fi
else
    bad "private: it would not build"; sed 's/^/      /' "$tmp/pv.build"
fi
rm -rf "$tmp/build"

# --- 9b. a call that makes an object keeps nothing ----------------------------
# An object is call memory like any other unless it has a destructor (which
# joins module state). 200 000 calls that each make a stdClass must leave
# php's usage where it was; pinning every `new` kept each call's memory until
# the request ended (the review of #19).
printf '<?php\nfunction mk(int $n): int { $o = new stdClass; $o->v = $n; $a = [$o, $o]; return $a[1]->v; }\n' > "$tmp/r.php"
rm -f "$tmp/build/r.$sx"
if "$BIN" build "$tmp" --config "$tmp/r.toml" > "$tmp/ob.build" 2>&1; then
    got=$("$PHP" -d extension="$tmp/build/r.$sx" \
        -r '$u = memory_get_usage(); $s = 0; for ($i = 0; $i < 200000; $i++) { $s += mk($i); } printf("%d %d", $s, memory_get_usage() - $u);' 2>&1 | tr -d '\r')
    set -- $got
    if [ "${1:-}" = 19999900000 ] && [ "${2:-999999}" -lt 65536 ]; then
        say "objects: 200000 calls that each make one, php's usage moved $2 bytes"
    else
        bad "objects: want 19999900000 and usage under 64 KiB, got $got"
    fi
else
    bad "objects: it would not build"; sed 's/^/      /' "$tmp/ob.build"
fi
rm -rf "$tmp/build"

# --- 10. a request lifecycle, through php's own built-in server -------------
# Twenty requests to one php -S, each calling a static counter twice, a
# `global` twice and a function that keeps 4 MiB in a static: php resets all
# three per request, so every response is the same line. The module used to
# keep its statics and globals across requests and to allocate out of one
# 48 MiB arena for the life of the server (docs/plan.md § 7). The second line
# of each response is an output buffer the MODULE opens and leaves open, which
# is php's own stack: the script's echo after the call goes into it too.
printf '<?php\nfunction counter(): int { static $n = 0; $n++; return $n; }\nfunction remember(string $s): string { global $last; $prev = $last ?? ""; $last = $s; return $prev; }\nfunction big(): int { static $keep = ""; $keep = str_repeat("x", 4 << 20); return strlen($keep); }\nfunction open_ob(): int { echo "0"; ob_start(); echo "A"; ob_start(); echo "B"; return 1; }\nfunction inner_ob(): string { ob_start(); echo "in"; return ob_get_clean() . "!"; }\nfunction lens(): string { ob_start(); echo "abcd"; $n = ob_get_length(); ob_end_clean(); return var_export($n, true) . " " . var_export(ob_get_length(), true); }\n' > "$tmp/r.php"
printf '<?php\nif (!function_exists("counter")) { require __DIR__ . "/r.php"; }\necho counter(), counter(), " [", remember("a"), remember("b"), "] ", big(), " ", inner_ob(), "\\n";\necho lens(), "\\n";\n$n = open_ob();\necho "C$n\\n";\n' > "$tmp/router.php"
rm -f "$tmp/build/r.$sx"
if "$BIN" build "$tmp" --config "$tmp/r.toml" > "$tmp/rq.build" 2>&1; then
    tmpn=$(cygpath -m "$tmp" 2>/dev/null || echo "$tmp")
    "$PHP" tests/ext/requests.php "$tmpn/router.php" 20 "$tmpn/build/r.$sx" > "$tmp/rq.n" 2>&1; qn=$?
    "$PHP" tests/ext/requests.php "$tmpn/router.php" 20 > "$tmp/rq.i" 2>&1; qi=$?
    want=$(sort -u "$tmp/rq.i" | tr -d '\r' | tr '\n' '|')
    if [ "$qn" = 0 ] && [ "$qi" = 0 ] && cmp -s "$tmp/rq.n" "$tmp/rq.i" \
       && [ "$want" = "0ABC1|12 [a] 4194304 in!|4 false|" ] \
       && [ "$(wc -l < "$tmp/rq.n" | tr -d ' ')" = 60 ]; then
        say "requests: 20 through php -S, every one the interpreted source's (statics reset, ob levels php's own)"
    else
        bad "requests: the module's 20 responses are not the interpreted source's"
        diff "$tmp/rq.i" "$tmp/rq.n" | head -8 | sed 's/^/      /'
    fi
else
    bad "requests: it would not build"; sed 's/^/      /' "$tmp/rq.build"
fi
rm -rf "$tmp/build"

# --- 11. a refcount-1 string grows in place --------------------------------
# php's concat_function extends the left operand in place (zend_string_extend,
# which is _erealloc) when it is the result and nobody else holds it, and a
# string offset write does the same; any other string is copied first. The
# module does both now (lib/php_rt.mc § who owns a string). The runtime counts
# which way each `.=` and `$s[$i] =` went and prints the two numbers at the
# end of the request when MCPHP_STATS=1 is in php's environment -- so this
# counts reallocations against copies rather than timing anything.
#   grow(100000): the first `.=` copies the literal "" (a literal is the
#   module's, never written), the other 99 999 are in place, and so is the
#   offset write on the string that loop built;
#   share(3): $k holds the same string as $s, so the first `.=` must COPY (and
#   $k keeps "aa"), after which $s is its own again.
printf '<?php\nfunction grow(int $n): int { $s = ""; for ($i = 0; $i < $n; $i++) { $s .= "x"; } $s[5] = "y"; return strlen($s) + ord($s[5]); }\nfunction share(int $n): string { $s = str_repeat("a", 2); $k = $s; for ($i = 0; $i < $n; $i++) { $s .= "b"; } return $k . " " . $s; }\n' > "$tmp/r.php"
rm -f "$tmp/build/r.$sx"
if "$BIN" build "$tmp" --config "$tmp/r.toml" > "$tmp/gr.build" 2>&1; then
    got=$(MCPHP_STATS=1 "$PHP" -d extension="$tmp/build/r.$sx" \
        -r 'echo grow(100000), " ", share(3), "\n";' 2>&1 | tr -d '\r' | tr '\n' '|')
    want=$(printf '<?php\nrequire $argv[1]; echo grow(100000), " ", share(3), "\\n";\n' > "$tmp/gi.php"; "$PHP" "$tmp/gi.php" "$tmp/r.php" | tr -d '\r')
    case "$got" in
        "$want|mc-php stats: in place 100002, copied 2|")
            say "in place: 100002 of 100004 string writes grew or wrote the string itself, 2 copied (a literal, and a shared string) -- answers php's own" ;;
        *) bad "in place: want '$want|mc-php stats: in place 100002, copied 2|', got '$got'" ;;
    esac
else
    bad "in place: it would not build"; sed 's/^/      /' "$tmp/gr.build"
fi
rm -rf "$tmp/build"

# --- 12. a loop inside ONE call keeps a bounded high-water mark ---------------
# Each iteration builds two 1 KB strings that the next iteration no longer
# reads. A temporary dies at the top of the next iteration and a variable's old
# string when it is overwritten, so 100 000 iterations in one call leave php's
# PEAK where one iteration puts it. The module used to bump every string of a
# call through its chunk until the call returned: 200 MB for this loop, past
# php's 128 MiB memory_limit.
printf '<?php\nfunction churn(int $n): int { $t = 0; for ($i = 0; $i < $n; $i++) { $s = str_repeat("y", 1000) . $i; $t += strlen($s); } return $t; }\n' > "$tmp/r.php"
rm -f "$tmp/build/r.$sx"
if "$BIN" build "$tmp" --config "$tmp/r.toml" > "$tmp/ch.build" 2>&1; then
    got=$("$PHP" -d extension="$tmp/build/r.$sx" \
        -r 'churn(10); $p = memory_get_peak_usage(); $t = churn(100000); printf("%d %d", $t, memory_get_peak_usage() - $p);' 2>&1 | tr -d '\r')
    set -- $got
    if [ "${1:-}" = 100488890 ] && [ "${2:-999999}" -lt 8192 ]; then
        say "one call: 100000 iterations that each build two 1 KB strings, php's peak moved $2 bytes"
    else
        bad "one call: want 100488890 and a peak that moved under 8 KiB, got $got"
    fi
else
    bad "one call: it would not build"; sed 's/^/      /' "$tmp/ch.build"
fi
rm -rf "$tmp/build"

# --- 13. the ownership shapes, in the module as interpreted ----------------
# tests/g/111-string-ownership.php's functions compiled into a module and
# called from php, several times, against the same source interpreted: a
# second name on a string, a string appended to itself, a parameter the body
# writes, an argument handed straight back, strings kept by an array, a
# closure and a static, and an exception thrown from the middle of a loop that
# builds strings. A string freed under a live name, or written through a name
# that shares it, prints something else.
{ printf '<?php\n'; awk '/^echo /{exit} /^function /{p=1} p' tests/g/111-string-ownership.php; } > "$tmp/r.php"
cat > "$tmp/own.php" <<'EOF2'
<?php
if (!function_exists('alias')) { require __DIR__ . '/r.php'; }
for ($k = 0; $k < 3; $k++) {
    echo strlen(grow(1000)), substr(grow(300), 290), " ", alias(), " ", self_cat("ab"), "\n";
    $x = "arg$k";
    echo param($x), " ", $x, " ", same($x), same("lit"), keep_last("one", "two$k"), " ", keepers(), " ", counter("t$k"), "\n";
    try { echo thrower($k), "\n"; } catch (RuntimeException $e) { echo get_class($e), ": ", $e->getMessage(), "\n"; }
}
EOF2
rm -f "$tmp/build/r.$sx"
if "$BIN" build "$tmp" --config "$tmp/r.toml" > "$tmp/ow.build" 2>&1; then
    "$PHP" -d extension="$tmp/build/r.$sx" "$tmp/own.php" > "$tmp/ow.n" 2>&1; on=$?
    "$PHP" "$tmp/own.php" > "$tmp/ow.i" 2>&1; oi=$?
    if [ "$on" = "$oi" ] && cmp -s "$tmp/ow.n" "$tmp/ow.i"; then
        say "ownership: $(wc -l < "$tmp/ow.n" | tr -d ' ') lines of aliasing, self-appends and kept strings, byte for byte php's own"
    else
        bad "ownership: the module (exit $on) and the interpreted source (exit $oi) differ"
        diff "$tmp/ow.i" "$tmp/ow.n" | head -8 | sed 's/^/      /'
    fi
else
    bad "ownership: it would not build"; sed 's/^/      /' "$tmp/ow.build"
fi
rm -rf "$tmp/build"

[ "$fail" = 0 ] || { echo "  ext: something failed"; exit 1; }
echo "  ext: the extension road is green"

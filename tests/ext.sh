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
. "$here/ts.sh"
mcphp_ts_init
# a ZTS php grades a copy of the file that says "zts" (tests/ts.sh)
cfg0=$cfg
cfg=$(mcphp_ts_cfg "$cfg")
trap 'rm -rf "$tmp"; mcphp_ts_clean' EXIT
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

# --- 1b. every php name the module imports, in the Windows import library --
# On Windows the module links against an import library tests/winsys.sh makes
# from src/win/php8.def and php8ts.def; a php name lib/php_ext.mc declares and
# those files do not list is an undefined symbol at lld-link -- found only on
# a Windows runner. Graded here, on every host. `free` is the C library's.
wn=0
for nm in $(sed -n 's/^extern [a-zA-Z0-9_ ]* \([a-zA-Z_][a-zA-Z_0-9]*\)(.*/\1/p' lib/php_ext.mc | sort -u); do
    [ "$nm" = free ] && continue
    wn=$((wn + 1))
    for d in src/win/php8.def src/win/php8ts.def; do
        grep -Eq "^$nm( |\$)" "$d" || bad "$d does not list $nm, which lib/php_ext.mc imports"
    done
done
say "windows imports: $wn php names lib/php_ext.mc declares, each in src/win/php8.def and php8ts.def"

# --- 2. the project file names the php it is being graded against ----------
# php -i writes CRLF on Windows; the values are compared without it.
pv() { "$PHP" -i | tr -d '\r' | sed -n "s/^$1 => //p" | head -1; }
tv() { sed -n "s/^$1 = *\(.*\)\$/\1/p" "$cfg" | head -1 | tr -d '"'; }
api=$(pv 'PHP API'); bid=$(pv 'PHP Extension Build')
zts=false; [ "$(pv 'Thread Safety')" = enabled ] && zts=true
dbg=false; [ "$(pv 'Debug Build')" = yes ] && dbg=true
# The build id is compared the way the compiler writes it: the stated one with
# its thread-safety word made this output's (src/ext.mc ph_ts_bid) -- the file
# says ",NTS" and a ZTS output carries ",TS".
tsw=NTS; [ "$zts" = true ] && tsw=TS
for pair in "api:$api" "build_id:$bid" "thread_safety:$TSV" "debug:$dbg"; do
    k=${pair%%:*}; want=${pair#*:}
    got=$(tv "$k")
    [ "$k" = build_id ] && got=$(printf '%s' "$got" | sed -E "s/,N?TS(,|\$)/,$tsw\1/")
    [ "$got" = "$want" ] || bad "$cfg0: php.$k is $got, this php says $want (re-measure: php -i)"
done
say "php: api $api, build $bid, zts $zts, debug $dbg -- and $cfg0 says so (thread_safety = \"$TSV\" for this php)"

# --- 2b. [php].thread_safety says what it can mean, or is refused ---------
# The value names the php the OUTPUT is for and the compiler never asks a php
# (docs/mcphp-toml.md § [php]). Anything else is refused at its own
# file:line:col, the old booleans with the word that replaces each; and a
# build id with no ,NTS or ,TS word cannot be made the output's own.
tsref() { # SED WANT: a copy of the file edited by SED is refused with WANT
    sed "$1" "$cfg" > "$EX/.ts-ref.toml"
    "$BIN" build "$EX" --config "$EX/.ts-ref.toml" > "$tmp/tsref.out" 2>&1; rc=$?
    got=$(tail -1 "$tmp/tsref.out" | tr -d '\r')
    rm -f "$EX/.ts-ref.toml"
    case "$got" in
        *.ts-ref.toml:[0-9]*:[0-9]*": $2") [ "$rc" = 1 ] && return 0 ;;
    esac
    bad "thread_safety: exit $rc, want 1 and \"$2\""; printf '      got %s\n' "$got"; return 1
}
tsn=0
tsref 's/^thread_safety = .*/thread_safety = "maybe"/' 'mc-php: thread_safety must be "nts", "zts" or "both": php.thread_safety' && tsn=$((tsn + 1))
tsref 's/^thread_safety = .*/thread_safety = false/' 'mc-php: thread_safety is "nts", "zts" or "both" (false is "nts", true is "zts"): php.thread_safety' && tsn=$((tsn + 1))
tsref 's/^build_id = .*/build_id = "API20250925"/' 'mc-php: the build id names no thread safety (,NTS or ,TS): php.build_id' && tsn=$((tsn + 1))
say "thread_safety: $tsn of 3 wrong files refused at the key's own line and column"

# --- 2c. "both": two outputs, and THIS php takes only its own ---------------
# One project, thread_safety = "both" (src/build.mc): build/hello.$sx for an
# NTS php and build/hello-zts.$sx for a ZTS one. The php under test loads the
# one for its kind and refuses the other by name. Every leg grades the half its
# php can; tests/both.sh loads each half in its own php on Linux.
sed 's/^thread_safety = .*/thread_safety = "both"/' "$cfg0" > "$EX/.mcphp-test-both.toml"
rm -f "$EX/build/hello.$sx" "$EX/build/hello-zts.$sx"
if "$BIN" build "$EX" --config "$EX/.mcphp-test-both.toml" > "$tmp/both.out" 2>&1 \
   && [ -f "$EX/build/hello.$sx" ] && [ -f "$EX/build/hello-zts.$sx" ]; then
    mine=hello.$sx; other=hello-zts.$sx
    [ "$TSV" = zts ] && { mine=hello-zts.$sx; other=hello.$sx; }
    cp "$EX/build/$mine" "$tmp/b-mine.$sx"; cp "$EX/build/$other" "$tmp/b-other.$sx"
    bm=$(cygpath -m "$tmp/b-mine.$sx" 2>/dev/null || echo "$tmp/b-mine.$sx")
    bo=$(cygpath -m "$tmp/b-other.$sx" 2>/dev/null || echo "$tmp/b-other.$sx")
    ml=$("$PHP" -d extension="$bm" -r 'echo extension_loaded("hello") ? "yes" : "no";' 2>&1 | tr -d '\r')
    ol=$("$PHP" -d extension="$bo" -r 'echo extension_loaded("hello") ? "yes" : "no";' 2>&1 | tr -d '\r')
    # refused: an NTS module by a ZTS php's header check; a ZTS module in an
    # NTS php by the module itself, from get_module, naming the TSRM symbol
    # this php does not export (lib/php_zts.mc phx_ts_module, an E_CORE_ERROR,
    # which php answers by exiting); and on Windows by the loader, before any
    # of that -- a ZTS module imports php8ts.dll and an NTS php does not have
    # it (and the other way round)
    case "$ml|$ol" in
        yes\|*"Unable to initialize module"*no|yes\|*"Unable to load dynamic library"*no)
            say "both: two outputs; this $TSV php loads $mine and refuses $other" ;;
        "yes|"*"mc-php: this ZTS extension needs php's tsrm_get_ls_cache, which this php does not export"*)
            say "both: two outputs; this $TSV php loads $mine, and $other refuses this php by name: tsrm_get_ls_cache is missing" ;;
        *) bad "both: $mine says \"$ml\", $other says \"$ol\"" ;;
    esac
else
    bad "both: the build:"; sed 's/^/      /' "$tmp/both.out"
fi
# the ZTS copy of the project file (.mcphp-zts-<pid>-<file>) is gone
left=$(ls -a "$EX" | grep '^\.mcphp-zts-' | tr '\n' ' ')
if [ -n "$left" ]; then bad "both: left behind: $left"; rm -f "$EX"/.mcphp-zts-*
else say "both: no .mcphp-zts- copy left beside the project file"; fi
rm -f "$EX/.mcphp-test-both.toml" "$EX/build/hello.$sx" "$EX/build/hello-zts.$sx"

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
# construct that has not been built. These seven are the second kind -- the
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
# (mixed, untyped, a default, a variadic and an array return are taken since
# step 17's signatures; what is left is a REFERENCE across the boundary)
refuse 'function f(&$x): int { return 1; }'          'a by-reference parameter in an exported function'
refuse 'function &f(int $x): int { return $x; }'     'a by-reference return in an exported function'
# a class the module publishes is a plain one at the top level (§ published
# classes): the rest of what php may declare there is refused by name
refuse 'interface I {}'                              'an interface an extension would publish'
refuse 'class A extends \Exception {}'               'a published class that extends or implements another'
refuse 'class A { public static function f() {} }'  'a static method of a published class'
refuse 'class A { public $a = [1]; }'                'a published class'"'"'s property whose default is not a scalar'
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
# shared() answers the runtime's shared empty and one-byte strings, which are
# built on first use -- in the first request, whose pinned call has the arena
# put back as MINIT left it at its end; the other nineteen must still see them.
printf '<?php\nfunction counter(): int { static $n = 0; $n++; return $n; }\nfunction remember(string $s): string { global $last; $prev = $last ?? ""; $last = $s; return $prev; }\nfunction big(): int { static $keep = ""; $keep = str_repeat("x", 4 << 20); return strlen($keep); }\nfunction open_ob(): int { echo "0"; ob_start(); echo "A"; ob_start(); echo "B"; return 1; }\nfunction inner_ob(): string { ob_start(); echo "in"; return ob_get_clean() . "!"; }\nfunction lens(): string { ob_start(); echo "abcd"; $n = ob_get_length(); ob_end_clean(); return var_export($n, true) . " " . var_export(ob_get_length(), true); }\nfunction shared(int $k): string { $e = ltrim(str_repeat("0", $k), "0"); return "<" . $e . substr("ab", 5) . chr(65 + $k) . ">" . strlen($e); }\n' > "$tmp/r.php"
printf '<?php\nif (!function_exists("counter")) { require __DIR__ . "/r.php"; }\necho counter(), counter(), " [", remember("a"), remember("b"), "] ", big(), " ", inner_ob(), "\\n";\necho lens(), " ", shared(3), shared(0), "\\n";\n$n = open_ob();\necho "C$n\\n";\n' > "$tmp/router.php"
rm -f "$tmp/build/r.$sx"
if "$BIN" build "$tmp" --config "$tmp/r.toml" > "$tmp/rq.build" 2>&1; then
    tmpn=$(cygpath -m "$tmp" 2>/dev/null || echo "$tmp")
    "$PHP" tests/ext/requests.php "$tmpn/router.php" 20 "$tmpn/build/r.$sx" > "$tmp/rq.n" 2>&1; qn=$?
    "$PHP" tests/ext/requests.php "$tmpn/router.php" 20 > "$tmp/rq.i" 2>&1; qi=$?
    want=$(sort -u "$tmp/rq.i" | tr -d '\r' | tr '\n' '|')
    if [ "$qn" = 0 ] && [ "$qi" = 0 ] && cmp -s "$tmp/rq.n" "$tmp/rq.i" \
       && [ "$want" = "0ABC1|12 [a] 4194304 in!|4 false <D>0<A>0|" ] \
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
#   Four strings are built in all: the two copies, str_repeat's and the
#   answer of share -- an in-place growth builds none.
printf '<?php\nfunction grow(int $n): int { $s = ""; for ($i = 0; $i < $n; $i++) { $s .= "x"; } $s[5] = "y"; return strlen($s) + ord($s[5]); }\nfunction share(int $n): string { $s = str_repeat("a", 2); $k = $s; for ($i = 0; $i < $n; $i++) { $s .= "b"; } return $k . " " . $s; }\n' > "$tmp/r.php"
rm -f "$tmp/build/r.$sx"
if "$BIN" build "$tmp" --config "$tmp/r.toml" > "$tmp/gr.build" 2>&1; then
    got=$(MCPHP_STATS=1 "$PHP" -d extension="$tmp/build/r.$sx" \
        -r 'echo grow(100000), " ", share(3), "\n";' 2>&1 | tr -d '\r' | tr '\n' '|')
    want=$(printf '<?php\nrequire $argv[1]; echo grow(100000), " ", share(3), "\\n";\n' > "$tmp/gi.php"; "$PHP" "$tmp/gi.php" "$tmp/r.php" | tr -d '\r')
    case "$got" in
        "$want|mc-php stats: in place 100002, copied 2, strings built 4|")
            say "in place: 100002 of 100004 string writes grew or wrote the string itself, 2 copied (a literal, and a shared string) -- answers php's own" ;;
        *) bad "in place: want '$want|mc-php stats: in place 100002, copied 2, strings built 4|', got '$got'" ;;
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

# --- 12b. a loop whose only calls are slow halves still drains ---------------
# src/opt.mc drops the pool drain at the top of a loop that builds nothing, and
# a slow half that raises a diagnostic BUILDS: the "Uninitialized string
# offset -100" text puts its number in the pool (php_mi -> php_itos). Treated
# as building nothing, 100 000 such reads in one call grew php's peak by 8.4 MB
# (the review of #24, reproduced before the fix); with the drain kept it does
# not move. The offset is a NEGATIVE LITERAL, the one out-of-range string read
# that keeps php's rules and its warning (docs/semantics.md): any other read
# outside the range is undefined, and a test must not make one.
printf '<?php\nfunction offs(string $s, int $n): int { $t = 0; for ($i = 0; $i < $n; $i++) { $t = $t + ord($s[-100]); } return $t; }\n' > "$tmp/r.php"
rm -f "$tmp/build/r.$sx"
if "$BIN" build "$tmp" --config "$tmp/r.toml" > "$tmp/dg.build" 2>&1; then
    # the 100 010 warnings are the module's own output: on stdout, dropped 4 KB
    # at a time by the buffer's callback (a buffer that kept them would move
    # the peak itself), and the log line on stderr. Only the number stays --
    # warmed up first: a peak is per process.
    got=$("$PHP" -d extension="$tmp/build/r.$sx"         -r 'ob_start(fn($b) => "", 4096); offs("abc", 1000); $p = memory_get_peak_usage(); offs("abc", 100000); $r = memory_get_peak_usage(); ob_end_clean(); echo $r - $p;' 2>/dev/null | tr -d '\r')
    if [ "${got:-999999}" -lt 8192 ]; then
        say "slow halves: 100000 reads at a negative literal offset outside the string in one call, php's peak moved $got bytes"
    else
        bad "slow halves: want a peak that moves under 8 KiB, got $got"
    fi
else
    bad "slow halves: it would not build"; sed 's/^/      /' "$tmp/dg.build"
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
    echo strlen(grow(1000)), substr(grow(300), 290), " ", alias(), " ", self_cat("ab"), " ", doubler("a$k", 4 + $k), "\n";
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

# --- 14. a call through php's function table, in the module as interpreted ---
# A function the module's source does not declare is looked up in php's
# function table when the call runs (lib/php_ext.mc's phx_fcall): here the
# callees are the SCRIPT's own php functions. Every value that crosses --
# int, string, float, bool, null, and a string handed back; the answer as an
# int on the `: int` road and as a value elsewhere; php's return-value rule
# (a numeric string coerced, a word refused); an exception the callee throws,
# caught by the module's own catch (class, message, code) and uncaught across
# it (the engine's own object); an undefined function; output ordered around
# the call; and the module RE-ENTERED through the callee. Then arrays, which
# cross as the engine's own both ways (§ engine values), and an array answer
# to `: int`, php's own TypeError. examples/two-extensions is the same road
# between two modules.
cat > "$tmp/r.php" <<'EOF2'
<?php
function ft_one(int $a): int { return cb_add($a, 1); }
function ft_two(int $a, int $b): int { return cb_add($a, $b); }
function ft_str(string $s): string { return cb_str($s) . "|" . cb_str("lit") . "|" . cb_str($s . "x"); }
function ft_mix(float $x, bool $b): string { return (string) cb_mix($x, $b, null) . (string) cb_mix(1.5, false, "v"); }
function ft_numstr(): int { return cb_numstr(); }
function ft_word(): int { return cb_word(); }
function ft_catch(int $n): string {
    try { return "no " . cb_throw($n); }
    catch (InvalidArgumentException $e) { return "caught " . get_class($e) . " " . $e->getMessage() . " " . $e->getCode(); }
}
function ft_uncaught(int $n): int { return cb_throw($n); }
function ft_undef(int $n): int { return no_such_fn($n); }
function ft_echo(int $n): int { echo "before "; $r = cb_echo($n); echo " after "; return $r; }
function ft_reent(int $n): int { return cb_back($n); }
function ft_two_calls(int $n): int { $x = cb_throw($n); return cb_add($x, 1); }
EOF2
cat > "$tmp/ft.php" <<'EOF2'
<?php
if (!function_exists('ft_one')) { require __DIR__ . '/r.php'; }
function cb_add(int $a, int $b): int { return $a + $b; }
function cb_str(string $s): string { return strtoupper($s); }
function cb_mix($x, $b, $n) { return ($b ? $x * 2 : $x) . ($n === null ? "n" : $n); }
function cb_throw(int $n) { throw new InvalidArgumentException("bad $n", 40 + $n); }
function cb_numstr() { return "7"; }
function cb_word() { return "x"; }
function cb_echo(int $n): int { echo "[cb $n]"; return $n * 3; }
function cb_back(int $n): int { return $n > 0 ? ft_reent($n - 1) + 1 : 100; }
for ($k = 0; $k < 3; $k++) {
    echo ft_one(41), " ", ft_two(40, $k), " ", ft_str("ab$k"), " ", ft_mix(2.25, true), " ", ft_numstr(), "\n";
    try { ft_word(); } catch (TypeError $e) { echo get_class($e), ": ", $e->getMessage(), "\n"; }
    echo ft_catch($k), "\n";
    try { ft_uncaught($k); } catch (InvalidArgumentException $e) { echo get_class($e), " ", $e->getMessage(), " ", $e->getCode(), "\n"; }
    try { ft_undef($k); } catch (Error $e) { echo get_class($e), ": ", $e->getMessage(), "\n"; }
    try { ft_two_calls($k); } catch (Exception $e) { echo "stopped at the first: ", $e->getMessage(), "\n"; }
    echo ft_echo($k), " ", ft_reent(3 + $k), "\n";
}
EOF2
rm -f "$tmp/build/r.$sx"
if "$BIN" build "$tmp" --config "$tmp/r.toml" > "$tmp/ft.build" 2>&1; then
    "$PHP" -d extension="$tmp/build/r.$sx" "$tmp/ft.php" > "$tmp/ft.n" 2>&1; fnrc=$?
    "$PHP" "$tmp/ft.php" > "$tmp/ft.i" 2>&1; firc=$?
    if [ "$fnrc" = "$firc" ] && cmp -s "$tmp/ft.n" "$tmp/ft.i"; then
        say "function table: $(wc -l < "$tmp/ft.n" | tr -d ' ') lines of calls into the script's own functions, byte for byte php's own"
    else
        bad "function table: the module (exit $fnrc) and the interpreted source (exit $firc) differ"
        diff "$tmp/ft.i" "$tmp/ft.n" | head -12 | sed 's/^/      /'
    fi
    # an array answer crosses now (§ engine values), so `: int` refuses it
    # with php's own return-value rule
    got=$("$PHP" -d extension="$tmp/build/r.$sx" -r 'function cb_add($a, $b) { return [$a]; }
        try { ft_two(1, 2); } catch (Error $e) { echo $e->getMessage(); }' 2>&1 | tr -d '\r')
    want="ft_two(): Return value must be of type int, array returned"
    [ "$got" = "$want" ] && say "function table: an array answer to \`: int\` is php's own TypeError" \
        || { bad "function table: an array answer"; printf '      want %s\n      got  %s\n' "$want" "$got"; }
else
    bad "function table: it would not build"; sed 's/^/      /' "$tmp/ft.build"
fi
# an array goes in and comes back: the engine's own array both ways
printf '<?php\nfunction ft_arr(int $n): int { $a = [$n, $n + 1]; return cb_count($a); }\nfunction ft_back(int $n): array { return cb_twice([$n, "k" => [$n]]); }\n' > "$tmp/r.php"
rm -f "$tmp/build/r.$sx"
if "$BIN" build "$tmp" --config "$tmp/r.toml" > "$tmp/fa.out" 2>&1; then
    got=$("$PHP" -d extension="$tmp/build/r.$sx" -r 'function cb_count($a) { return count($a); } function cb_twice($a) { return [$a, $a]; }
        echo ft_arr(5), " ", json_encode(ft_back(7));' 2>&1 | tr -d '\r')
    want='2 [{"0":7,"k":[7]},{"0":7,"k":[7]}]'
    [ "$got" = "$want" ] && say "function table: an array argument and an array answer, both the engine's own" \
        || { bad "function table: arrays"; printf '      want %s\n      got  %s\n' "$want" "$got"; }
else
    bad "function table: arrays would not build"; sed 's/^/      /' "$tmp/fa.out"
fi
rm -rf "$tmp/build"

# --- 15. a namespaced module, in the module as interpreted -------------------
# A function declared in `namespace aw\util` is published as `aw\util\tri`,
# a module-private `_h` stays private under its namespace, a constant and
# __NAMESPACE__/__FUNCTION__ are the namespace's, an unqualified php function
# is php's global one, and an unqualified name the source does not declare is
# looked up as `aw\util\helper` and then `helper`, as php does (src/ns.mc).
cat > "$tmp/r.php" <<'EOF2'
<?php
namespace aw\util;
const K = 3;
function _h(int $n): int { return $n * K; }
function tri(int $n): int { return _h($n) + strlen("ab"); }
function name(): string { return __FUNCTION__ . " in " . __NAMESPACE__; }
function via(int $n): int { return helper($n); }
EOF2
cat > "$tmp/ns.php" <<'EOF2'
<?php
if (!function_exists('aw\util\tri')) { require __DIR__ . '/r.php'; }
function helper($n) { return $n + 1000; }
echo aw\util\tri(4), " ", \aw\util\name(), " ", aw\util\via(1), " ",
     var_export(function_exists('aw\util\_h'), true), "\n";
EOF2
rm -f "$tmp/build/r.$sx"
if "$BIN" build "$tmp" --config "$tmp/r.toml" > "$tmp/ns.build" 2>&1; then
    nn=$("$PHP" -d extension="$tmp/build/r.$sx" "$tmp/ns.php" 2>&1 | tr -d '\r')
    ni=$("$PHP" "$tmp/ns.php" 2>&1 | tr -d '\r')
    # interpreted, the private helper IS a function php knows: that one
    # answer differs by design (docs/php-extension.md § What is published)
    ni=$(printf '%s' "$ni" | sed 's/ true$/ false/')
    if [ "$nn" = "$ni" ]; then
        say "namespaces: published as aw\\util\\*, the fallback to a global function, as interpreted"
    else
        bad "namespaces: module and interpreted differ"; printf '      module:      %s\n      interpreted: %s\n' "$nn" "$ni"
    fi
    pub=$("$PHP" -d extension="$tmp/build/r.$sx" -r '$f = get_extension_funcs("hello"); sort($f); echo implode(" ", $f);' 2>&1 | tr -d '\r')
    [ "$pub" = 'aw\util\name aw\util\tri aw\util\via' ] || bad "namespaces: published $pub"
else
    bad "namespaces: it would not build"; sed 's/^/      /' "$tmp/ns.build"
fi
rm -rf "$tmp/build"

# --- 16. #[Extern]: a C function declared in php ------------------------------
# The module calls C by the declaration alone -- ints, a C int's sign, a
# pointer, a string both ways, a C variadic (Apple arm64 puts it on the stack)
# -- and the declaration is not published. The symbols come from php's own
# process. Windows refuses it by name: the link names no library for it.
cat > "$tmp/r.php" <<'EOF2'
<?php
namespace xc;
#[\Extern('c')] function atoi(string $s): int {}
#[\Extern('c')] function strlen(string $s): Ptr {}
#[\Extern('c')] function malloc(Ptr $n): Ptr {}
#[\Extern('c')] function free(Ptr $p): void {}
#[\Extern('c')] function strcat(Ptr $d, string $s): string {}
#[\Extern('c', variadic: 2)] function snprintf(Ptr $b, Ptr $n, string $f, mixed $a, mixed $c): int {}
function fmt(int $n, string $s): string {
    $b = malloc(64);
    $k = snprintf($b, 64, "%d-%s", $n, $s);
    $r = strcat($b, "") . " " . $k . " " . strlen($s) . " " . atoi("-1");
    free($b);
    return $r;
}
EOF2
rm -f "$tmp/build/r.$sx"
"$BIN" build "$tmp" --config "$tmp/r.toml" > "$tmp/xc.build" 2>&1; rc=$?
if [ "${WINDOWS:-0}" = 1 ]; then
    if [ "$rc" != 0 ] && grep -q "an #\[Extern\] function on Windows" "$tmp/xc.build"; then
        say "#[Extern]: refused on Windows by name"
    else
        bad "#[Extern] on Windows: want the refusal"; sed 's/^/      /' "$tmp/xc.build"
    fi
elif [ "$rc" = 0 ]; then
    got=$("$PHP" -d extension="$tmp/build/r.$sx" -r 'echo xc\fmt(42, "abc"), " ", var_export(function_exists("xc\\atoi"), true), "\n";' 2>&1 | tr -d '\r')
    if [ "$got" = "42-abc 6 3 -1 false" ]; then
        say "#[Extern]: libc called from the module, a variadic placed, the declarations not published"
    else
        bad "#[Extern]: got [$got], want [42-abc 6 3 -1 false]"
    fi
else
    bad "#[Extern]: it would not build"; sed 's/^/      /' "$tmp/xc.build"
fi
rm -rf "$tmp/build"

# --- 17. signatures beyond the scalars, php's arrays and objects inside -----
# tests/ext/values: every answer the interpreted source's, the errors an
# internal function's (php's own parameter parsing, as a C extension's), and
# the engine object a proxy stands for is the same object going back out.
cp tests/ext/values/values.php "$tmp/r.php"
cp tests/ext/values/check.php "$tmp/vc.php"
sed -i.bak "s#__DIR__ . '/values.php'#__DIR__ . '/r.php'#" "$tmp/vc.php"
rm -f "$tmp/build/r.$sx"
if "$BIN" build "$tmp" --config "$tmp/r.toml" > "$tmp/v.build" 2>&1; then
    "$PHP" -d extension="$tmp/build/r.$sx" "$tmp/vc.php" 2>&1 | tr -d '\r' > "$tmp/v.m"
    "$PHP" "$tmp/vc.php" 2>&1 | tr -d '\r' > "$tmp/v.i"
    ne=$(wc -l < tests/ext/values/errors.expect | tr -d ' ')
    nm=$(wc -l < "$tmp/v.m" | tr -d ' ')
    head -n $((nm - ne)) "$tmp/v.m" > "$tmp/v.mh"
    head -n $((nm - ne)) "$tmp/v.i" > "$tmp/v.ih"
    tail -n "$ne" "$tmp/v.m" > "$tmp/v.mt"
    if cmp -s "$tmp/v.mh" "$tmp/v.ih" && cmp -s "$tmp/v.mt" tests/ext/values/errors.expect; then
        say "values: arrays, objects, a class, a callable, ?array, a default and variadics, as interpreted; $ne errors in php's own words"
    else
        bad "values: module and interpreted differ"; diff "$tmp/v.ih" "$tmp/v.mh" | sed -n '1,12p' | sed 's/^/      /'
        diff tests/ext/values/errors.expect "$tmp/v.mt" | sed -n '1,12p' | sed 's/^/      /'
    fi
else
    bad "values: it would not build"; sed 's/^/      /' "$tmp/v.build"
fi
rm -rf "$tmp/build"

# --- 18. a module that publishes classes, as interpreted ---------------------
cp tests/ext/classes/classes.php "$tmp/r.php"
sed "s#__DIR__ . '/classes.php'#__DIR__ . '/r.php'#" tests/ext/classes/check.php > "$tmp/cc.php"
rm -f "$tmp/build/r.$sx"
if "$BIN" build "$tmp" --config "$tmp/r.toml" > "$tmp/c.build" 2>&1; then
    "$PHP" -d extension="$tmp/build/r.$sx" "$tmp/cc.php" > "$tmp/c.m" 2>&1; cm=$?
    "$PHP" "$tmp/cc.php" > "$tmp/c.i" 2>&1; ci=$?
    if [ "$cm" = "$ci" ] && cmp -s "$tmp/c.m" "$tmp/c.i"; then
        say "classes: $(wc -l < "$tmp/c.m" | tr -d ' ') lines of a published class, byte for byte the interpreted source's"
    else
        bad "classes: the module (exit $cm) and the interpreted source (exit $ci) differ"
        diff "$tmp/c.i" "$tmp/c.m" | sed -n '1,12p' | sed 's/^/      /'
    fi
else
    bad "classes: it would not build"; sed 's/^/      /' "$tmp/c.build"
fi
rm -rf "$tmp/build"

# --- 19. a module that calls php's callables, as interpreted -----------------
cp tests/ext/callables/callables.php "$tmp/r.php"
sed "s#__DIR__ . '/callables.php'#__DIR__ . '/r.php'#" tests/ext/callables/check.php > "$tmp/kc.php"
rm -f "$tmp/build/r.$sx"
if "$BIN" build "$tmp" --config "$tmp/r.toml" > "$tmp/k.build" 2>&1; then
    "$PHP" -d extension="$tmp/build/r.$sx" "$tmp/kc.php" > "$tmp/k.m" 2>&1; km=$?
    "$PHP" "$tmp/kc.php" > "$tmp/k.i" 2>&1; ki=$?
    if [ "$km" = "$ki" ] && cmp -s "$tmp/k.m" "$tmp/k.i"; then
        say "callables: a name, an array, a closure, __invoke and a spread called; throwables both ways -- $(wc -l < "$tmp/k.m" | tr -d ' ') lines, the interpreted source's"
    else
        bad "callables: the module (exit $km) and the interpreted source (exit $ki) differ"
        diff "$tmp/k.i" "$tmp/k.m" | sed -n '1,40p' | sed 's/^/      /'
    fi
else
    bad "callables: it would not build"; sed 's/^/      /' "$tmp/k.build"
fi
rm -rf "$tmp/build"

# a closure that captures its own parameter's name is php's compile-time
# Fatal error on this road too, in php's words, exit 255
cp tests/g/125-closure-lexical-param.php "$tmp/r.php"
rm -f "$tmp/build/r.$sx"
"$BIN" build "$tmp" --config "$tmp/r.toml" > "$tmp/lx.out" 2> "$tmp/lx.err"; lx=$?
if [ "$lx" = 255 ] && grep -q "^Fatal error: Cannot use lexical variable \$x as a parameter name in .*r.php on line 6$" "$tmp/lx.out" \
   && [ ! -f "$tmp/build/r.$sx" ]; then
    say "closures: a parameter named like a lexical variable is php's own compile-time Fatal error, exit 255, no module"
else
    bad "closures: the lexical-variable parameter (exit $lx)"; sed 's/^/      /' "$tmp/lx.out" "$tmp/lx.err" | head -6
fi
rm -rf "$tmp/build"

# --- 20. compiled functions on several OS threads at once --------------------
# tests/ext/threads: the module's threads against php calling the same
# function one thread at a time (a recording: php has no mcphp_threads)
cp tests/ext/threads/threads.php "$tmp/r.php"
rm -f "$tmp/build/r.$sx"
if "$BIN" build "$tmp" --config "$tmp/r.toml" > "$tmp/t.build" 2>&1; then
    "$PHP" -d extension="$tmp/build/r.$sx" tests/ext/threads/check.php 2>&1 | tr -d '\r' > "$tmp/t.m"; tm=$?
    if [ "$tm" = 0 ] && [ "$(grep -c 'the 8 threads agree' "$tmp/t.m")" = 5 ] && [ "$(wc -l < "$tmp/t.m" | tr -d ' ')" = 6 ] \
       && grep -qx "php's engine from this thread: 1002, from 4 others: 4" "$tmp/t.m"; then
        say "threads: 8 OS threads running the module's compiled code, 5 rounds, every sum php's; a worker reaching php's engine gets an Error"
    else
        bad "threads: exit $tm"; sed -n '1,8p' "$tmp/t.m" | sed 's/^/      /'
    fi
else
    bad "threads: it would not build"; sed 's/^/      /' "$tmp/t.build"
fi
rm -rf "$tmp/build"

[ "$fail" = 0 ] || { echo "  ext: something failed"; exit 1; }
echo "  ext: the extension road is green"

#!/bin/sh
# g/*.php byte for byte php's -- the two streams SEPARATELY and the exit code;
# r/*.php refused by name with exit 3. Exits 0 only when every one agreed.
#
# Carved from probes/t10/fixtures.sh, which is frozen and still runs against
# the probe's own copies. This one grades tests/g and tests/r against
# build/mc-php -- the living compiler.
#
# docs/review-backlog.md section 1, fourth finding: T7..T9's fixtures.sh merged
# the streams with `2>&1` and compared with `[ "$exp" = "$got" ]`. Two things
# were therefore not measured. A merge cannot tell stdout from stderr, so a
# diagnostic written to the wrong one passed; and `$(...)` strips EVERY
# trailing newline, so a program missing (or inventing) a final blank line
# passed as well. Here each stream goes to its own file and `cmp` grades it,
# so "byte for byte" is what it says.
set -u
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/.." && pwd)
cd "$root"
PHP=${PHP:-php}
P=tests
# HOW php is run here, and it is this repository's choice and not the
# machine's. A bare `php` reads the host's php.ini: a host whose
# display_errors is Off prints no warning where mc-php prints one, and ten
# fixtures "failed" on a CI runner for exactly that (2026-09-23).
#
# These four are the configuration mc-php IMPLEMENTS. It has no php.ini of its
# own, so its diagnostic channel is one fixed behaviour, and each of these was
# MEASURED against it rather than assumed:
#
#   display_errors=1      the diagnostic on stdout
#   log_errors=1          and the `PHP Warning:` copy on stderr. With 0 php
#                         stops writing it and mc-php does not, and this gate
#                         compares BOTH streams
#   html_errors=0         plain text
#   error_reporting=E_ALL which on php 8.5 is 30719 and INCLUDES E_DEPRECATED
#                         -- `E_ALL & ~E_DEPRECATED` is 22527 and made php drop
#                         a str_getcsv() deprecation that mc-php emits
#
# The GRID is a different thing and uses probes/t0/phpt-run.py's DEFAULT_INI,
# which sets log_errors=0 -- correct there, because the grid ignores stderr.
PHPINI="-d display_errors=1 -d log_errors=1 -d html_errors=0 -d error_reporting=E_ALL"
BIN=${BIN:-build/mc-php}
# A measurement takes a SNAPSHOT of the compiler (T7's note): an edit during
# the run cannot then corrupt it.
# Where the binaries go and what bounds it: tests/tmp.sh. This script
# did not set MCPHP_TMP at all before, so every fixture run left its binary
# (about 2 MB) in $TMPDIR for ever.
. "$here/tmp.sh"
mcphp_tmp_init mcphp-fx
tmp=$MCPHP_TMP
# a Windows executable keeps its suffix: the loader starts nothing without it
sfx=
case "$BIN" in *.exe) sfx=.exe ;; esac
cp "$BIN" "$tmp/mc-php$sfx"
MCPHP_BIN=$tmp/mc-php$sfx
export MCPHP_BIN
# The cleanup is the EXIT trap and the signal traps EXIT: a handler that
# only cleans up RETURNS, so an interrupted run carried on with its
# temporary directory already gone and ran the handler a second time on the
# way out.
trap 'rm -rf "$tmp"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

. "$here/lim.sh"

# One name for the binary, removed after each fixture: this loop is serial and
# it WAITS, so it is the process that can do it (mcphp.sh execs and cannot).
MCPHP_OUT=$tmp/fx.bin
export MCPHP_OUT
fail=0
ng=0; nok=0
for f in $P/g/*.php; do
    # `inc.php` is a HELPER another fixture requires, not a fixture: running
    # it on its own passed vacuously (php and mc-php both print nothing) and
    # it made the count 76 where there are 75 numbered fixtures. It is
    # covered by 08-require and 72-require-dir, which include it, and
    # d8check.py puts it in a regime of its own.
    case $(basename "$f") in inc.php) continue ;; esac
    ng=$((ng + 1))
    # php runs without ANY of the harness's own variables: they are
    # exported for mcphp.sh's benefit and mcphp.sh unsets all three before
    # the program runs, so leaving them here gave the two worlds different
    # environments for the same fixture.
    lim env -u MCPHP_OUT -u MCPHP_BIN -u MCPHP_TMP -u MCPHP__RC "$PHP" $PHPINI "$f" > "$tmp/p.out" 2> "$tmp/p.err"; pe=$?; pto=$timedout
    lim $P/mcphp.sh "$f" > "$tmp/m.out" 2> "$tmp/m.err"; me=$?; mto=$timedout
    rm -f "$MCPHP_OUT" "$MCPHP_OUT.exe" "$MCPHP_OUT.out" "$MCPHP_OUT.err"
    # A fixture that HANGS in both worlds leaves both streams empty and both
    # codes 124, which the comparison below would otherwise call agreement.
    # The ALARM says so, not the code: a fixture may legitimately exit(124).
    if [ "$pto" = yes ] || [ "$mto" = yes ]; then
        printf '  FAIL  %s (timed out: php %s, mc-php %s)\n' "$(basename "$f")" "$pe" "$me"
        fail=1
    elif cmp -s "$tmp/p.out" "$tmp/m.out" && cmp -s "$tmp/p.err" "$tmp/m.err" \
       && [ "$pe" = "$me" ]; then
        nok=$((nok + 1))
    else
        printf '  FAIL  %s (php exit %s, mc-php exit %s)\n' "$(basename "$f")" "$pe" "$me"
        cmp -s "$tmp/p.out" "$tmp/m.out" || {
            printf '    stdout differs:\n'
            diff -u "$tmp/p.out" "$tmp/m.out" | sed -n '3,12p' | sed 's/^/      /'
        }
        cmp -s "$tmp/p.err" "$tmp/m.err" || {
            printf '    stderr differs:\n'
            diff -u "$tmp/p.err" "$tmp/m.err" | sed -n '3,12p' | sed 's/^/      /'
        }
        fail=1
    fi
done
echo "  fixtures: $nok / $ng agree with php (stdout, stderr and the exit code)"
nr=0; nrok=0
for f in $P/r/*.php; do
    nr=$((nr + 1))
    # php's OWN half of a refusal fixture. `r/` is not a byte-for-byte pair:
    # the point of the file is that mc-php declines it BY NAME, and its
    # runtime half may need a directory it is not run from
    # (`d1-computed-include.php` requires a sibling). What makes it a
    # differential is that php accepts the source as php at all -- otherwise
    # "mc-php refuses what php accepts" is only half measured, and a typo
    # would read as a refusal.
    if ! env -u MCPHP_OUT -u MCPHP_BIN -u MCPHP_TMP -u MCPHP__RC "$PHP" $PHPINI -l "$f" > "$tmp/l.out" 2>&1; then
        printf '  FAIL  %-26s php will not parse it: %s\n' \
            "$(basename "$f")" "$(head -1 "$tmp/l.out")"
        fail=1
        continue
    fi
    lim $P/mcphp.sh "$f" > "$tmp/r.out" 2> "$tmp/r.err"; rc=$?
    rm -f "$MCPHP_OUT" "$MCPHP_OUT.exe" "$MCPHP_OUT.out" "$MCPHP_OUT.err"
    if [ "$timedout" = yes ]; then rc=timeout; fi
    msg=$(sed 's/^[^:]*:[0-9]*: //' "$tmp/r.err" | head -1)
    case "$rc:$msg" in
        3:*"is refused by design"*) nrok=$((nrok + 1)) ;;
        *) printf '  FAIL  %-26s exit %s: %s\n' "$(basename "$f")" "$rc" "$msg"; fail=1 ;;
    esac
done
echo "  refusals: $nrok / $nr parse under php and are named by mc-php, exit 3"
# The packed int array (src/packed.mc) is a LOWERING, and a differential only
# says the answers are php's -- a proof that silently never fires would pass
# it too. So the lowering is read back: every pk_* function of g/105 must
# hold its $x as the native buffer (an mc `uptr` local), and no esc_* function
# of g/106 may, each of those being one thing the proof must refuse.
"$MCPHP_BIN" --dump-ast $P/g/105-packed-int.php > "$tmp/pk.ast" 2>&1
"$MCPHP_BIN" --dump-ast $P/g/106-packed-fallback.php > "$tmp/pe.ast" 2>&1
pk=$(awk '/^FUNC.* name=f_pk_/ { f = $NF } /^FUNC/ && !/name=f_pk_/ { f = "" }
          f != "" && /VAR type=uptr name=v_x$/ { print f }' "$tmp/pk.ast" | sort -u | wc -l | tr -d ' ')
pn=$(grep -c '^FUNC.* name=f_pk_' "$tmp/pk.ast")
pe=$(awk '/^FUNC.* name=f_esc_/ { f = $NF } /^FUNC/ && !/name=f_esc_/ { f = "" }
          f != "" && /VAR type=uptr name=v_x$/ { print f }' "$tmp/pe.ast" | sort -u | tr '\n' ' ')
en=$(grep -c '^FUNC.* name=f_esc_' "$tmp/pe.ast")
if [ "$pn" -gt 0 ] && [ "$pk" = "$pn" ] && [ -z "$pe" ] && [ "$en" -gt 0 ]; then
    echo "  packed: $pk / $pn accepted in g/105, 0 / $en lowered in g/106"
else
    echo "  FAIL  packed: $pk / $pn accepted in g/105; lowered in g/106 where the proof must fail: ${pe:-none}"
    fail=1
fi
# src/opt.mc's concatenation windows: g/112's every substr() is a piece of a
# concatenation, so its compiled functions have php_str_catwN and not one php_substr
# (a fusion that never fired would pass the differential just as well).
"$MCPHP_BIN" --dump-ast $P/g/112-concat-windows.php > "$tmp/cw.ast" 2>&1
set -- $(awk '/^FUNC/ { u = ($0 ~ / name=(f_|main$)/) }
               u && /CALL .*name=php_str_catw/ { w++ } u && /CALL .*name=php_substr$/ { n++ }
               END { print w + 0, n + 0 }' "$tmp/cw.ast")
if [ "$1" = 7 ] && [ "$2" = 0 ]; then
    echo "  windows: g/112's 7 concatenations read their substr() pieces in place"
else
    echo "  FAIL  windows: g/112's lowering has $1 php_str_catw and $2 php_substr (want 7 and 0)"
    fail=1
fi
# src/opt.mc's inlining: in g/113's run() every call but the recursive one
# is a copy, so its lowering calls f_fact and no other php function.
"$MCPHP_BIN" --dump-ast $P/g/113-inline.php > "$tmp/in.ast" 2>&1
il=$(awk '/^FUNC/ { u = ($0 ~ / name=f_run$/) } u && /CALL .*name=f_/ { print $NF }' "$tmp/in.ast" | sort -u | tr '\n' ' ')
if [ "$il" = "name=f_fact " ]; then
    echo "  inlining: g/113's run() calls only its recursive function; the rest are copies"
else
    echo "  FAIL  inlining: g/113's run() still calls: $il(want only name=f_fact)"
    fail=1
fi
# src/mach.mc's peepholes, read back on BOTH machines whatever the host (the
# dump takes --machine=): in g/114's sums() a constant that fits is the
# immediate (4095) and one that does not stays a register (4096), `$i < $n`
# feeding its loop's exit is one conditional branch, and a global's store
# carries its page offset. The differential passes without any of it.
set -- $("$MCPHP_BIN" --machine=arm64 --dump-asm $P/g/114-peephole.php 2>&1 | awk '
    /^_/ { u = ($0 == "_f_sums:") }
    u && /add x9, x9, #4095$/ { a++ } u && /movz x10, #4096$/ { b++ }
    u && /cmp x9, x10$/ { getline; if ($1 == "b.ge") c++ }
    /@PAGEOFF\]$/ { d++ }
    END { print a + 0, b + 0, c + 0, (d > 0) }')
set -- "$@" $("$MCPHP_BIN" --machine=x86_64 --dump-asm $P/g/114-peephole.php 2>&1 | awk '
    /^_/ { u = ($0 == "_f_sums:") }
    u && /lea r8, \[r8\+4095\]$/ { a++ } u && /lea r8, \[r8-4096\]$/ { b++ }
    u && /cmp r8, r9$/ { getline; if ($1 == "jge") c++ }
    END { print a + 0, b + 0, c + 0 }')
if [ "$*" = "1 1 1 1 1 1 1" ]; then
    echo "  peephole: g/114 has its immediates, one branch per loop exit and a global's page offset, on arm64 and x86-64"
else
    echo "  FAIL  peephole: g/114's dump reads $* (want 1 1 1 1 1 1 1: arm64 add #4095, movz #4096, b.ge, @PAGEOFF]; x86-64 lea +4095, lea -4096, jge)"
    fail=1
fi
# The one place the packed lowering is NOT php: an int that overflows on an
# element. php makes a float; a native int cannot hold one, so it is a named
# ArithmeticError and never a wrapped int. Not a differential -- php's answer
# is the float -- so the refusal's text is what is checked.
cat > "$tmp/pko.php" <<'PKO'
<?php
function pko(int $n): string {
    $x = [];
    $x[] = $n;
    try { return (string) ($x[0] * 3); } catch (ArithmeticError $e) { return get_class($e) . ": " . $e->getMessage(); }
}
function pkn(int $n): string {
    $x = [];
    $x[] = $n;
    try { return (string) (-($x[0] + 1) * 2); } catch (ArithmeticError $e) { return get_class($e); }
}
// the store is not reached when the value throws: $x is as it was
function pks(int $n): string {
    $x = [];
    $x[] = $n;
    try { $x[] = $x[0] * 3; } catch (ArithmeticError $e) { }
    try { $x[0] = $x[0] + $x[0]; } catch (ArithmeticError $e) { }
    return count($x) . " " . $x[0];
}
echo pko(5), "\n", pko(PHP_INT_MAX), "\n", pkn(5), " ", pkn(PHP_INT_MAX - 1), "\n";
// PHP_INT_MIN * -1 in both orders: the one product whose DIVISION check
// would trap on x86-64 (idiv of PHP_INT_MIN by -1); it must be the named error
function pkm(int $n, int $o): string {
    $x = [];
    $x[] = $n;
    try { if ($o) return (string) (-1 * $x[0]); return (string) ($x[0] * -1); } catch (ArithmeticError $e) { return "A"; }
}
// `throw` of an element product that overflows is that ArithmeticError,
// not "Can only throw objects" over the wrapped value
function pkt(int $n): string {
    $x = [];
    $x[] = $n;
    try { throw $x[0] * 3; } catch (ArithmeticError $e) { return "A"; } catch (Error $e) { return "E"; }
}
echo pks(5), " ", pks(PHP_INT_MAX), "\n";
echo pkt(5), " ", pkt(PHP_INT_MAX), "\n";
echo pkm(5, 0), " ", pkm(5, 1), " ", pkm(PHP_INT_MIN, 0), " ", pkm(PHP_INT_MIN, 1), "\n";
PKO
lim $P/mcphp.sh "$tmp/pko.php" > "$tmp/pko.out" 2> "$tmp/pko.err"
rm -f "$MCPHP_OUT" "$MCPHP_OUT.exe" "$MCPHP_OUT.out" "$MCPHP_OUT.err"
pko=$(tr -d '\r' < "$tmp/pko.out")
pkw=$(printf '15\nArithmeticError: mc-php: an int overflowed in * on a packed array'"'"'s element: php would make a float here, and this native int cannot hold one (docs/plan.md, the packed int array)\n-12 ArithmeticError\n2 10 1 9223372036854775807\nE A\n-5 -5 A A')
if [ "$pko" = "$pkw" ]; then
    echo "  packed: an overflow on an element is the named ArithmeticError, not a wrapped int, and no store"
else
    echo "  FAIL  packed overflow: want [$pkw], got [$pko]"; fail=1
fi
# A size near PHP_INT_MAX on the program road is "arena exhausted", never a
# bump past the arena: `a + n` wrapped and moved the top to a wild address
# (SIGBUS on main). php answers with its memory-limit fatal, so this is not a
# differential either -- the refusal's text is what is checked.
printf '<?php\n$s = str_repeat("a", 100);\necho strlen(str_pad($s, PHP_INT_MAX - 100, "x")), "\\n";\n' > "$tmp/big.php"
lim $P/mcphp.sh "$tmp/big.php" > "$tmp/big.out" 2> "$tmp/big.err"
rm -f "$MCPHP_OUT" "$MCPHP_OUT.exe" "$MCPHP_OUT.out" "$MCPHP_OUT.err"
if tr -d '\r' < "$tmp/big.err" | grep -q '^mc-php: arena exhausted$'; then
    echo "  arena: a size near PHP_INT_MAX is 'arena exhausted', not a wild bump"
else
    echo "  FAIL  arena: want 'mc-php: arena exhausted' on stderr, got [$(cat "$tmp/big.err")]"; fail=1
fi
exit $fail

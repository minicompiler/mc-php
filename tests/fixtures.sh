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
# c/*.php: C's behaviour (docs/semantics.md), where php's differs, so each
# is graded against its own recording and not against php: NAME.out is
# stdout, NAME.err stderr (empty when absent; the path of the file is
# spelled tests/c/NAME.php whatever the host wrote) and NAME.code the exit
# code (0 when absent). A NAME.toml beside it is the project file's own
# tables (`[php] checked_reads = true`), and tests/mcphp.sh builds it the
# project road.
nc=0; ncok=0
host_os=$("$MCPHP_BIN" --host | sed -n 's/^os //p' | tr -d '\r')
for f in $P/c/*.php; do
    nc=$((nc + 1))
    b=${f%.php}
    lim $P/mcphp.sh "$f" > "$tmp/c.out" 2> "$tmp/c.err"; ce=$?
    rm -f "$MCPHP_OUT" "$MCPHP_OUT.exe" "$MCPHP_OUT.out" "$MCPHP_OUT.err"
    tr -d '\r' < "$tmp/c.out" > "$tmp/c.o"
    tr -d '\r' < "$tmp/c.err" | sed -e 's#(.*tests[/\\]c[/\\]#(tests/c/#' -e 's#^[^ (]*tests[/\\]c[/\\]#tests/c/#' > "$tmp/c.e"
    # NAME.win.{out,err,code}: what the file answers on Windows instead
    wb=$b
    [ "$host_os" = windows ] && [ -f "$b.win.code" ] && wb=$b.win
    want=0; [ -f "$wb.code" ] && want=$(cat "$wb.code")
    [ -f "$wb.err" ] && cp "$wb.err" "$tmp/c.we" || : > "$tmp/c.we"
    [ -f "$wb.out" ] && cp "$wb.out" "$tmp/c.wo" || : > "$tmp/c.wo"
    if [ "$timedout" != yes ] && [ "$ce" = "$want" ] && cmp -s "$tmp/c.wo" "$tmp/c.o" && cmp -s "$tmp/c.we" "$tmp/c.e"; then
        ncok=$((ncok + 1))
    else
        printf '  FAIL  c/%s (exit %s, want %s)\n' "$(basename "$f")" "$ce" "$want"
        diff "$tmp/c.wo" "$tmp/c.o" | sed -n '1,6p' | sed 's/^/      /'
        diff "$tmp/c.we" "$tmp/c.e" | sed -n '1,6p' | sed 's/^/      /'
        fail=1
    fi
done
echo "  C behaviour: $ncok / $nc answer their recording (wrap, in-range reads, a hash, checked_reads, #[Extern], threads)"
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
# src/opt.mc's runtime pass: in g/115 the byte read and the packed element
# read and write are copied into acc() and bytes() -- no call to the routine
# is left, only to its slow half -- and the unwinding is one tail the checks
# break out to (acc()'s two loops plus the tail's own: `break 3`).
"$MCPHP_BIN" --dump-ast $P/g/115-hot-paths.php > "$tmp/hp.ast" 2>&1
set -- $(awk '/^FUNC/ { u = ($0 ~ / name=f_(acc|bytes)$/) }
               u && /CALL .*name=php_(pk_get_c|pk_set|str_byte|str_byte_c)$/ { f++ }
               u && /CALL .*name=php_pk_get_c_slow$/ { s++ } u && /BREAK val=3$/ { b++ }
               END { print f + 0, (s > 0), (b > 0) }' "$tmp/hp.ast")
if [ "$*" = "0 1 1" ]; then
    echo "  runtime copies: g/115's byte and element reads and writes are inline, their slow halves calls, one unwind tail"
else
    echo "  FAIL  runtime copies: g/115's lowering reads $* (want 0 1 1: no php_pk_get_c/pk_set/str_byte call, a php_pk_get_c_slow, a break to the tail)"
    fail=1
fi
# decimal-2x's lowerings, read back from g/116 compiled the counting way
# (MCPHP_RC=check, so src/rc.mc runs as on the extension road): fmt() builds
# its answer as one rope, acc()'s array is fixed (no hash test, no bound),
# pad() is one string, fresh() writes its buffer in place with the slow half
# the only call, and sign()'s short circuits are mc's && and || again (no
# temporary is assigned; sc()'s right sides are calls, which keep theirs). The differential passes without any of it.
MCPHP_RC=check "$MCPHP_BIN" --dump-ast $P/g/116-lowered-forms.php > "$tmp/lf.ast" 2>&1
set -- $(awk '/^FUNC/ { f = $NF }
    f == "name=f_fmt" && /CALL .*name=php_str_rope$/ { r++ } f == "name=f_fmt" && /CALL .*name=php_str_(concat|catw2)$/ { c++ }
    f == "name=f_acc" && /CALL .*name=php_pk_(get_c|set|get_c_slow|set_slow)$/ { p++ }
    f == "name=f_pad" && /CALL .*name=php_str_catrep$/ { d++ }
    f == "name=f_fresh" && /CALL .*name=php_str_setb_f_slow$/ { w++ } f == "name=f_fresh" && /CALL .*name=php_str_setb(_own)?$/ { o++ }
    f == "name=f_sign" && /ASSIGN name=.*phs_/ { t++ }
    END { print r + 0, c + 0, p + 0, (d > 0), (w > 0), o + 0, t + 0 }' "$tmp/lf.ast")
# A Windows-hosted compiler reads no environment (below, the out-of-line
# block says why), so MCPHP_RC=check cannot turn the counting on there and
# fresh() keeps php's write: that host checks the other four.
want="1 0 0 1 1 0 0"; fb="fresh buffer"
if [ "$sfx" = .exe ]; then want="1 0 0 1 0 1 0"; fb="php's write in fresh() (the counting switch is not readable on a Windows host)"; fi
if [ "$*" = "$want" ]; then
    echo "  lowered forms: g/116's rope, fixed array, pad, $fb and folded short circuits"
else
    echo "  FAIL  lowered forms: g/116 reads $* (want $want: one rope and no concatenation, no packed call, a pad, a fresh buffer's slow half and no php write, no short-circuit temporary)"
    fail=1
fi
# src/mach.mc's peepholes, read back on BOTH machines whatever the host (the
# dump takes --machine=): in g/114's sums() a constant that fits is the
# immediate (4095) and one that does not stays a register (4096), `$i < $n`
# feeding its loop's exit is one conditional branch, and a global's store
# carries its page offset. The differential passes without any of it. The
# branch is counted as present, not once: with MCPHP_RC=check the pool's own
# drains add more fused compares to the same function.
set -- $("$MCPHP_BIN" --machine=arm64 --dump-asm $P/g/114-peephole.php 2>&1 | awk '
    /^_/ { u = ($0 == "_f_sums:") }
    u && /add x9, x9, #4095$/ { a++ } u && /movz x10, #4096$/ { b++ }
    u && /cmp x9, x10$/ { getline; if ($1 == "b.ge") c++ }
    /@PAGEOFF\]$/ { d++ }
    END { print a + 0, b + 0, (c > 0), (d > 0) }')
set -- "$@" $("$MCPHP_BIN" --machine=x86_64 --dump-asm $P/g/114-peephole.php 2>&1 | awk '
    /^_/ { u = ($0 == "_f_sums:") }
    u && /lea r8, \[r8\+4095\]$/ { a++ } u && /lea r8, \[r8-4096\]$/ { b++ }
    u && /cmp r8, r9$/ { getline; if ($1 == "jge") c++ }
    END { print a + 0, b + 0, (c > 0) }')
if [ "$*" = "1 1 1 1 1 1 1" ]; then
    echo "  peephole: g/114 has its immediates, one branch per loop exit and a global's page offset, on arm64 and x86-64"
else
    echo "  FAIL  peephole: g/114's dump reads $* (want 1 1 1 1 1 1 1: arm64 add #4095, movz #4096, b.ge, @PAGEOFF]; x86-64 lea +4095, lea -4096, jge)"
    fail=1
fi
# decimal-2x's second round, read back on arm64 whatever the host: in g/118
# a division by a constant is a multiply-high and no sdiv (P12) whose shift is
# the immediate form (P13), the FIXED array's `$a[K] = $a[K] + E` is
# ph_addm64 (src/lvalue.mc), its element address one add with a shifted
# operand (P13) and its byte read's constants the load's own offset
# (src/opt.mc's ph_ac_walk). The differential passes without any of it.
set -- $("$MCPHP_BIN" --machine=arm64 --dump-asm $P/g/118-divk-shift-rmw.php 2>&1 | awk '
    /^_/ { u = $0 }
    u == "_f_divs:" && /smulh/ { a++ } u == "_f_divs:" && /sdiv/ { b++ }
    u == "_f_divs:" && /asr x[0-9]+, x[0-9]+, #2$/ { c++ }
    u == "_f_rmw:" && /, lsl #3$/ { d++ } u == "_f_rmw:" && /ldrb w[0-9]+, \[x[0-9]+, #23\]$/ { e++ }
    END { print (a > 0), b + 0, (c > 0), (d > 0), (e > 0) }')
set -- "$@" $("$MCPHP_BIN" --dump-ast $P/g/118-divk-shift-rmw.php 2>&1 | grep -c 'name=ph_addm64')
if [ "$*" = "1 0 1 1 1 2" ]; then
    echo "  second round: g/118's multiply-high, immediate shifts, shifted add, load offset and ph_addm64"
else
    echo "  FAIL  second round: g/118 reads $* (want 1 0 1 1 1 2: smulh and no sdiv, asr #2, an add lsl #3, ldrb [x, #23], two ph_addm64)"
    fail=1
fi
# P15: a branch on a && or || branches on its terms, so a whole program's
# arm64 dump keeps a cset only where a boolean is a VALUE -- 38 in g/119's,
# where mc's value form of every && in the runtime made about 500. The
# differential passes without it.
set -- $("$MCPHP_BIN" --machine=arm64 --dump-asm $P/g/119-branch-terms.php 2>&1 | awk '/cset/ { n++ } END { print n + 0 }')
if [ "${1:-999}" -lt 100 ]; then
    echo "  branch terms: g/119's program keeps $1 csets on arm64, each one a boolean value"
else
    echo "  FAIL  branch terms: g/119's arm64 dump has ${1:-?} csets (want under 100: a branch on && and || is on its terms)"
    fail=1
fi
# src/mach.mc's P10, read back on the three machines: every slow half in g/115's
# acc() -- the element read of a hash, the store outside the array -- is
# laid out after the function's ret, and the fast path falls through its
# guards. MCPHP_LAYOUT=0 is the off switch and puts every one back in line; the
# "on" half unsets it, so this reads the same under a run with the switch off.
set --
for m in arm64 x86_64 x86_64-win; do
    for e in "-u MCPHP_LAYOUT" "MCPHP_LAYOUT=0"; do
        set -- "$@" $(env $e "$MCPHP_BIN" --machine=$m --dump-asm $P/g/115-hot-paths.php 2>&1 | awk '
            /^_/ { u = ($0 == "_f_acc:"); r = 0 } u && / ret$/ { r = 1 }
            u && /_slow$/ { if (r) a++; else b++ }
            END { print ((a > 0 && b == 0) ? "out" : ((a == 0 && b > 0) ? "in" : "mixed")) }')
    done
done
# A Windows-hosted compiler reads no environment (mc's host_environ() is 0
# there, M38's Decision 5), so the switch cannot reach it and the off half
# reads "out" like the on half: that host checks the layout alone.
want="out in out in out in"; off="and in line with MCPHP_LAYOUT=0"
if [ "$sfx" = .exe ]; then want="out out out out out out"; off="(the switch is not readable on a Windows host)"; fi
if [ "$*" = "$want" ]; then
    echo "  out of line: g/115's slow halves are after the ret on arm64, x86-64 and Win64, $off"
else
    echo "  FAIL  out of line: g/115's slow halves read $* (want $want: arm64, x86_64, x86_64-win, each on and off)"
    fail=1
fi
# P10's reach. mc's arm64 encoder refuses any branch past 0x1ffff words
# ("branch too far") and a moved region's branch spans the whole function, one
# `b` per region longer than main's layout. This function is 131 114 words,
# its longest branch on main 131 067 (it compiles) and, with the region
# moved, 131 090 (it did not): the move has to stand down for it. Generated
# rather than checked in, 1600 lines of xor after one loop with a string read.
# The sizes are the plain lowering's (MCPHP_RC=check makes it larger than main
# can compile), so it is compiled without that switch.
awk 'BEGIN { print "<?php"; print "function big(string $s, int $t): int {"
    print "    for ($i = 0; $i < strlen($s); $i++) { $t = $t + ord($s[$i]); }"
    for (i = 0; i < 1598; i++) { printf "    $t = $t"
        for (k = 1; k <= 40; k++) printf " ^ %d", (i * 40 + k) % 4000 + 1; print ";" }
    print "    $t = $t;"; print "    return $t;"; print "}"
    print "echo big(\"abcdefg\", 5), \"\\n\";" }' > "$tmp/far.php"
if env -u MCPHP_RC "$MCPHP_BIN" --backend=macho "$tmp/far.php" -o "$tmp/far.o" > "$tmp/far.err" 2>&1; then
    echo "  reach: a 131 114-word function whose moved slow half would be out of a branch's range compiles, laid out as main lays it"
else
    echo "  FAIL  reach: $(head -1 "$tmp/far.err") (a function main compiles)"
    fail=1
fi
# An int that overflows on a packed element wraps as C's does
# (docs/semantics.md): php would make a float, so this is not a differential
# and the answers are checked. Nothing is thrown -- so `throw` of the product
# is php's "Can only throw objects" over an int, and each store is made.
cat > "$tmp/pkc.php" <<'PKC'
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
function pks(int $n): string {
    $x = [];
    $x[] = $n;
    try { $x[] = $x[0] * 3; } catch (ArithmeticError $e) { }
    try { $x[0] = $x[0] + $x[0]; } catch (ArithmeticError $e) { }
    return count($x) . " " . $x[0];
}
echo pko(5), "\n", pko(PHP_INT_MAX), "\n", pkn(5), " ", pkn(PHP_INT_MAX - 1), "\n";
// PHP_INT_MIN * -1 in both orders: the one product whose division would trap
// on x86-64 (idiv of PHP_INT_MIN by -1); a multiplication wraps and does not
function pkm(int $n, int $o): string {
    $x = [];
    $x[] = $n;
    try { if ($o) return (string) (-1 * $x[0]); return (string) ($x[0] * -1); } catch (ArithmeticError $e) { return "A"; }
}
function pkt(int $n): string {
    $x = [];
    $x[] = $n;
    try { throw $x[0] * 3; } catch (ArithmeticError $e) { return "A"; } catch (Error $e) { return "E"; }
}
echo pks(5), " ", pks(PHP_INT_MAX), "\n";
echo pkt(5), " ", pkt(PHP_INT_MAX), "\n";
echo pkm(5, 0), " ", pkm(5, 1), " ", pkm(PHP_INT_MIN, 0), " ", pkm(PHP_INT_MIN, 1), "\n";
PKC
lim $P/mcphp.sh "$tmp/pkc.php" > "$tmp/pkc.out" 2> "$tmp/pkc.err"
rm -f "$MCPHP_OUT" "$MCPHP_OUT.exe" "$MCPHP_OUT.out" "$MCPHP_OUT.err"
pkc=$(tr -d '\r' < "$tmp/pkc.out")
pcw=$(printf '15\n9223372036854775805\n-12 2\n2 10 2 -2\nE E\n-5 -5 -9223372036854775808 -9223372036854775808')
if [ "$pkc" = "$pcw" ]; then
    echo "  packed: an overflow on an element wraps as C's does, nothing is thrown, and every store is made"
else
    echo "  FAIL  packed overflow: want [$pcw], got [$pkc]"; fail=1
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
# `namespace` and `use` are declarations of a file's top level: php refuses
# them in a function body or a block with a parse error, and a namespace
# declaration inside a braced one as "Cannot mix". mc-php refuses all three
# while compiling, and the namespace in effect does not change first.
nsr=0
for c in 'function f() { namespace inner; }|namespace' 'function f() { use Foo\Bar; }|use' \
         'if (true) { use Foo; }|use' 'namespace A { namespace B; }|braced'; do
    src=${c%|*}; want=${c##*|}
    printf '<?php\n%s\necho 1;\n' "$src" > "$tmp/nsr.php"
    if env -u MCPHP_RC "$MCPHP_BIN" --backend=macho "$tmp/nsr.php" -o "$tmp/nsr.o" > "$tmp/nsr.err" 2>&1; then
        echo "  FAIL  namespace scope: [$src] compiled"; nsr=1; fail=1
    elif [ "$want" = braced ]; then
        grep -q 'a namespace declaration inside a braced namespace' "$tmp/nsr.err" ||
            { echo "  FAIL  namespace scope: [$src] said [$(head -1 "$tmp/nsr.err")]"; nsr=1; fail=1; }
    else
        grep -q "a declaration of a file's top level, not a statement: $want" "$tmp/nsr.err" ||
            { echo "  FAIL  namespace scope: [$src] said [$(head -1 "$tmp/nsr.err")]"; nsr=1; fail=1; }
    fi
done
[ "$nsr" = 0 ] && echo "  namespace scope: namespace and use in a function or a block, and a namespace inside a braced one, refused while compiling"
# #[Extern] (src/extern.mc) refuses what it cannot read as a C declaration,
# while compiling: on something that is not a function (a class member, a
# statement in a body, a namespace, a use, a closure -- refused at the
# attribute, so it never reaches a later declaration), a runtime function's
# name, a library the program road does not link, an errno that is not
# `errno(): int`, and a body that is not empty
xr=0
for c in 'class A { #[Extern("c")] function f(): int {} }|on something that is not a function' \
         'function f() { #[Extern("c")] echo 1; } function g(): int { return 2; }|on something that is not a function' \
         '#[Extern("c")] namespace A; function g(): int { return 2; }|on something that is not a function' \
         '#[Extern("c")] use A\B; function g(): int { return 2; }|on something that is not a function' \
         '$f = #[Extern("c")] function () {};|on something that is not a function' \
         '#[Extern("c")] function php_alloc(Ptr $n): Ptr {}|one of the runtime'"'"'s own functions' \
         '#[Extern("c", name: "1atoi")] function f(string $s): int {}|is not a C identifier: 1atoi' \
         '#[Extern("curl")] function curl_easy_init(): Ptr {}|library the program road does not link' \
         '#[Extern("c")] function errno(int $e): int {}|errno takes no parameter and returns int' \
         '#[Extern("c")] function abs(int $a): int { return 1; }|body is the library'"'"'s: leave it empty'; do
    src=${c%|*}; want=${c##*|}
    printf '<?php\n%s\necho 1;\n' "$src" > "$tmp/xr.php"
    if env -u MCPHP_RC "$MCPHP_BIN" --backend=macho "$tmp/xr.php" -o "$tmp/xr.o" > "$tmp/xr.err" 2>&1; then
        echo "  FAIL  #[Extern]: [$src] compiled"; xr=1; fail=1
    elif ! grep -q "$want" "$tmp/xr.err"; then
        echo "  FAIL  #[Extern]: [$src] said [$(head -1 "$tmp/xr.err")]"; xr=1; fail=1
    fi
done
[ "$xr" = 0 ] && echo "  #[Extern]: on what is not a function, a runtime name, a bad name:, an unlinked library, errno misdeclared and a body, refused while compiling"
# two aliases of one C symbol (c/08's dec and hex, both `name: 'strtol'`) are
# ONE C declaration
nx=$("$MCPHP_BIN" --dump-ast $P/c/08-extern.php 2>/dev/null | grep -c '^EXTERN.* name=strtol$')
if [ "$nx" = 1 ]; then echo "  #[Extern]: two aliases of strtol, one C declaration"
elif [ "$host_os" != windows ]; then echo "  FAIL  #[Extern]: two aliases of strtol made $nx C declarations"; fail=1; fi
exit $fail

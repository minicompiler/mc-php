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
    lim env -u MCPHP_OUT -u MCPHP_BIN -u MCPHP_TMP "$PHP" $PHPINI "$f" > "$tmp/p.out" 2> "$tmp/p.err"; pe=$?; pto=$timedout
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
    if ! env -u MCPHP_OUT -u MCPHP_BIN -u MCPHP_TMP "$PHP" $PHPINI -l "$f" > "$tmp/l.out" 2>&1; then
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
exit $fail

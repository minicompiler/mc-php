#!/bin/sh
# g/*.php byte for byte php's -- the two streams SEPARATELY and the exit code;
# r/*.php refused by name with exit 3. Exits 0 only when every one agreed.
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
root=$(CDPATH= cd -- "$here/../.." && pwd)
cd "$root"
PHP=${PHP:-php}
P=probes/t10
# A measurement takes a SNAPSHOT of the compiler (T7's note): an edit during
# the run cannot then corrupt it.
# Where the binaries go and what bounds it: probes/t10/tmp.sh. This script
# did not set MCPHP_TMP at all before, so every fixture run left its binary
# (about 2 MB) in $TMPDIR for ever.
. "$here/tmp.sh"
mcphp_tmp_init mcphp-fx
tmp=$MCPHP_TMP
cp $P/mc-php "$tmp/mc-php"
MCPHP_BIN=$tmp/mc-php
export MCPHP_BIN
# The cleanup is the EXIT trap and the signal traps EXIT: a handler that
# only cleans up RETURNS, so an interrupted run carried on with its
# temporary directory already gone and ran the handler a second time on the
# way out.
trap 'rm -rf "$tmp"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# A fixture that loops for ever must not hang the gate with no output. perl is
# on every host that has php; `timeout` is not on macOS.
# perl forks rather than execs, so the alarm kills the CHILD and this shell
# never prints "Alarm clock" into the stderr being compared.
# `timedout` is set by the wrapper itself and not read off the child's exit
# status: a fixture may legitimately `exit(124)`, and treating that code as
# the alarm failed a pair whose streams and statuses agreed. The marker file
# is the alarm's own signal, written before the wrapper exits.
timedout=""
lim() {
    rm -f "$tmp/alarm"
    perl -e 'my $t = shift; my $mark = shift;
             my $p = fork; exec(@ARGV) or exit 127 if !$p;
             $SIG{ALRM} = sub { kill 9, $p; waitpid $p, 0;
                                open my $fh, ">", $mark; close $fh; exit 124 };
             alarm $t; waitpid $p, 0;
             # A child killed by a SIGNAL has its number in the low seven
             # bits and nothing in the high byte, so `$? >> 8` reported 0:
             # a fixture that SEGFAULTED came out as a clean exit 0 and
             # could pass the comparison. 128 + n is the shell convention
             # and is a code php never answers.
             exit(($? & 127) ? 128 + ($? & 127) : $? >> 8)' 30 "$tmp/alarm" "$@"
    _rc=$?
    timedout=no
    if [ -f "$tmp/alarm" ]; then timedout=yes; fi
    return $_rc
}

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
    lim "$PHP" "$f" > "$tmp/p.out" 2> "$tmp/p.err"; pe=$?; pto=$timedout
    lim $P/mcphp.sh "$f" > "$tmp/m.out" 2> "$tmp/m.err"; me=$?; mto=$timedout
    rm -f "$MCPHP_OUT" "$MCPHP_OUT.out" "$MCPHP_OUT.err"
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
    lim $P/mcphp.sh "$f" > "$tmp/r.out" 2> "$tmp/r.err"; rc=$?
    rm -f "$MCPHP_OUT" "$MCPHP_OUT.out" "$MCPHP_OUT.err"
    if [ "$timedout" = yes ]; then rc=timeout; fi
    msg=$(sed 's/^[^:]*:[0-9]*: //' "$tmp/r.err" | head -1)
    case "$rc:$msg" in
        3:*"is refused by design"*) nrok=$((nrok + 1)) ;;
        *) printf '  FAIL  %-26s exit %s: %s\n' "$(basename "$f")" "$rc" "$msg"; fail=1 ;;
    esac
done
echo "  refusals: $nrok / $nr named, exit 3"
exit $fail

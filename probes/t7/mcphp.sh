#!/bin/sh
# Executor B for the phpt grid (probes/t0/phpt-run.py's protocol):
#
#     probes/t7/mcphp.sh FILE.php [ARGS...]
#
# stdin is the test's --STDIN-- section, the environment carries --ENV--.
# Compile the file with the taught compiler and run the binary; the process
# exits with the PROGRAM's status, except:
#
#   3   a named refusal -- `mc-php: <what> is refused by design (docs/plan.md
#       D<n>)`. That is the grid's third column and it is a DESIGN answer, not
#       a failure: docs/plan.md D1/D4/D5/D6 and T5's own named limits.
#   2   an ordinary compile error (a construct the compiler does not parse, an
#       mc diagnostic): not a refusal, not a run.
#
# The refusal is recognised by the message and not by a compiler exit code,
# because mc's err_at always exits 1: the compiler is mc's, the taxonomy is
# this repository's.
set -u
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
MCPHP=${MCPHP_BIN:-$here/mc-php}
[ -x "$MCPHP" ] || { echo "mcphp.sh: no $MCPHP -- run probes/t7/run.sh" >&2; exit 2; }

src=$1
shift

# The binaries go in one directory the caller sweeps (MCPHP_TMP), because the
# shell EXECs the program below and so cannot clean up after it.
dir=${MCPHP_TMP:-${TMPDIR:-/tmp}}
tmp=$dir/mcphp.$$.$(basename "$src" .php)
err=$tmp.err

# Both of the compiler's streams are captured, because a php COMPILE-TIME
# `Fatal error:` is written to BOTH in php's own order -- the stderr form
# first -- and a shell that let stdout through live could not reproduce it.
out=$tmp.out
"$MCPHP" --exe "$src" -o "$tmp" > "$out" 2> "$err"
rc=$?
if [ "$rc" != 0 ]; then
    cat "$err" >&2
    cat "$out"
    # 255 is a php compile-time fatal: php reports those while parsing too,
    # and exits 255. The text is already written; passing the code through is
    # what makes the grid compare it.
    [ "$rc" = 255 ] && exit 255
    grep -q 'is refused by design' "$err" && exit 3
    exit 2
fi

rm -f "$err" "$out"
# EXEC, so this shell BECOMES the program: python's subprocess timeout kills
# the process it spawned, and a program that loops for ever must be that same
# process. Without the exec the timeout killed the shell and left the binary
# spinning -- eleven of them had accumulated across three grid runs before
# this was measured. The binary is left behind for the caller to sweep.
exec "$tmp" "$@"

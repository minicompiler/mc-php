#!/bin/sh
# Executor B for the phpt grid (probes/t0/phpt-run.py's protocol):
#
#     probes/t5/mcphp.sh FILE.php [ARGS...]
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
[ -x "$MCPHP" ] || { echo "mcphp.sh: no $MCPHP -- run probes/t5/run.sh" >&2; exit 2; }

src=$1
shift

tmp=${TMPDIR:-/tmp}/mcphp.$$.$(basename "$src" .php)
err=$tmp.err
trap 'rm -f "$tmp" "$err"' EXIT INT TERM

if ! "$MCPHP" --exe "$src" -o "$tmp" 2> "$err"; then
    cat "$err" >&2
    grep -q 'is refused by design' "$err" && exit 3
    exit 2
fi
"$tmp" "$@"
exit $?

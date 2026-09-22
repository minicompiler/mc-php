#!/bin/sh
# Executor B for the phpt grid (probes/t0/phpt-run.py's protocol):
#
#     probes/t10/mcphp.sh FILE.php [ARGS...]
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
[ -x "$MCPHP" ] || { echo "mcphp.sh: no $MCPHP -- run probes/t10/run.sh" >&2; exit 2; }

src=$1
shift

# Where the binary goes. The CALLER names it through MCPHP_OUT when it can,
# because the caller is the process that WAITS for this one and so is the only
# one that knows when the file is dead: the `exec` at the bottom means this
# shell cannot delete it itself. Without MCPHP_OUT they pile up in MCPHP_TMP
# until its sweeper collects them, which at 37 tests/s is about 3000 binaries
# (6 GB) live at once -- that is what filled the boot volume at 20000 of
# 21395 tests. The fallback is kept so a direct call still works.
if [ -n "${MCPHP_OUT:-}" ]; then
    tmp=$MCPHP_OUT
else
    dir=${MCPHP_TMP:-${TMPDIR:-/tmp}}
    tmp=$dir/mcphp.$$.$(basename "$src" .php)
fi
err=$tmp.err

# Both of the compiler's streams are captured, because a php COMPILE-TIME
# `Fatal error:` is written to BOTH in php's own order -- the stderr form
# first -- and a shell that let stdout through live could not reproduce it.
out=$tmp.out
# The compiler runs in the BACKGROUND and is waited for, so a signal can
# reach it. The caller's timeout kills this wrapper; without this the
# compiler kept going, kept writing the binary, and left exactly the orphan
# the temporary-directory bound exists to prevent.
"$MCPHP" --exe "$src" -o "$tmp" > "$out" 2> "$err" &
mcpid=$!
trap 'kill -9 $mcpid 2>/dev/null; rm -f "$err" "$out" "$tmp"; exit 143' TERM
trap 'kill -9 $mcpid 2>/dev/null; rm -f "$err" "$out" "$tmp"; exit 130' INT
wait $mcpid
rc=$?
trap - TERM INT
if [ "$rc" != 0 ]; then
    cat "$err" >&2
    cat "$out"
    # 255 is a php compile-time fatal: php reports those while parsing too,
    # and exits 255. The text is already written; passing the code through is
    # what makes the grid compare it.
    if [ "$rc" = 255 ]; then rm -f "$err" "$out" "$tmp"; exit 255; fi
    if grep -q 'is refused by design' "$err"; then rm -f "$err" "$out" "$tmp"; exit 3; fi
    rm -f "$err" "$out" "$tmp"
    exit 2
fi

rm -f "$err" "$out"
# The wrapper's own scratch name is not the PROGRAM's business: the oracle
# runs without it, so a .phpt that reads getenv('MCPHP_OUT') or enumerates
# its environment would see two different environments and be classified on
# the harness rather than on itself.
unset MCPHP_OUT MCPHP_BIN MCPHP_TMP
# EXEC, so this shell BECOMES the program: python's subprocess timeout kills
# the process it spawned, and a program that loops for ever must be that same
# process. Without the exec the timeout killed the shell and left the binary
# spinning -- eleven of them had accumulated across three grid runs before
# this was measured. The binary is left behind for the caller to sweep.
exec "$tmp" "$@"

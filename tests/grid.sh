#!/bin/sh
# Run the three directory grids (and optionally the whole corpus) against a
# SNAPSHOT of the compiler, so a rebuild during a measurement cannot corrupt it.
#   sh tests/grid.sh [<snapshot-binary> [<out-dir> [all]]]
#
# The runner is probes/t0/phpt-run.py and stays there on purpose: it is the
# definition of "these two agree" that every probe since T0 graded on, and a
# copy here would fork that definition. This script only chooses the corpus.
set -eu
LC_ALL=C; export LC_ALL
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
bin=${1:-build/mc-php}; out=${2:-build/grid}; full=${3:-}
MCPHP_BIN=$(CDPATH= cd -- "$(dirname -- "$bin")" && pwd)/$(basename "$bin")
export MCPHP_BIN
# the macOS SDK path once, so tests/link.sh does not run xcrun per test
[ "$(uname -s)" = Darwin ] && export MCPHP_SDK=${MCPHP_SDK:-$(xcrun --show-sdk-path)}
. "$(dirname -- "$0")/tmp.sh"
mcphp_tmp_init mcphp-grid
mcphp_tmp_watch
# The cleanup is the EXIT trap and the signal traps EXIT: a handler that
# only cleans up RETURNS, so an interrupted run carried on with its
# temporary directory already gone and ran the handler a second time on the
# way out.
trap 'mcphp_tmp_done' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
rm -rf "$out"; mkdir -p "$out"
for d in tests/lang Zend/tests ext/standard/tests/strings; do
    n=$(echo "$d" | tr '/' '_')
    printf '== %s ==\n' "$d"
    find "php-src/$d" -name '*.phpt' | python3 probes/t0/phpt-run.py \
        --candidate "$root/tests/mcphp.sh" --jobs "${MCPHP_JOBS:-12}" --quiet --out "$out/$n"
done
# The gate: what is green must be tests/grid/green-<dir>.txt (the recording)
# minus tests/grid/expected-differences.txt -- the tests php passes that
# mc-php does not because it behaves as C does (docs/semantics.md). A test
# lost, a test gained and an expected difference that no longer differs all
# fail, by name; a gain is the recording to update in the same commit.
gate=0
exp=tests/grid/expected-differences.txt
for d in tests/lang Zend/tests ext/standard/tests/strings; do
    n=$(echo "$d" | tr '/' '_')
    grep -v '^#' "$exp" | cut -f1 | grep -v '^$' | LC_ALL=C sort > "$out/$n.exp"
    LC_ALL=C comm -23 "tests/grid/green-$n.txt" "$out/$n.exp" > "$out/$n.want"
    cut -f1 "$out/$n/green.txt" | LC_ALL=C sort > "$out/$n.got"
    lost=$(LC_ALL=C comm -23 "$out/$n.want" "$out/$n.got")
    won=$(LC_ALL=C comm -13 "$out/$n.want" "$out/$n.got")
    for t in $lost; do echo "  FAIL  $t: green in the recording, not now"; gate=1; done
    for t in $won; do
        if grep -q "^$t	" "$exp"; then echo "  FAIL  $t: an expected difference that no longer differs"
        else echo "  FAIL  $t: green now and not in the recording (update tests/grid/green-$n.txt)"; fi
        gate=1
    done
done
if [ "$gate" = 0 ]; then
    echo "grid: green is the recording minus the $(grep -v '^#' "$exp" | grep -c .) expected differences, in all three directories"
else
    echo "grid: FAILED against the recording"
fi
if [ -n "$full" ]; then
    printf '== the whole corpus ==\n'
    find php-src -name '*.phpt' -not -path '*/sapi/*' | python3 probes/t0/phpt-run.py \
        --candidate "$root/tests/mcphp.sh" --jobs "${MCPHP_JOBS:-12}" --quiet --out "$out/all"
fi
exit $gate

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
if [ -n "$full" ]; then
    printf '== the whole corpus ==\n'
    find php-src -name '*.phpt' -not -path '*/sapi/*' | python3 probes/t0/phpt-run.py \
        --candidate "$root/tests/mcphp.sh" --jobs "${MCPHP_JOBS:-12}" --quiet --out "$out/all"
fi

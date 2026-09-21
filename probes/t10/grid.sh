#!/bin/sh
# Run the three directory grids (and optionally the whole corpus) against a
# SNAPSHOT of the compiler, so a rebuild during a measurement cannot corrupt it.
#   sh probes/t10/grid.sh <snapshot-binary> <out-dir> [all]
set -eu
LC_ALL=C; export LC_ALL
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$root"
bin=$1; out=$2; full=${3:-}
MCPHP_BIN=$(CDPATH= cd -- "$(dirname -- "$bin")" && pwd)/$(basename "$bin")
export MCPHP_BIN
. "$(dirname -- "$0")/tmp.sh"
mcphp_tmp_init mcphp-grid
mcphp_tmp_watch
trap 'mcphp_tmp_done' EXIT INT TERM
rm -rf "$out"; mkdir -p "$out"
for d in tests/lang Zend/tests ext/standard/tests/strings; do
    n=$(echo "$d" | tr '/' '_')
    printf '== %s ==\n' "$d"
    find "php-src/$d" -name '*.phpt' | python3 probes/t0/phpt-run.py \
        --candidate "$root/probes/t10/mcphp.sh" --jobs "${T10_JOBS:-12}" --quiet --out "$out/$n"
done
if [ -n "$full" ]; then
    printf '== the whole corpus ==\n'
    find php-src -name '*.phpt' -not -path '*/sapi/*' | python3 probes/t0/phpt-run.py \
        --candidate "$root/probes/t10/mcphp.sh" --jobs "${T10_JOBS:-12}" --quiet --out "$out/all"
fi

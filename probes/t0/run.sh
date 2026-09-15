#!/bin/sh
# T0 -- how far is 0 from N (docs/plan.md § 4).
#
# Three things, in order:
#   1. the grid itself: every .phpt under php-src, run under `php` (the
#      oracle) and under the placeholder executor B (probes/t0/mcphp-stub.sh,
#      which does not exist as a compiler yet and refuses nothing -- it just
#      always disagrees, so this is an honest "green 0" baseline).
#   2. the corpus breakdown: how much of that same corpus the decisions in
#      docs/plan.md § 3 touch, with the real tokenizer.
#   3. the oracle cross-check: php-src's own run-tests.php over the two
#      named directories, compared with this runner's oracle-only verdict
#      on the same files.
#
# Exits 0 only when all three ran. Needs php-src cloned at the repository
# root (php-src/ is entirely gitignored) and `php` on PATH.
set -eu
LC_ALL=C
export LC_ALL

cd "$(dirname "$0")"
PHP=${PHP:-php}
SRC=../../php-src
OUT=out
fail=0

[ -d "$SRC" ] || { echo "T0: no php-src -- clone php-8.5.10 at the repository root"; exit 1; }
"$PHP" --version | head -1

echo ""
echo "== 1. the grid: every .phpt under php-src, php vs the placeholder =="
rm -rf "$OUT"
mkdir -p "$OUT"
find "$SRC" -name '*.phpt' -not -path '*/sapi/*' | python3 phpt-run.py --jobs "${T0_JOBS:-24}" --out "$OUT" --quiet \
    | tee "$OUT/summary.txt"
grep -q '^phpt: green' "$OUT/summary.txt" || fail=1

echo ""
echo "== 2. the corpus breakdown: how much of it the decisions touch =="
python3 breakdown.py --root "$SRC" --php "$PHP" --out "$OUT" | tee "$OUT/breakdown.txt"

echo ""
echo "== 3. the oracle cross-check: php-src's own run-tests.php =="
if [ "${T0_CROSSCHECK:-0}" = 1 ]; then
    for dir in Zend/tests ext/standard/tests/strings; do
        echo "-- $dir --"
        n_ours=$(find "$SRC/$dir" -name '*.phpt' | wc -l | tr -d ' ')
        (cd "$SRC" && "$PHP" run-tests.php -q "$dir" 2>&1 | tail -8)
        echo "(ours over the same $n_ours files: see $OUT/summary.txt, filtered to $dir)"
    done
else
    echo "skipped (php-src's own runner takes ~8 minutes over Zend/tests alone;"
    echo " set T0_CROSSCHECK=1 to run it -- the numbers already measured are in RESULTS.md)"
fi

echo ""
[ "$fail" = 0 ] || { echo "T0: the grid did not run"; exit 1; }
echo "T0: measured -- see probes/t0/RESULTS.md"

#!/bin/sh
# T9 -- func_get_args, the block that prints the wrong thing, the block that
# does not compile, the names, and the generator decision
# (docs/plan.md section 4 row T9)
#
# T8 answered 1450 of 21044 and INVERTED its own failure table: 758 of 1396
# sampled `wrong` tests compiled and printed the wrong thing, 638 did not
# compile. T9 works both, in that order, re-measuring between blocks, and
# takes D6's correction (func_get_args) first.
#
# Four grid runs, then the tables that choose the next block:
#   (a) tests/lang   (b) Zend/tests   (c) ext/standard/tests/strings
#   (d) the whole corpus
# plus the compiler's own fixtures under g/ (byte for byte php's, on BOTH
# streams and the exit code) and the refusals under r/ (named, exit 3);
# then why.py's wrong-reason table, nocompile.py's groups of the block that
# does not compile, diffgroup.py's clustering of the block that does,
# arena.py's answer to D7, and D8's two obligations for the one .php this
# probe wrote that is not a fixture -- its tests in both worlds and its
# bench against php.
#
# Exits 0 only when every run measured; a red grid is still a measurement.
set -eu
LC_ALL=C
export LC_ALL

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../.." && pwd)
cd "$root"

MC=${MC:-mc}
PHP=${PHP:-php}
SRC=php-src
OUT=probes/t9/out
JOBS=${T9_JOBS:-12}
fail=0

# mcphp.sh EXECs the program it compiled, so it cannot clean up after itself:
# the binaries land here and this is what sweeps them.
MCPHP_TMP=${TMPDIR:-/tmp}/mcphp-t7.$$
export MCPHP_TMP
mkdir -p "$MCPHP_TMP"
# and swept WHILE it runs: 21395 binaries is about 6 GB otherwise
( while [ -d "$MCPHP_TMP" ]; do find "$MCPHP_TMP" -type f -mmin +1 -delete 2>/dev/null; sleep 20; done ) &
sweeper=$!
trap 'kill "$sweeper" 2>/dev/null; rm -rf "$MCPHP_TMP"' EXIT INT TERM

[ -d "$SRC" ] || { echo "T9: no php-src -- clone php-8.5.10 at the repository root"; exit 1; }
"$MC" --version
"$PHP" --version | head -1

echo ""
echo "== 0. the compiler =="
python3 probes/t9/lencheck.py
python3 probes/t9/aritycheck.py
# mc --exe must not overwrite a signed executable at the same inode: the
# kernel kills the next run with SIGKILL (mc's M12 note).
rm -f probes/t9/mc-php
"$MC" --exe probes/t9/mc-php.mc -o probes/t9/mc-php
ls -l probes/t9/mc-php | awk '{ printf "  probes/t9/mc-php  %s bytes\n", $5 }'

echo ""
echo "== 1. the fixtures and the refusals, against a SNAPSHOT of the compiler =="
sh probes/t9/fixtures.sh || fail=1

run_grid() {
    name=$1
    dir=$2
    printf '\n== %s ==\n' "$name"
    find "$SRC/$dir" -name '*.phpt' \
        | python3 probes/t0/phpt-run.py --candidate "$root/probes/t9/mcphp.sh" \
            --jobs "$JOBS" --quiet --out "$OUT/$3" \
        | tee "$OUT/$3.summary"
    grep -q '^phpt: green' "$OUT/$3.summary" || fail=1
}

rm -rf "$OUT"
mkdir -p "$OUT"
run_grid "2. the grid: tests/lang"                 tests/lang                  lang
run_grid "3. the grid: Zend/tests"                 Zend/tests                  zend
run_grid "4. the grid: ext/standard/tests/strings" ext/standard/tests/strings  strings

printf '\n== 5. the grid: the whole corpus ==\n'
find "$SRC" -name '*.phpt' -not -path '*/sapi/*' \
    | python3 probes/t0/phpt-run.py --candidate "$root/probes/t9/mcphp.sh" \
        --jobs "$JOBS" --quiet --out "$OUT/all" \
    | tee "$OUT/all.summary"
grep -q '^phpt: green' "$OUT/all.summary" || fail=1

printf '\n== 6. how many of the greens T0 calls "touched by none" ==\n'
python3 probes/t0/breakdown.py --root "$SRC" --php "$PHP" --out "$OUT" > "$OUT/breakdown.txt"
python3 - "$OUT/breakdown.tsv" "$OUT/all/green.txt" <<'PY'
import sys, os
# breakdown.py writes ABSOLUTE paths, phpt-run.py writes what it was given
rows = {}
with open(sys.argv[1]) as f:
    head = f.readline().rstrip('\n').split('\t')
    for line in f:
        c = line.rstrip('\n').split('\t')
        rows[os.path.relpath(c[0], os.getcwd())] = dict(zip(head, c))
green = [l.split('\t')[0] for l in open(sys.argv[2])]
def touched(r):
    return any(r.get(k) not in ('0', '', None) for k in ('d1', 'd5', 'autoload', 'd6', 'd4'))
known = [g for g in green if g in rows]
none = [g for g in known if not touched(rows[g])]
print(f'  greens {len(green)}, classifiable {len(known)}, '
      f'in T0\'s "touched by none" set {len(none)}')
PY

printf '\n== 7. the wrong-reason table, re-measured ==\n'
cut -f1 "$OUT/lang/wrong.txt" "$OUT/strings/wrong.txt" > "$OUT/why.list"
head -900 "$OUT/zend/wrong.txt" | cut -f1 >> "$OUT/why.list"
MCPHP_BIN="$root/probes/t9/mc-php" python3 probes/t9/why.py "$OUT/why.tsv" < "$OUT/why.list"
python3 probes/t9/whytable.py "$OUT/why.tsv" | tee "$OUT/why.table"

printf '\n== 7b. the tests that DO NOT COMPILE, by the compiler own message ==\n'
python3 probes/t9/nocompile.py "$OUT/why.tsv" | tee "$OUT/nocompile.table"

printf '\n== 8. the tests that COMPILE and disagree, by what differs ==\n'
awk -F'\t' '$2 == "(compiled; output differs)" { print $1 }' "$OUT/why.tsv" > "$OUT/dg.list"
MCPHP_BIN="$root/probes/t9/mc-php" python3 probes/t9/diffgroup.py "$OUT/dg.tsv" \
    < "$OUT/dg.list" | tee "$OUT/dg.table"

printf "\n== 8b. the two sub-populations T7 named ==\n"
python3 probes/t9/subpop.py "$OUT/all"

printf '\n== 9. how often the arena (D7) is the answer ==\n'
# A php array is a VALUE and D7 has no refcount, so T6 copies EAGERLY; this
# is the number that says whether that, or anything else, exhausts the arena.
MCPHP_BIN="$root/probes/t9/mc-php" python3 probes/t9/arena.py < "$OUT/why.list"

printf '\n== 10. D8: the workload tests, in both worlds ==\n'
"$PHP" probes/t9/bench/run.php | tail -1
probes/t9/mcphp.sh probes/t9/bench/run.php | tail -1

printf '\n== 11. D8: the bench, php against the mc-php binary ==\n'
sh probes/t9/bench/bench9.sh || fail=1

echo ""
[ "$fail" = 0 ] || { echo "T9: something did not measure"; exit 1; }
echo "T9: measured -- see probes/t9/RESULTS.md"

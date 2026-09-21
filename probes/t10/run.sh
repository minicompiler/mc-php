#!/bin/sh
# T10 -- the review backlog: the measurements that lie, the semantics that are
# wrong, and D8 over the fixtures (docs/review-backlog.md, docs/plan.md row T10)
#
# GitHub's Copilot reviewer left 59 inline findings across #1..#7 that nothing
# acted on. They are grouped by cost in docs/review-backlog.md and worked in
# that order:
#
#   1. the measurements that LIE -- four tools reported numbers they had not
#      measured, so they chose what every block since T5 worked on. Fixed
#      first, in probes/t10/harness.py, which is now the one definition of
#      "these two agree" (stdout, stderr and the exit code).
#   2. the semantics a program can OBSERVE -- short circuit, parameters by
#      value, finally, a pending exception, visibility, hoisting, typed
#      parameters, `?->` and thirteen one-line answers.
#   3. D8 over the fixtures: probes/t10/d8check.py puts every .php in this
#      probe into one of four regimes and fails on a file in none of them.
#
# Four grid runs, then the tables that choose the next block:
#   (a) tests/lang   (b) Zend/tests   (c) ext/standard/tests/strings
#   (d) the whole corpus
# plus the compiler's own fixtures under g/ (byte for byte php's, on BOTH
# streams and the exit code) and the refusals under r/ (named, exit 3);
# then why.py's wrong-reason table, nocompile.py's groups of the block that
# does not compile, diffgroup.py's clustering of the block that does,
# arena.py's answer to D7, and D8's two obligations for the .php this probe
# wrote that is not a fixture -- its tests in both worlds and its bench.
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
OUT=probes/t10/out
JOBS=${T10_JOBS:-12}
fail=0

# Where the compiled binaries go, and what bounds that directory: see
# probes/t10/tmp.sh, which is the one definition and carries the measurement.
. "$here/tmp.sh"
mcphp_tmp_init mcphp-t10
mcphp_tmp_watch
trap 'mcphp_tmp_done' EXIT INT TERM
df -h / | tail -1 | awk '{ printf "  disk before: %s used, %s free\n", $3, $4 }' 

[ -d "$SRC" ] || { echo "T10: no php-src -- clone php-8.5.10 at the repository root"; exit 1; }
"$MC" --version
"$PHP" --version | head -1

echo ""
echo "== 0. the compiler =="
# D8 over every .php this probe wrote, before anything is built: a file with
# neither a test in both worlds nor a bench row fails the run.
python3 probes/t10/d8check.py || fail=1
python3 probes/t10/lencheck.py
python3 probes/t10/aritycheck.py
# mc --exe must not overwrite a signed executable at the same inode: the
# kernel kills the next run with SIGKILL (mc's M12 note).
rm -f probes/t10/mc-php
"$MC" --exe probes/t10/mc-php.mc -o probes/t10/mc-php
ls -l probes/t10/mc-php | awk '{ printf "  probes/t10/mc-php  %s bytes\n", $5 }'

echo ""
echo "== 1. the fixtures and the refusals, against a SNAPSHOT of the compiler =="
sh probes/t10/fixtures.sh || fail=1

run_grid() {
    name=$1
    dir=$2
    printf '\n== %s ==\n' "$name"
    find "$SRC/$dir" -name '*.phpt' \
        | python3 probes/t0/phpt-run.py --candidate "$root/probes/t10/mcphp.sh" \
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
    | python3 probes/t0/phpt-run.py --candidate "$root/probes/t10/mcphp.sh" \
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
MCPHP_BIN="$root/probes/t10/mc-php" python3 probes/t10/why.py "$OUT/why.tsv" < "$OUT/why.list"
python3 probes/t10/whytable.py "$OUT/why.tsv" | tee "$OUT/why.table"

printf '\n== 7b. the tests that DO NOT COMPILE, by the compiler own message ==\n'
python3 probes/t10/nocompile.py "$OUT/why.tsv" | tee "$OUT/nocompile.table"

printf '\n== 8. the tests that COMPILE and disagree, by what differs ==\n'
awk -F'\t' '$2 == "(compiled; output differs)" { print $1 }' "$OUT/why.tsv" > "$OUT/dg.list"
MCPHP_BIN="$root/probes/t10/mc-php" python3 probes/t10/diffgroup.py "$OUT/dg.tsv" \
    < "$OUT/dg.list" | tee "$OUT/dg.table"

printf "\n== 8b. the two sub-populations T7 named ==\n"
python3 probes/t10/subpop.py "$OUT/all"

printf '\n== 9. how often the arena (D7) is the answer ==\n'
# A php array is a VALUE and D7 has no refcount, so T6 copies EAGERLY; this
# is the number that says whether that, or anything else, exhausts the arena.
MCPHP_BIN="$root/probes/t10/mc-php" python3 probes/t10/arena.py < "$OUT/why.list"

printf '\n== 10. D8: the workload tests, in both worlds ==\n'
# GATED. T9's step 10 piped both halves to `tail -1` with nothing behind
# them, so the mc-php half's refusal went to stderr, its stdout was empty,
# and "6 ok / 0 failed in BOTH worlds" was php's side alone -- the mc-php
# half had never run under any probe. Both lines are printed, both are
# required, and they have to agree.
# php's half is captured the same way the mc-php half is: a pipeline's
# status is `tail`'s, so a php that exited non-zero -- or warned before
# printing its last line -- satisfied the gate.
"$PHP" probes/t10/bench/run.php > "$MCPHP_TMP/d8p.out" 2> "$MCPHP_TMP/d8p.err"
d8pe=$?
d8a=$(tail -1 "$MCPHP_TMP/d8p.out")
[ "$d8pe" = 0 ] || { printf '  php exited %s\n' "$d8pe"; fail=1; }
[ -s "$MCPHP_TMP/d8p.err" ] && { printf '  php wrote to stderr:\n'; sed 's/^/    /' "$MCPHP_TMP/d8p.err"; fail=1; }
rm -f "$MCPHP_TMP/d8p.out" "$MCPHP_TMP/d8p.err"
MCPHP_OUT=$MCPHP_TMP/d8.bin probes/t10/mcphp.sh probes/t10/bench/run.php \
    > "$MCPHP_TMP/d8.out" 2>&1
d8b=$(tail -1 "$MCPHP_TMP/d8.out")
rm -f "$MCPHP_TMP/d8.bin" "$MCPHP_TMP/d8.bin.out" "$MCPHP_TMP/d8.bin.err" "$MCPHP_TMP/d8.out"
printf '  php     %s\n  mc-php  %s\n' "$d8a" "$d8b"
# NOT phpunit and NOT `mc-php test`, and the reason is on record rather than
# implied: phpunit is not installed on this host (bench/shim.php's own note)
# and `mc-php test` does not exist -- D8 (a) names it as the mechanism the
# COMPILER will provide. Until it does, the method list is written by hand in
# run.php, and probes/t10/d8check.py is what keeps that list honest: it fails
# when the class declares a `test*` the runner does not name, or the reverse.
printf '  (the runner is run.php: phpunit is not installed here and `mc-php test`\n'
printf '   does not exist yet -- d8check.py checks the hand-written list against\n'
printf '   the class, so a test method cannot be declared and never run)\n'
case "$d8a" in *" 0 failed") ;; *) fail=1 ;; esac
[ "$d8a" = "$d8b" ] || fail=1

printf '\n== 11. D8: the bench, php against the mc-php binary ==\n'
sh probes/t10/bench/bench10.sh || fail=1

echo ""
[ "$fail" = 0 ] || { echo "T10: something did not measure"; exit 1; }
echo "T10: measured -- see probes/t10/RESULTS.md"

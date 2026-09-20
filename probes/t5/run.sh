#!/bin/sh
# T5 -- does the runtime agree with php? (docs/plan.md section 4 row T5)
#
# Four grid runs, in the order the task asks for them:
#   (a) tests/lang   (b) Zend/tests   (c) ext/standard/tests/strings
#   (d) the whole corpus
# plus the compiler's own sanity fixtures under g/, each compared with `php`.
#
# The number that matters is `green`, and its denominator. Exits 0 only when
# every run measured; a red grid is still a measurement.
set -eu
LC_ALL=C
export LC_ALL

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../.." && pwd)
cd "$root"

MC=${MC:-mc}
PHP=${PHP:-php}
SRC=php-src
OUT=probes/t5/out
JOBS=${T5_JOBS:-12}
fail=0

[ -d "$SRC" ] || { echo "T5: no php-src -- clone php-8.5.10 at the repository root"; exit 1; }
"$MC" --version
"$PHP" --version | head -1

echo ""
echo "== 0. the compiler =="
"$MC" --exe probes/t5/mc-php.mc -o probes/t5/mc-php
ls -l probes/t5/mc-php | awk '{ printf "  probes/t5/mc-php  %s bytes\n", $5 }'

echo ""
echo "== 1. the fixtures: every g/*.php under php and under mc-php =="
ng=0
nok=0
for f in probes/t5/g/*.php; do
    ng=$((ng + 1))
    exp=$("$PHP" "$f" 2>&1) && pe=0 || pe=$?
    got=$(probes/t5/mcphp.sh "$f" 2>&1) && me=0 || me=$?
    if [ "$exp" = "$got" ] && [ "$pe" = "$me" ]; then
        nok=$((nok + 1))
        printf '  ok    %s\n' "$(basename "$f")"
    else
        printf '  FAIL  %s\n    php:    %s (exit %s)\n    mc-php: %s (exit %s)\n' \
            "$(basename "$f")" "$exp" "$pe" "$got" "$me"
        fail=1
    fi
done
echo "  fixtures: $nok / $ng agree with php"

echo ""
echo "== 1b. the refusals: a .php php runs and mc-php names (exit 3) =="
nr=0
nrok=0
for f in probes/t5/r/*.php; do
    nr=$((nr + 1))
    msg=$(probes/t5/mcphp.sh "$f" 2>&1 >/dev/null | sed 's/^[^:]*:[0-9]*: //' | head -1)
    probes/t5/mcphp.sh "$f" >/dev/null 2>&1 && rc=0 || rc=$?
    case "$rc:$msg" in
        3:*"is refused by design"*)
            nrok=$((nrok + 1)); printf '  ok    %-26s %s\n' "$(basename "$f")" "$msg" ;;
        *)  printf '  FAIL  %-26s exit %s: %s\n' "$(basename "$f")" "$rc" "$msg"; fail=1 ;;
    esac
done
echo "  refusals: $nrok / $nr named, exit 3"

run_grid() {
    name=$1
    dir=$2
    printf '\n== %s ==\n' "$name"
    find "$SRC/$dir" -name '*.phpt' \
        | python3 probes/t0/phpt-run.py --candidate "$root/probes/t5/mcphp.sh" \
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
    | python3 probes/t0/phpt-run.py --candidate "$root/probes/t5/mcphp.sh" \
        --jobs "$JOBS" --quiet --out "$OUT/all" \
    | tee "$OUT/all.summary"
grep -q '^phpt: green' "$OUT/all.summary" || fail=1

printf '\n== 6. how many of the greens T0 calls "touched by none" ==\n'
python3 probes/t0/breakdown.py --root "$SRC" --php "$PHP" --out "$OUT" > "$OUT/breakdown.txt"
python3 - "$OUT/breakdown.tsv" "$OUT/all/green.txt" <<'PY'
import sys
rows = {}
with open(sys.argv[1]) as f:
    head = f.readline().rstrip('\n').split('\t')
    for line in f:
        c = line.rstrip('\n').split('\t')
        rows[c[0]] = dict(zip(head, c))
green = [l.split('\t')[0] for l in open(sys.argv[2])]
def touched(r):
    return any(r.get(k) not in ('0', '', None) for k in ('d1', 'd5', 'autoload', 'd6', 'd4'))
known = [g for g in green if g in rows]
none = [g for g in known if not touched(rows[g])]
print(f'  greens {len(green)}, classifiable {len(known)}, '
      f'in T0\'s "touched by none" set {len(none)}')
PY

echo ""
[ "$fail" = 0 ] || { echo "T5: something did not measure"; exit 1; }
echo "T5: measured -- see probes/t5/RESULTS.md"

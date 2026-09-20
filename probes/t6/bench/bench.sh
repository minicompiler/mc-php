#!/bin/sh
# T6's unwinding measurement: what does the pending-exception CHECK cost?
#
# There is no VM and no setjmp (probes/t6/RESULTS.md section 4), so a throw
# sets a flag and the compiler emits `if (php_thrown()) <unwind>` after every
# statement that contains a call. This builds the SAME compiler twice -- once
# as it ships and once with ph_check emitting nothing -- compiles the same
# program with each, and times them interleaved against `php`.
#
# The no-check compiler is not a usable php compiler: it cannot unwind. It
# exists for this measurement and nothing else.
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../../.." && pwd)
cd "$root"
MC=${MC:-mc}
PHP=${PHP:-php}
REPS=${REPS:-5}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "== building the two compilers =="
cp probes/t6/php.mc probes/t6/php_rt.txt probes/t6/mc-php.mc "$tmp/"
# the no-check variant: ph_check answers an empty block
python3 - "$tmp/php.mc" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace('i64 ph_check(i64 line, uptr fl) {',
              'i64 ph_check(i64 line, uptr fl) {\n    return node_new(N_BLOCK, line, fl);   // BENCH: no unwinding check')
open(p, 'w').write(s)
PY
rm -f probes/t6/mc-php "$tmp/mc-php-nocheck"
"$MC" --exe probes/t6/mc-php.mc -o probes/t6/mc-php
( cd "$tmp" && "$MC" --exe mc-php.mc -o mc-php-nocheck )

echo "== compiling the benchmark with each =="
rm -f "$tmp/with" "$tmp/without"
probes/t6/mc-php --exe probes/t6/bench/unwind.php -o "$tmp/with"
"$tmp/mc-php-nocheck" --exe probes/t6/bench/unwind.php -o "$tmp/without"

w=$("$tmp/with")
wo=$("$tmp/without")
pp=$("$PHP" probes/t6/bench/unwind.php)
echo "  php        $pp"
echo "  with       $w"
echo "  without    $wo"
[ "$w" = "$pp" ] || { echo "bench: mc-php disagrees with php"; exit 1; }
[ "$wo" = "$pp" ] || { echo "bench: the no-check build disagrees with php"; exit 1; }

echo "== $REPS interleaved repetitions, seconds =="
python3 - "$tmp/with" "$tmp/without" "$PHP" probes/t6/bench/unwind.php "$REPS" <<'PY'
import statistics, subprocess, sys, time
with_, without, php, src, reps = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5])
runs = {'with': [], 'without': [], 'php': []}
cmds = {'with': [with_], 'without': [without], 'php': [php, src]}
for _ in range(reps):
    for k in ('with', 'without', 'php'):
        t = time.perf_counter()
        subprocess.run(cmds[k], stdout=subprocess.DEVNULL, check=True)
        runs[k].append(time.perf_counter() - t)
m = {k: statistics.median(v) for k, v in runs.items()}
for k in ('with', 'without', 'php'):
    print('  %-9s median %.3f  best %.3f' % (k, m[k], min(runs[k])))
print('  the check costs %+.1f%% of run time' % ((m['with'] / m['without'] - 1) * 100))
print('  mc-php is %.2fx php' % (m['php'] / m['with']))
PY

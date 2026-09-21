#!/usr/bin/env python3
"""Time `php PROG` against an mc-php binary, interleaved, with php's own
start-up measured beside them so the second ratio is the WORK."""
import statistics
import subprocess
import sys
import time

php, exe, reps, src = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
rows = {'php': [], 'mc-php': [], 'php -r (start-up)': []}
for _ in range(reps):
    for name, cmd in (('php', [php, src]), ('mc-php', [exe]),
                      ('php -r (start-up)', [php, '-r', ''])):
        t = time.perf_counter()
        subprocess.run(cmd, stdout=subprocess.DEVNULL, check=True)
        rows[name].append(time.perf_counter() - t)
m = {k: statistics.median(v) for k, v in rows.items()}
for k in ('php', 'mc-php', 'php -r (start-up)'):
    print('  %-18s median %.4f s   best %.4f s' % (k, m[k], min(rows[k])))
print('  php / mc-php = %.2fx  (%d repetitions, interleaved)' % (m['php'] / m['mc-php'], reps))
w = m['php'] - m['php -r (start-up)']
if w > 0:
    print('  php WORK / mc-php = %.2fx  (php minus its own start-up)' % (w / m['mc-php'],))

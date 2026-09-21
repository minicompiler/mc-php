#!/usr/bin/env python3
"""Time `php PROG` against an mc-php binary, interleaved, with php's own
start-up measured beside them so the second ratio is the WORK.

    time2.py PHP EXE REPS SRC [--json FILE]

`--json` writes the same numbers as one JSON object. It is written HERE and
not scraped out of the text above by the caller, because a bench row that is
re-parsed from a printed line is a second place for it to be wrong (the
first attempt did exactly that and produced invalid JSON)."""
import json
import statistics
import subprocess
import sys
import time

php, exe, reps, src = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
jsonf = sys.argv[6] if len(sys.argv) > 6 and sys.argv[5] == '--json' else None
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
if jsonf:
    o = {'program': src, 'reps': reps,
         'php_median_s': round(m['php'], 6),
         'mcphp_median_s': round(m['mc-php'], 6),
         'php_startup_median_s': round(m['php -r (start-up)'], 6),
         'php_best_s': round(min(rows['php']), 6),
         'mcphp_best_s': round(min(rows['mc-php']), 6),
         'ratio_php_over_mcphp': round(m['php'] / m['mc-php'], 3)}
    if w > 0:
        o['ratio_work_over_mcphp'] = round(w / m['mc-php'], 3)
    open(jsonf, 'w').write(json.dumps(o))

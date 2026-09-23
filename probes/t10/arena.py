#!/usr/bin/env python3
"""How often is `mc-php: arena exhausted` the answer?

docs/plan.md D7 has no refcount and no free, so a php array -- which is a
VALUE -- is copied EAGERLY at every hand-over, and T6 measured the 48 MiB
arena exhausted between 500 and 1000 copies of a 2000-element array. The
question this answers is whether that, or anything else, actually bites the
corpus.

`docs/review-backlog.md` section 1, third finding: T7..T9's arena.py turned
EVERY exception -- a compile failure, a timeout, anything -- into `None` and
still divided by `len(files)`. "11 of 1396 exhaust the arena" counted, in its
denominator, tests it never ran. The denominator here is the number of tests
that RAN, every other outcome is reported on its own line, and the two are
added up so nothing is silently dropped.

    python3 probes/t10/arena.py < LIST-OF-PHPT      (one path per line)
"""
import os, sys
from collections import Counter
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import harness


def one(p):
    r = harness.run_pair(p, 'ar')
    s = r['status']
    if s != 'ran':
        return (s, p)
    # a php COMPILE-TIME fatal: the grid grades the pair on its output, but
    # no binary ran, so it belongs in neither half of "N of M that RAN"
    if r.get('compile_fatal'):
        return ('compile-fatal', p)
    return ('exhausted' if 'arena exhausted' in r['err'] else 'ran', p)


def main():
    files = [l.split('\t')[0].strip() for l in sys.stdin if l.strip()]
    with ThreadPoolExecutor(max_workers=harness.jobs()) as ex:
        rows = list(ex.map(one, files))
    c = Counter(s for s, _ in rows)
    ran = c['ran'] + c['exhausted']
    print(f"arena exhausted in {c['exhausted']} of {ran} tests that RAN "
          f"({len(files)} in the list)")
    for k, v in sorted(c.items()):
        if k in ('ran', 'exhausted'):
            continue
        print(f'  not run: {v:5d}  {k}')
    for s, p in rows:
        if s == 'exhausted':
            print(' ', p)
    assert sum(c.values()) == len(files), 'a test was dropped'


main()

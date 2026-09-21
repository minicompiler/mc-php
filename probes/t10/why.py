#!/usr/bin/env python3
"""Ask the compiler WHY each .phpt in a list is `wrong`.

The grid says a test disagreed; this says what mc-php had to say about its
--FILE-- section -- the first diagnostic, or, when it built a binary, what that
binary then DID.

`docs/review-backlog.md` section 1, first finding: T5..T9's why.py wrote
`(compiled; output differs)` without ever running the binary, so every
"output differs" count since T5 really meant "compiled". This runs it, beside
php, and compares stdout AND the exit code -- which is what the grid grades --
so the label is one of

    (compiled; output differs)          it ran and disagreed
    (compiled; agrees on this harness)  it ran and agreed: the .phpt's own
                                        expectation, not the program, is what
                                        the grid graded wrong
    (compiled; crashed: signal N)       the binary died
    (compiled; timed out)

    python3 probes/t10/why.py OUT.tsv [FILE.phpt ...]      (else stdin)
"""
import os, sys
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import harness


def why(path):
    r = harness.run_pair(path, 'why')
    s = r['status']
    if s == 'no-file':
        return path, '(no --FILE-- section)'
    if s == 'busy':
        return path, '(a sibling of that name exists; skipped)'
    if s == 'no-compile':
        msg = r['cerr'].splitlines()
        return path, (msg[0] if msg else f"(exit {r['crc']}, silent)")
    if s == 'compile-timeout':
        return path, '(compiler timed out)'
    if s == 'run-timeout':
        return path, '(compiled; timed out)'
    if s != 'ran':
        return path, f"({r.get('error', s)})"
    if r['agrees']:
        return path, '(compiled; agrees on this harness)'
    if r['rc'] < 0:
        return path, f"(compiled; crashed: signal {-r['rc']})"
    if r['out'] == r['want']:
        return path, f"(compiled; same output, exit {r['rc']} where php exits {r['wrc']})"
    return path, '(compiled; output differs)'


def main():
    out = sys.argv[1]
    files = sys.argv[2:] or [l.split('\t')[0].strip() for l in sys.stdin if l.strip()]
    with ThreadPoolExecutor(max_workers=os.cpu_count() or 8) as ex:
        rows = list(ex.map(why, files))
    with open(out, 'w') as f:
        for path, msg in rows:
            f.write(f'{path}\t{msg}\n')
    print(f'why: {len(rows)} tests -> {out}')


main()

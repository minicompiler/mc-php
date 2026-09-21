#!/usr/bin/env python3
"""Cluster the `(compiled; output differs)` tests by WHAT differs.

It runs php and the mc-php binary on the same --FILE--, finds the FIRST
differing line, and groups by the shape of that line, which is what says
whether a fix is one bug or a hundred.

`docs/review-backlog.md` section 1, second finding: T7..T9's diffgroup
compared stdout ONLY, while the grid counts an exit-code mismatch as `wrong`
(`probes/t0/phpt-run.py`: green needs the output AND the code). A pair whose
output matches and whose exit code does not was grouped as agreeing. The two
are graded together here, and a pair that agrees on stdout alone gets its own
group -- `an exit code` -- because the fix for it is a different fix.

    python3 probes/t10/diffgroup.py OUT.tsv [FILE.phpt ...]      (else stdin)

Writes one row per test:  <path>\t<group>\t<php line>\t<mc-php line>
"""
import os, re, sys
from collections import Counter
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import harness

# the shapes, in the order they are tried: the FIRST that matches names the
# group, so a more specific rule goes above a more general one.
SHAPES = [
    (r'^\s*(Warning|Deprecated|Notice|Fatal error|Parse error):', 'a php diagnostic'),
    (r'^(int|float|string|bool|NULL|array|object|enum|resource)\(', 'var_dump of a value'),
    (r'^\s*\[.*\] =>', 'print_r of an element'),
    (r'^(Array|Object|stdClass Object)\s*$', 'print_r of a container'),
    (r"^\s*\d+ => ", 'var_export of an element'),
    (r'^\s*\)|^\s*\(|^\s*\{|^\s*\}', 'a container delimiter'),
    (r'^-?\d+\.\d|[eE][-+]\d', 'a float'),
    (r'^-?\d+$', 'an integer'),
    (r'^$', 'a blank line'),
]


def shape(a, b):
    for rx, name in SHAPES:
        if re.search(rx, a) or re.search(rx, b):
            return name
    return 'other text'


def one(path):
    r = harness.run_pair(path, 'dg')
    s = r['status']
    if s == 'no-file':
        return None
    if s == 'busy':
        return (path, '(a sibling of that name exists)', '', '')
    if s == 'no-compile':
        return (path, '(does not compile)', '', '')
    if s in ('compile-timeout', 'run-timeout'):
        return (path, '(timed out)', '', '')
    if s != 'ran':
        return (path, f"({r.get('error', s)})", '', '')
    if r['agrees']:
        return (path, '(agrees on this harness)', '', '')
    # The equality is tested on the RAW strings. `rstrip('\n')` before
    # splitting made a pair that differs ONLY in a final newline compare
    # EQUAL, and the branch below then reported an exit code that is the
    # same on both sides. `split` without the rstrip keeps that difference
    # as a differing last element, and `shape()` still sees lines with no
    # line ending -- which is what its patterns are written against.
    # the grid's OWN comparison, as `run_pair`'s own verdict uses: a pair
    # differing only in a trailing newline or a CRLF is the same output
    # there, so testing the raw bytes here called an exit-code-only mismatch
    # a blank-line or text difference
    if harness.agrees(r.get('sec'), r['out'], r['want'], r['rc'], r['rc']):
        # the grid grades the exit code too, so this is a real disagreement
        return (path, 'an exit code', f"exit {r['wrc']}", f"exit {r['rc']}")
    want = r['want'].split('\n')
    got = r['out'].split('\n')
    for i in range(max(len(want), len(got))):
        a = want[i] if i < len(want) else '<eof>'
        b = got[i] if i < len(got) else '<eof>'
        if a != b:
            return (path, shape(a, b), a[:120], b[:120])
    # unreachable: the raw strings differ above, so some index differs
    return (path, '(agrees on this harness)', '', '')


def main():
    out = sys.argv[1]
    files = sys.argv[2:] or [l.split('\t')[0].strip() for l in sys.stdin if l.strip()]
    with ThreadPoolExecutor(max_workers=harness.jobs()) as ex:
        rows = [r for r in ex.map(one, files) if r]
    with open(out, 'w') as f:
        for r in rows:
            f.write('\t'.join(r) + '\n')
    c = Counter(r[1] for r in rows)
    print(f'  {len(rows)} tests that compile, by the shape of the first differing line')
    for k, v in c.most_common():
        print(f'    {v:5d}  {k}')
    print('\n  the five commonest first-difference pairs per group:')
    for grp, _ in c.most_common(6):
        if grp.startswith('('):
            continue
        pairs = Counter((re.sub(r'\d+', 'N', r[2])[:60], re.sub(r'\d+', 'N', r[3])[:60])
                        for r in rows if r[1] == grp)
        print(f'    {grp}:')
        for (a, b), v in pairs.most_common(5):
            print(f'      {v:4d}  php {a!r}')
            print(f'            mc  {b!r}')


main()

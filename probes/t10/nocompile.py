#!/usr/bin/env python3
"""The tests that DO NOT COMPILE, grouped by the compiler's own message.

T7 left `(does not compile)` as the biggest block -- 878 of 1460 sampled
`wrong` tests -- and `whytable.py` prints its head as a flat top-22 with no
way back to a file. This reads the SAME why.tsv (so no compiler run is
repeated), masks the variable parts of each message, groups, and prints the
count with three example files per group -- which is what makes a group
workable instead of countable.

    python3 probes/t10/nocompile.py OUT/why.tsv [N]
"""
import collections, re, sys

# A compiler DIAGNOSTIC is what this tool groups, and mc's own `err_at`
# writes `file:line: message` -- it never begins with a bracket. Every other
# thing why.py can write does: the five compiled outcomes (`output differs`,
# `agrees on this harness`, `same output, exit N ...`, `crashed: signal N`,
# `timed out`), and equally `(compiler timed out)`, `(php timed out)`,
# `(a sibling of that name exists; skipped)`, `(no --FILE-- section)` and
# `(error)`, none of which is a test that failed to compile either.
# Naming `(compiled;` alone left those five counted as tests that DO NOT
# COMPILE. (In the run this probe publishes there are none of them, so the
# block is 539 either way; the filter was still wrong.)
SKIP = '('



def mask(msg):
    # drop the `file:line: ` prefix mc's err_at writes
    m = re.sub(r'^[^ ]*:\d+: ', '', msg)
    # the refusal/not-implemented wrapper: keep what it names
    mm = re.match(r'mc-php: (.*?) is (not implemented yet|refused by design)', m)
    if mm:
        return mm.group(1) + ' [' + mm.group(2).split()[0] + ']'
    # a missing library name is one group with its own frequency list
    g = re.match(r'a php (function|constant) mc-php does not have: (\w+)', m)
    if g:
        return f'a php {g.group(1)} mc-php does not have'
    # mask the quoted/trailing variable part of everything else
    m = re.sub(r'\b[A-Za-z_$][A-Za-z_0-9$]*\b(?=\s*$)', 'X', m)
    return re.sub(r': .*', ': X', m)


def main():
    top = int(sys.argv[2]) if len(sys.argv) > 2 else 30
    groups = collections.defaultdict(list)
    names = collections.Counter()
    total = 0
    for line in open(sys.argv[1]):
        path, msg = line.rstrip('\n').split('\t', 1)
        if msg.startswith(SKIP):
            continue
        total += 1
        g = re.match(r'a php (function|constant) mc-php does not have: (\w+)',
                     re.sub(r'^[^ ]*:\d+: ', '', msg))
        if g:
            names[g.group(2)] += 1
        groups[mask(msg)].append(path)
    print(f'  {total} tests that DO NOT COMPILE, by the compiler\'s message')
    for key, files in sorted(groups.items(), key=lambda kv: -len(kv[1]))[:top]:
        print(f'  {len(files):5d}  {key}')
        for f in files[:3]:
            print(f'           {f}')
    if names:
        print(f'\n  the {len(names)} names it does not have, by frequency:')
        print('  ' + ', '.join(f'{k}({v})' for k, v in names.most_common(60)))


main()

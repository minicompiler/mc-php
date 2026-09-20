#!/usr/bin/env python3
"""The wrong-reason table: what mc-php says about each `wrong` test.

why.py records one diagnostic per test; this groups them, so the next block of
work is chosen by the number and not by a guess.

    python3 probes/t8/whytable.py OUT/why.tsv
"""
import collections, re, sys

TOP = 22
NAMES = 40


def main():
    c = collections.Counter()
    fn = collections.Counter()
    for line in open(sys.argv[1]):
        path, msg = line.rstrip('\n').split('\t', 1)
        m = re.sub(r'^[^ ]*:\d+: ', '', msg)
        mm = re.match(r'mc-php: (.*?) is (not implemented yet|refused by design)', m)
        key = mm.group(1) if mm else m
        g = re.match(r'a php (function|constant) mc-php does not have: (\w+)', key)
        if g:
            fn[g.group(2)] += 1
            key = 'a php function or constant mc-php does not have'
        else:
            key = re.sub(r': .*', '', key)
        c[key] += 1
    total = sum(c.values())
    print(f'  {total} `wrong` tests, by what mc-php said about each')
    for k, v in c.most_common(TOP):
        print(f'  {v:5d}  {k}')
    if fn:
        print('\n  the most wanted names mc-php does not have:')
        print('  ' + ', '.join(f'{k}({v})' for k, v in fn.most_common(NAMES)))


main()

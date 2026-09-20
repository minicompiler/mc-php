#!/usr/bin/env python3
"""The library table's `max` and the runtime function's arity must agree.

php.mc emits a call with exactly `max` arguments (a missing optional one is
php_znull()), so a runtime function that takes a different number is an mc
compile error -- "wrong number of arguments" -- with no hint of which row is
wrong. 37 rows were wrong when this check was written.

    python3 probes/t9/aritycheck.py      # exits 1 on any mismatch
"""
import os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEF = re.compile(r'^(?:uptr|i64|u8|u32|u64|f64|void)\s+(\w+)\s*\(([^)]*)\)\s*\{', re.M)
ROW = re.compile(r'ph_lib\("([^"]+)",\s*"([^"]+)",\s*(\d+),\s*(\d+),')


def main():
    rt = open(os.path.join(HERE, 'php_rt.txt')).read()
    mc = open(os.path.join(HERE, 'php.mc')).read()
    arity = {}
    for m in DEF.finditer(rt):
        p = m.group(2).strip()
        arity.setdefault(m.group(1), 0 if p in ('', 'void') else len(p.split(',')))
    bad = n = 0
    for m in ROW.finditer(mc):
        php, fn, lo, hi = m.group(1), m.group(2), int(m.group(3)), int(m.group(4))
        n += 1
        if fn not in arity:
            print(f'aritycheck: {php} -> {fn} is not defined in php_rt.txt')
            bad += 1
        elif arity[fn] != hi:
            print(f'aritycheck: {php} -> {fn}: table max {hi}, runtime takes {arity[fn]}')
            bad += 1
        if lo > hi:
            print(f'aritycheck: {php}: min {lo} above max {hi}')
            bad += 1
    print(f'aritycheck: {n} library rows, {bad} wrong')
    sys.exit(1 if bad else 0)


main()

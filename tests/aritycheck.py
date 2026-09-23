#!/usr/bin/env python3
"""The library table's `max` and the runtime function's arity must agree.

The compiler emits a call with exactly `max` arguments (a missing optional one is
php_znull()), so a runtime function that takes a different number is an mc
compile error -- "wrong number of arguments" -- with no hint of which row is
wrong. 37 rows were wrong when this check was written.

    python3 tests/aritycheck.py      # exits 1 on any mismatch
"""
import os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
DEF = re.compile(r'^(?:uptr|i64|u8|u32|u64|f64|void)\s+(\w+)\s*\(([^)]*)\)\s*\{', re.M)
ROW = re.compile(r'ph_lib\("([^"]+)",\s*"([^"]+)",\s*(\d+),\s*(\d+),')


def main():
    # The runtime is every .mc under lib/, not one file: since the hosts
    # branch its system layer is one file per host (lib/rt_host_*.mc) and a
    # function a row names may be in one of them.
    rt = ''.join(open(os.path.join(ROOT, 'lib', f)).read()
                 for f in sorted(os.listdir(os.path.join(ROOT, 'lib')))
                 if f.endswith('.mc'))
    mc = ''.join(open(os.path.join(ROOT, 'src', f)).read()
                 for f in sorted(os.listdir(os.path.join(ROOT, 'src')))
                 if f.endswith('.mc'))
    arity = {}
    for m in DEF.finditer(rt):
        p = m.group(2).strip()
        arity.setdefault(m.group(1), 0 if p in ('', 'void') else len(p.split(',')))
    bad = n = 0
    for m in ROW.finditer(mc):
        php, fn, lo, hi = m.group(1), m.group(2), int(m.group(3)), int(m.group(4))
        n += 1
        if fn not in arity:
            print(f'aritycheck: {php} -> {fn} is not defined in lib/php_rt.mc')
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

#!/usr/bin/env python3
"""The two sub-populations T7 named, re-measured on the greens of a run.

    python3 probes/t10/subpop.py OUT/all

  * the tests that assert a php diagnostic line
  * the tests that mention __destruct
"""
import re, sys, glob, os
green = set()
out = sys.argv[1] if len(sys.argv) > 1 else 'probes/t10/out/all'
for f in glob.glob(os.path.join(out, 'green.txt')):
    for l in open(f):
        green.add(l.split('\t')[0])
DIAG = re.compile(r'^(Warning|Deprecated|Notice|Fatal error):', re.M)
nd = gd = nx = gx = 0
for f in glob.glob('php-src/**/*.phpt', recursive=True):
    if '/sapi/' in f: continue
    try: s = open(f, 'rb').read().decode('latin-1')
    except OSError: continue
    m = re.search(r'^--EXPECT(?:F|REGEX)?--\r?\n(.*)', s, re.S | re.M)
    if m and DIAG.search(m.group(1)):
        nd += 1
        if f in green: gd += 1
    if '__destruct' in s:
        nx += 1
        if f in green: gx += 1
print(f'  assert a php diagnostic line: {gd} green of {nd}')
print(f'  mention __destruct:           {gx} green of {nx}')

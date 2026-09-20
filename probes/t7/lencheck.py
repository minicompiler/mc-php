#!/usr/bin/env python3
"""Every (literal, length) pair in T5's sources must agree.

php_die("...", N), php_write("...", N), php_memcpy(d, "...", N), p_cat(x, "...",
off, N) and ph_strlit("...", N) all carry a HAND-COUNTED length beside a string
literal, and mc will not check it: a length one short truncates the message, one
long reads a byte past the literal. Four were wrong when this check was written.

    python3 probes/t7/lencheck.py       # exits 1 on any mismatch
"""
import os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
LIT = r'"((?:[^"\\]|\\.)*)"'
PATS = [
    (re.compile(r'(php_die|php_write)\(' + LIT + r',\s*(\d+)\)'), 1, 2, None),
    (re.compile(r'php_memcpy\([^,]+,\s*' + LIT + r',\s*(\d+)\)'), 0, 1, None),
    (re.compile(r'ph_strlit\(' + LIT + r',\s*(\d+)\)'), 0, 1, None),
    (re.compile(r'p_cat\([^,"]+,\s*' + LIT + r',\s*(\d+),\s*(\d+)\)'), 0, 2, 1),
]


def real_len(lit):
    return len(lit.encode().decode('unicode_escape').encode('latin-1'))


def main():
    bad = n = 0
    for name in ('php.mc', 'php_rt.txt'):
        src = open(os.path.join(HERE, name)).read()
        for pat, gl, gn, goff in PATS:
            for m in pat.finditer(src):
                g = m.groups()
                lit = g[gl]
                want = int(g[gn])
                off = int(g[goff]) if goff is not None else 0
                n += 1
                have = real_len(lit) - off
                if have != want:
                    print(f'{name}: "{lit}" is {have} bytes, written as {want}')
                    bad += 1
    print(f'lencheck: {n} literal lengths, {bad} wrong')
    sys.exit(1 if bad else 0)


main()

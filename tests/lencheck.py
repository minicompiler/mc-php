#!/usr/bin/env python3
"""Every (literal, length) pair in the sources must agree.

php_die("...", N), php_write("...", N), php_memcpy(d, "...", N), p_cat(x, "...",
off, N) and ph_strlit("...", N) all carry a HAND-COUNTED length beside a string
literal, and mc will not check it: a length one short truncates the message, one
long reads a byte past the literal. Four were wrong when this check was written.

    python3 tests/lencheck.py       # exits 1 on any mismatch
"""
import os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SRC = [os.path.join('src', f) for f in sorted(os.listdir(os.path.join(ROOT, 'src')))
       if f.endswith('.mc')] + sorted(
           os.path.join('lib', f) for f in os.listdir(os.path.join(ROOT, 'lib'))
           if f.endswith('.mc'))
LIT = r'"((?:[^"\\]|\\.)*)"'
PATS = [
    (re.compile(r'(php_die|php_write)\(' + LIT + r',\s*(\d+)\)'), 1, 2, None),
    (re.compile(r'php_memcpy\([^,]+,\s*' + LIT + r',\s*(\d+)\)'), 0, 1, None),
    (re.compile(r'ph_strlit\(' + LIT + r',\s*(\d+)\)'), 0, 1, None),
    # T9: php_str_new and php_mput carry a hand-counted length too, and the
    # check did not cover either -- one of them was ten bytes long, which
    # reads past the literal into whatever the linker put next.
    (re.compile(r'php_str_new\(' + LIT + r',\s*(\d+)\)'), 0, 1, None),
    (re.compile(r'php_mput\(' + LIT + r',\s*(\d+)\)'), 0, 1, None),
    (re.compile(r'p_cat\([^,"]+,\s*' + LIT + r',\s*(\d+),\s*(\d+)\)'), 0, 2, 1),
    # hosts: ph_pre's third column is the LENGTH when the kind is 1 (string),
    # and it was 0 on two rows -- DIRECTORY_SEPARATOR and PATH_SEPARATOR both
    # compiled to the empty string, every probe since they were added
    # (issue #11). The length is written as the row's THIRD field and the
    # literal as its fourth, so the pair is reversed against every other
    # pattern here: the number comes first.
    (re.compile(r'ph_pre\("[^"]*",\s*1,\s*(\d+),\s*' + LIT + r'\)'), 1, 0, None),
]


def real_len(lit):
    return len(lit.encode().decode('unicode_escape').encode('latin-1'))


def main():
    bad = n = 0
    for name in SRC:
        src = open(os.path.join(ROOT, name)).read()
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

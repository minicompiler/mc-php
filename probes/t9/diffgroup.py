#!/usr/bin/env python3
"""Cluster the `(compiled; output differs)` tests by WHAT differs.

T6 left 536 of 1417 sampled `wrong` tests in one bucket: the program compiled,
it ran, and it printed the wrong thing. That is the largest single reason and
the least structured, so this takes it apart -- it runs php and the mc-php
binary on the same --FILE--, finds the FIRST differing line, and groups by the
shape of that line, which is what says whether a fix is one bug or a hundred.

    python3 probes/t9/diffgroup.py OUT.tsv [FILE.phpt ...]      (else stdin)

Reads the same list why.py reads (a `wrong.txt` column 1, or why.tsv filtered
to `(compiled; output differs)`); writes one row per test:

    <path>\t<group>\t<php line>\t<mc-php line>
"""
import os, re, subprocess, sys, tempfile
from collections import Counter
from concurrent.futures import ThreadPoolExecutor


def _mkpath(prefix='', suffix=''):
    # mkstemp, not mktemp: the name is reserved by the kernel, so no other
    # process can win the race between choosing it and creating it. The file
    # is unlinked here and re-created by the writer, which is what the callers
    # want (a PATH, not a handle) without the TOCTOU.
    fd, path = tempfile.mkstemp(prefix=prefix, suffix=suffix)
    os.close(fd)
    os.unlink(path)
    return path

HERE = os.path.dirname(os.path.abspath(__file__))
MCPHP = os.environ.get('MCPHP_BIN', os.path.join(HERE, 'mc-php'))
PHP = os.environ.get('PHP', 'php')
SEC = re.compile(r'^--FILE--\r?\n(.*?)(?=^--[A-Z_]+--)', re.S | re.M)
INI = ['-d', 'error_reporting=30719', '-d', 'display_errors=1', '-d', 'log_errors=0',
       '-d', 'html_errors=0', '-d', 'precision=14', '-d', 'serialize_precision=-1',
       '-d', 'date.timezone=UTC', '-d', 'output_buffering=Off', '-d', 'docref_root=']

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
    try:
        src = open(path, 'rb').read().decode('latin-1')
    except OSError:
        return None
    m = SEC.search(src)
    if not m:
        return None
    php = os.path.abspath(path[:-5] + '.dg.php')
    binf = _mkpath(prefix='dg.', suffix='.bin')
    d = os.path.dirname(os.path.abspath(path)) or '.'
    try:
        open(php, 'w', encoding='latin-1', newline='').write(m.group(1))
        c = subprocess.run([MCPHP, '--exe', php, '-o', binf], stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, timeout=40)
        if c.returncode != 0:
            return (path, '(does not compile)', '', '')
        g = subprocess.run([binf], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                           cwd=d, timeout=20)
        e = subprocess.run([PHP] + INI + ['-q', php], stdout=subprocess.PIPE,
                           stderr=subprocess.DEVNULL, cwd=d, timeout=20)
    except subprocess.TimeoutExpired:
        return (path, '(timed out)', '', '')
    except OSError as ex:
        return (path, f'(cannot run: {ex.__class__.__name__})', '', '')
    finally:
        for f in (php, binf):
            try: os.unlink(f)
            except OSError: pass
    want = e.stdout.decode('latin-1').rstrip('\n').split('\n')
    got = g.stdout.decode('latin-1').rstrip('\n').split('\n')
    if want == got:
        return (path, '(agrees on this harness)', '', '')
    for i in range(max(len(want), len(got))):
        a = want[i] if i < len(want) else '<eof>'
        b = got[i] if i < len(got) else '<eof>'
        if a != b:
            return (path, shape(a, b), a[:120], b[:120])
    return (path, '(agrees on this harness)', '', '')


def main():
    out = sys.argv[1]
    files = sys.argv[2:] or [l.split('\t')[0].strip() for l in sys.stdin if l.strip()]
    with ThreadPoolExecutor(max_workers=os.cpu_count() or 8) as ex:
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

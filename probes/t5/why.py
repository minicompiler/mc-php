#!/usr/bin/env python3
"""Ask the compiler WHY each .phpt in a list is `wrong`.

The grid says a test disagreed; this says what mc-php had to say about its
--FILE-- section -- the first diagnostic, or `(compiled; output differs)` when
it built a binary that then printed the wrong thing. That list is T6's plan,
so it is a script and not a paragraph.

    python3 probes/t5/why.py OUT.tsv [FILE.phpt ...]      (else stdin)
"""
import os, re, subprocess, sys, tempfile
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
MCPHP = os.environ.get('MCPHP_BIN', os.path.join(HERE, 'mc-php'))
SEC = re.compile(r'^--FILE--\r?\n(.*?)(?=^--[A-Z_]+--)', re.S | re.M)


def why(path):
    try:
        src = open(path, 'rb').read().decode('latin-1')
    except OSError as e:
        return path, f'(unreadable: {e})'
    m = SEC.search(src)
    if not m:
        return path, '(no --FILE-- section)'
    # next to the .phpt, like php-src's own runner: __DIR__ and siblings resolve
    php = path[:-5] + '.why.php'
    binf = tempfile.mktemp(prefix='why.', suffix='.bin')
    try:
        open(php, 'w').write(m.group(1))
        p = subprocess.run([MCPHP, '--exe', php, '-o', binf],
                           stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=30)
        msg = p.stderr.decode('latin-1', 'replace').splitlines()
        if p.returncode == 0:
            return path, '(compiled; output differs)'
        return path, (msg[0] if msg else f'(exit {p.returncode}, silent)')
    except subprocess.TimeoutExpired:
        return path, '(compiler timed out)'
    finally:
        for f in (php, binf):
            try: os.unlink(f)
            except OSError: pass


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

#!/usr/bin/env python3
"""How often is `mc-php: arena exhausted` the answer?

docs/plan.md D7 has no refcount and no free, so a php array -- which is a
VALUE -- is copied EAGERLY at every hand-over, and T6 measured the 48 MiB
arena exhausted between 500 and 1000 copies of a 2000-element array. The
question this answers is whether that, or anything else, actually bites the
corpus: it compiles and RUNS every test in the list and counts the ones whose
stderr says the arena ran out.

    python3 probes/t9/arena.py < LIST-OF-PHPT      (one path per line)
"""
import os, re, subprocess, sys, tempfile
from concurrent.futures import ThreadPoolExecutor
MC = os.environ.get('MCPHP_BIN',
                    os.path.join(os.path.dirname(os.path.abspath(__file__)), 'mc-php'))
SEC = re.compile(r'^--FILE--\r?\n(.*?)(?=^--[A-Z_]+--)', re.S | re.M)
def one(p):
    try: s=open(p,'rb').read().decode('latin-1')
    except OSError: return None
    m=SEC.search(s)
    if not m: return None
    php=os.path.abspath(p[:-5]+'.ar.php'); b=tempfile.mktemp(suffix='.bin')
    d=os.path.dirname(php)
    try:
        open(php,'w').write(m.group(1))
        c=subprocess.run([MC,'--exe',php,'-o',b],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=40)
        if c.returncode!=0: return None
        r=subprocess.run([b],stdout=subprocess.DEVNULL,stderr=subprocess.PIPE,cwd=d,timeout=20)
        return p if b'arena exhausted' in r.stderr else None
    except Exception: return None
    finally:
        for f in (php,b):
            try: os.unlink(f)
            except OSError: pass
files=[l.split('\t')[0].strip() for l in sys.stdin if l.strip()]
with ThreadPoolExecutor(max_workers=6) as ex: rows=[r for r in ex.map(one,files) if r]
print(f'arena exhausted in {len(rows)} of {len(files)} tests')
for r in rows[:20]: print(' ',r)

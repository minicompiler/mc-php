#!/usr/bin/env python3
"""T0's corpus breakdown -- how much of the .phpt corpus docs/plan.md's
decisions actually touch, measured with the real tokenizer (token_get_all
via probes/t0/classify.php), not a regex over the source.

Walks --root (default php-src) for every *.phpt, extracts each --FILE--
section and classifies it for:

  D1        eval() / create_function() / assert(STRING)
  D5        include/require/_once of anything but a plain string literal
            (reported with, separately, how many of those are an
            spl_autoload_register() call -- the computed-autoload shape)
  D6        $$name, $obj->$dynamic(), new $c, $c::..., any Reflection*
            class, or one of the seven introspection functions D6 names
  D4-suspect  a variable assigned two DIFFERENT literal kinds (number,
            string, bool/null, array) inside the same lexical function
            scope -- an APPROXIMATION: it is a token-level heuristic over
            literal assignments, not a type-inference pass, and it can
            both miss a real conflict (assigned from an expression, not a
            literal) and manufacture one $$name can produce (guarded, see
            classify.php's own comment for the one guard it has).

Prints one table: total tests; per decision, the count and percentage of
the CLASSIFIABLE ones it touches; the count touched by NONE of them (the
reachable target of the first milestones); the count per top-level
directory; the count and touched-count per non-core extension.

Usage: sh probes/t0/breakdown.py [--root php-src] [--out probes/t0/out]
Exits 0 only when at least one .phpt was classified.
"""
import argparse
import collections
import os
import subprocess
import sys

CORE_EXTS = {'standard', 'spl', 'date', 'json', 'pcre', 'ctype', 'mbstring', 'hash', 'random'}

HERE = os.path.dirname(os.path.abspath(__file__))


def top_dir(relpath):
    parts = relpath.split('/')
    if parts[0] == 'ext' and len(parts) >= 3:
        return '/'.join(parts[:3])
    if len(parts) >= 2:
        return '/'.join(parts[:2])
    return parts[0]


def ext_name(relpath):
    parts = relpath.split('/')
    if parts[0] == 'ext' and len(parts) >= 2:
        return parts[1]
    return None


def find_phpt(root):
    out = []
    for dp, dn, fn in os.walk(root):
        for name in fn:
            if name.endswith('.phpt'):
                out.append(os.path.join(dp, name))
    out.sort()
    return out


def classify_all(php, classify_php, files):
    p = subprocess.run([php, classify_php],
                        input=('\n'.join(files) + '\n').encode('latin-1'),
                        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if p.returncode != 0:
        sys.stderr.write(p.stderr.decode('latin-1', 'replace'))
        raise SystemExit(f'classify.php exited {p.returncode}')
    rows = []
    for line in p.stdout.decode('latin-1', 'replace').splitlines():
        parts = line.split('|')
        if len(parts) != 7:
            continue
        path, d1, d5, autoload, d6, d4, status = parts
        rows.append(dict(path=path, d1=int(d1), d5=int(d5), autoload=int(autoload),
                          d6=int(d6), d4=int(d4), status=status))
    return rows


def pct(n, d):
    return f'{100.0 * n / d:5.1f}%' if d else '  n/a'


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                  formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--root', default='php-src')
    ap.add_argument('--php', default=os.environ.get('PHP', 'php'))
    ap.add_argument('--classify', default=os.path.join(HERE, 'classify.php'))
    ap.add_argument('--out', default=None, help='directory to write the raw per-file table into')
    args = ap.parse_args()

    root = os.path.abspath(args.root)
    files = find_phpt(root)
    if not files:
        print(f'breakdown: no .phpt found under {root}', file=sys.stderr)
        sys.exit(2)

    rows = classify_all(args.php, args.classify, files)
    if not rows:
        print('breakdown: classify.php produced nothing', file=sys.stderr)
        sys.exit(2)

    if args.out:
        os.makedirs(args.out, exist_ok=True)
        with open(os.path.join(args.out, 'breakdown.tsv'), 'w') as f:
            f.write('path\td1\td5\tautoload\td6\td4\tstatus\n')
            for r in rows:
                f.write('{path}\t{d1}\t{d5}\t{autoload}\t{d6}\t{d4}\t{status}\n'.format(**r))

    total = len(rows)
    status_counts = collections.Counter(r['status'] for r in rows)
    ok_rows = [r for r in rows if r['status'] == 'ok']
    n_ok = len(ok_rows)

    def touched(r):
        return r['d1'] or r['d5'] or r['autoload'] or r['d6'] or r['d4']

    d1c = sum(r['d1'] for r in ok_rows)
    d5_only = sum(r['d5'] for r in ok_rows)
    autoloadc = sum(r['autoload'] for r in ok_rows)
    d5c = sum(1 for r in ok_rows if r['d5'] or r['autoload'])
    d6c = sum(r['d6'] for r in ok_rows)
    d4c = sum(r['d4'] for r in ok_rows)
    nonec = sum(1 for r in ok_rows if not touched(r))
    anyc = n_ok - nonec

    print(f'breakdown: {total} .phpt under {os.path.relpath(root)}')
    for status, c in sorted(status_counts.items()):
        if status != 'ok':
            print(f'  {status}: {c} (excluded from the table below)')
    print(f'  classifiable (--FILE-- tokenized cleanly): {n_ok}')
    print()
    print('  decision                                          touched     pct')
    print(f'  D1  eval / create_function / assert(string)      {d1c:7d}  {pct(d1c, n_ok)}')
    print(f'  D5  include/require of a computed path            {d5c:7d}  {pct(d5c, n_ok)}')
    print(f'        of which spl_autoload_register-shaped       {autoloadc:7d}  {pct(autoloadc, n_ok)}')
    print(f'        (non-autoload computed path alone)          {d5_only:7d}  {pct(d5_only, n_ok)}')
    print(f'  D6  dynamic dispatch / reflection                 {d6c:7d}  {pct(d6c, n_ok)}')
    print(f'  D4  suspect: reassigned with another literal kind {d4c:7d}  {pct(d4c, n_ok)}  (heuristic)')
    print()
    print(f'  touched by at least one                           {anyc:7d}  {pct(anyc, n_ok)}')
    print(f'  touched by NONE (the reachable target)             {nonec:7d}  {pct(nonec, n_ok)}')
    print()
    print('  per top-level directory:')
    dirs = collections.Counter(top_dir(os.path.relpath(r['path'], root)) for r in rows)
    for d, c in sorted(dirs.items(), key=lambda kv: (-kv[1], kv[0])):
        print(f'    {d:40s} {c:6d}')
    print()
    print(f'  per extension (ext/<name>, {len(CORE_EXTS)} core ones excluded: '
          f'{" ".join(sorted(CORE_EXTS))}):')
    ext_total = collections.Counter()
    ext_touched = collections.Counter()
    ok_by_path = {r['path']: r for r in ok_rows}
    for r in rows:
        e = ext_name(os.path.relpath(r['path'], root))
        if e is None or e in CORE_EXTS:
            continue
        ext_total[e] += 1
        r_ok = ok_by_path.get(r['path'])
        if r_ok and touched(r_ok):
            ext_touched[e] += 1
    sum_total = sum(ext_total.values())
    sum_touched = sum(ext_touched.values())
    for e, c in sorted(ext_total.items(), key=lambda kv: (-kv[1], kv[0])):
        print(f'    {e:20s} {c:6d}   touched {ext_touched[e]:6d}')
    print(f'    {"TOTAL extension-specific":20s} {sum_total:6d}   touched {sum_touched:6d}')
    sys.exit(0)


if __name__ == '__main__':
    main()

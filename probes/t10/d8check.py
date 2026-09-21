#!/usr/bin/env python3
"""D8 over every `.php` this probe wrote -- no file waives the rule for itself.

`docs/review-backlog.md` section 3: D8's text covers "fixtures, any part of
the runtime or standard library written in PHP, examples", and the `.php`
under `probes/*/g` and `probes/*/r` carried neither a PHPUnit class nor a
bench row. Either they carry them, or the plan states why -- and a probe
cannot waive the rule for itself, so the statement has to be ENFORCED and not
written down.

This is the enforcement. Every `.php` under the probe is put in exactly one
of four regimes, each with its own obligation, and a file in none of them
fails the run:

  fixture    `g/*.php`, `r/*.php`. Its test is the DIFFERENTIAL gate itself
             (`fixtures.sh`): stdout, stderr and the exit code compared byte
             for byte against `php` on the same source. That is a stronger
             assertion than an `assertSame` -- the oracle is the reference
             implementation, not a value someone typed -- and it runs in both
             worlds by construction, which is what D8 (a) asks of a test. It
             carries no bench row because a three-line program measures
             process start-up and nothing else (T9 measured that: php pays
             ~38 ms before the first statement).
  instrument the mechanism of D8 (a) itself -- the `TestCase` shim, the test
             class, the runner that names the test methods. Testing the test
             harness with the test harness is a circle.
  library    required BY the test class and BY a bench program: exercised in
             both worlds by the first and timed in both by the second.
  bench      a row in `bench10.sh`, which runs it under `php` and as an
             mc-php binary, REFUSES to time them unless the two answers are
             equal, and prints the ratio.

    python3 probes/t10/d8check.py
"""
import os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
REQ = re.compile(r'(?:require|include)(?:_once)?\s*\(?\s*__DIR__\s*\.\s*"/([^"]+)"')

INSTRUMENTS = {
    'bench/shim.php': 'the TestCase shim D8 (a) names (phpunit cannot run on mc-php)',
    'bench/WorkloadTest.php': 'the PHPUnit test class itself',
    'bench/run.php': 'the mc-php runner that NAMES the test methods (D6: no reflection)',
}


def rel(p):
    return os.path.relpath(p, HERE)


def reach(start):
    """`start` and everything it requires, transitively."""
    seen, todo = set(), [start]
    while todo:
        f = todo.pop()
        if f in seen or not os.path.exists(f):
            continue
        seen.add(f)
        src = open(f, encoding='latin-1').read()
        for m in REQ.finditer(src):
            todo.append(os.path.join(os.path.dirname(f), m.group(1)))
    return {rel(f) for f in seen}


def bench_programs():
    """The programs bench10.sh times, read out of the script."""
    src = open(os.path.join(HERE, 'bench/bench10.sh'), encoding='latin-1').read()
    m = re.search(r'^for prog in (.+?); do', src, re.M)
    if not m:
        sys.exit('d8check: bench10.sh has no `for prog in ...` list')
    return [w for w in m.group(1).split() if w.endswith('.php')]


def fixture_globs():
    """The two globs fixtures.sh walks -- so a fixture cannot be orphaned."""
    src = open(os.path.join(HERE, 'fixtures.sh'), encoding='latin-1').read()
    return set(re.findall(r'for f in \$P/(\w+)/\*\.php; do', src))


def main():
    globs = fixture_globs()
    if globs != {'g', 'r'}:
        sys.exit(f'd8check: fixtures.sh walks {sorted(globs)}, expected g and r')

    tested = reach(os.path.join(HERE, 'bench/WorkloadTest.php'))
    benched = set()
    for prog in bench_programs():
        benched |= reach(os.path.join(HERE, 'bench', prog))

    files = []
    for root, dirs, names in os.walk(HERE):
        dirs[:] = [d for d in dirs if d != 'out']
        files += [rel(os.path.join(root, n)) for n in names if n.endswith('.php')]
    files.sort()

    counts = {'fixture': 0, 'instrument': 0, 'library': 0, 'bench': 0}
    bad = []
    for f in files:
        d = f.split('/')[0]
        if d in globs and f.count('/') == 1:
            counts['fixture'] += 1
        elif f in INSTRUMENTS:
            counts['instrument'] += 1
        elif f in tested and f in benched:
            counts['library'] += 1
        elif f in benched:
            counts['bench'] += 1
        else:
            bad.append(f)

    for k in ('fixture', 'instrument', 'library', 'bench'):
        print(f'  {counts[k]:4d}  {k}')
    if not counts['library'] and not counts['bench']:
        bad.append('(nothing is benched at all)')
    if bad:
        print('\n  D8: a .php in NO regime -- it has neither a test in both '
              'worlds nor a bench row:')
        for f in bad:
            print(f'        {f}')
        print('  (docs/plan.md D8; give it a test and a bench row, make it a '
              'fixture, or delete it)')
        return 1
    print(f'  d8: {len(files)} .php, every one in a regime with its obligation')
    return 0


sys.exit(main())

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

  helper     a `g/` file another fixture `require`s and the gate does not
             run on its own -- `inc.php`. Its test is every fixture that
             includes it, and this checks that at least one does.
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



# A whole-line comment names a file, it does not run one. Dropping them is
# what stops a `# probes/t9/bench/unwind.php` in prose from standing in for a
# gate -- the second half of the same finding as the self-reference above.
def _uncomment(src):
    out = []
    for line in src.splitlines():
        t = line.lstrip()
        if t.startswith('#') or t.startswith('//'):
            continue
        out.append(line)
    return '\n'.join(out)


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


def test_methods_are_all_run():
    """Every `test*` the class declares is NAMED by the runner, and back.

    D8 (a) wants the SAME file run in both worlds. Under php with the real
    phpunit installed the runner is phpunit, which DISCOVERS the methods;
    under mc-php D6 forbids discovering them at run time, so `run.php` names
    them and `mc-php test` (which does not exist yet) is what will do it from
    the compiler. Until then the list is written by hand, and a hand-written
    list is a thing that goes stale: a test method added to the class and not
    added to the runner would be reported as passing without ever running.
    This is what stops that.
    """
    cls = open(os.path.join(HERE, 'bench/WorkloadTest.php'), encoding='latin-1').read()
    run = open(os.path.join(HERE, 'bench/run.php'), encoding='latin-1').read()
    declared = set(re.findall(r'function\s+(test\w+)\s*\(', cls))
    named = set(re.findall(r'"(test\w+)"', run))
    if declared == named and declared:
        print(f'  {len(declared):4d}  test* methods declared, and every one named by the runner')
        return []
    bad = []
    for m in sorted(declared - named):
        bad.append(f'{m}: declared by WorkloadTest.php, run by nobody')
    for m in sorted(named - declared):
        bad.append(f'{m}: named by run.php, declared by nobody')
    if not declared:
        bad.append('WorkloadTest.php declares no test* method')
    return bad


# Directories whose `.php` were written BEFORE D8 was decided (owner,
# 2026-09-15) and are not programs: T4's are one lexical construct each, fed
# to `--dump-tokens` by a glob in its own run.sh, and the gap probes' are the
# six shapes the mc lexer could not own. Each is named with its reason, and
# the sweep below FAILS when one of them is gone -- so the list cannot rot
# into an excuse for a directory nobody looks at any more.
PRE_D8 = {
    'probes/t0': 'T0 predates D8: classify.php is read by breakdown.py, not run',
    'probes/t4': 'T4 predates D8: one lexical construct per file, globbed by its own run.sh',
    'probes/gap-lexer-ownership': 'the six shapes the mc lexer could not own, globbed by run.sh',
}

REPO = os.path.abspath(os.path.join(HERE, '..', '..'))


def every_php():
    out = []
    for root, dirs, names in os.walk(os.path.join(REPO, 'probes')):
        dirs[:] = [d for d in dirs if d != 'out']
        out += [os.path.relpath(os.path.join(root, n), REPO)
                for n in names if n.endswith('.php')]
    return sorted(out)


def repo_sweep():
    """No `.php` under probes/ outside a regime -- the WHOLE tree, not t10.

    D8 covers every `.php` in this repository and `d8check.py` walked
    `probes/t10` alone, so the orphan it was written to catch could sit in
    any other probe and pass: `probes/t9/bench/unwind.php` did, while t9's
    own bench script runs `probes/t6/bench/unwind.php`. A file is accounted
    for when it is a fixture (`<probe>/g|r/`), when another `.php` requires
    it, when a script names its PATH, when a bench script names its
    BASENAME in a `for prog in` list, or when it is under a PRE_D8
    directory.
    """
    bad = []
    for d, why in sorted(PRE_D8.items()):
        if not os.path.isdir(os.path.join(REPO, d)):
            bad.append(f'{d}: exempted as "{why}" and it is not there')
        elif os.path.isdir(os.path.join(REPO, d, 'bench')):
            bad.append(f'{d}: exempted as pre-D8 and it has grown a bench/')

    # One entry per source, NOT one concatenated string: a file that names
    # its own path -- in a comment, in its own doc string -- was proving
    # itself referenced. Each candidate is searched in every OTHER source.
    srcs = {}
    required = set()
    for root, dirs, names in os.walk(os.path.join(REPO, 'probes')):
        dirs[:] = [d for d in dirs if d != 'out']
        for n in names:
            # what RUNS a file, not what mentions it: a .md that names a
            # path is prose, and t9's own RESULTS.md naming its orphan is
            # exactly how the orphan stayed invisible.
            if not n.endswith(('.sh', '.py', '.php')):
                continue
            f = os.path.join(root, n)
            # and NOT this file: its own doc comment names the orphan it was
            # written to catch, which is enough to make the sweep believe
            # something references it. Measured -- t9's copy was invisible
            # until this line.
            if os.path.abspath(f) == os.path.abspath(__file__):
                continue
            try:
                src = open(f, encoding='latin-1').read()
            except OSError:
                continue
            srcs[os.path.relpath(f, REPO)] = _uncomment(src)
            if n.endswith('.php'):
                for m in REQ.finditer(src):
                    required.add(os.path.relpath(
                        os.path.join(os.path.dirname(f), m.group(1)), REPO))
    text = '\n'.join(srcs.values())
    progs = set(re.findall(r'^for prog in (.+?); do', text, re.M))
    basenames = {w for line in progs for w in line.split() if w.endswith('.php')}

    n = 0
    for f in every_php():
        n += 1
        parts = f.split('/')
        if any(f.startswith(d + '/') for d in PRE_D8):
            continue
        if len(parts) >= 3 and parts[2] in ('g', 'r'):
            continue
        if f in required:
            continue
        # every source but this one
        if any(f in t for p, t in srcs.items() if p != f):
            continue
        if os.path.basename(f) in basenames:
            continue
        bad.append(f'{f}: no fixture gate runs it, no .php requires it, '
                   f'no script names it')
    print(f'  {n:4d}  .php under probes/, swept for orphans')
    return bad


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

    # a g/ file that another fixture requires, and that fixtures.sh
    # therefore skips: the gate's own `case ... in inc.php) continue` list
    helpers = set(re.findall(r'case \$\(basename "\$f"\) in (\S+)\)',
                             open(os.path.join(HERE, 'fixtures.sh'),
                                  encoding='latin-1').read()))
    included = set()
    for f in files:
        if f.split('/')[0] in globs:
            src = open(os.path.join(HERE, f), encoding='latin-1').read()
            for m in re.finditer(r"(?:require|include)(?:_once)?[^;]*?['\"]([^'\"]+\.php)", src):
                included.add(os.path.basename(m.group(1)))

    counts = {'fixture': 0, 'helper': 0, 'instrument': 0, 'library': 0, 'bench': 0}
    bad = []
    for f in files:
        d = f.split('/')[0]
        if d in globs and os.path.basename(f) in helpers:
            if os.path.basename(f) in included:
                counts['helper'] += 1
            else:
                bad.append(f'{f}: skipped by the gate and required by no fixture')
        elif d in globs and f.count('/') == 1:
            counts['fixture'] += 1
        elif f in INSTRUMENTS:
            counts['instrument'] += 1
        elif f in tested and f in benched:
            counts['library'] += 1
        elif f in benched:
            counts['bench'] += 1
        else:
            bad.append(f)

    for k in ('fixture', 'helper', 'instrument', 'library', 'bench'):
        print(f'  {counts[k]:4d}  {k}')
    bad += test_methods_are_all_run()
    bad += repo_sweep()
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

#!/usr/bin/env python3
"""D8 over every `.php` this repository wrote -- no file waives the rule.

Carved from probes/t10/d8check.py. The one difference is the sweep: the
probe walks `probes/` with its pre-D8 exemptions, this walks the project
and has none.

`docs/review-backlog.md` section 3: D8's text covers "fixtures, any part of
the runtime or standard library written in PHP, examples", and the `.php`
under `probes/*/g` and `probes/*/r` carried neither a PHPUnit class nor a
bench row. Either they carry them, or the plan states why -- and a probe
cannot waive the rule for itself, so the statement has to be ENFORCED and not
written down.

This is the enforcement. Every `.php` under the probe is put in exactly one
of SIX regimes, each with its own obligation, and a file in none of them
fails the run:

  helper     a `g/` file another fixture `require`s and the gate does not
             run on its own -- `inc.php`. Its test is every fixture that
             includes it, and this checks that at least one does.
  fixture    `g/*.php`. Its test is the DIFFERENTIAL gate itself
             (`fixtures.sh`): stdout, stderr and the exit code compared byte
             for byte against `php` on the same source. That is a stronger
             assertion than an `assertSame` -- the oracle is the reference
             implementation, not a value someone typed -- and it runs in both
             worlds by construction, which is what D8 (a) asks of a test. It
             carries no bench row because a three-line program measures
             process start-up and nothing else (T9 measured that: php pays
             ~38 ms before the first statement).
  refusal    `r/*.php`. NOT a byte-for-byte pair, and it cannot be: the
             point of the file is that mc-php DECLINES it. Its test is the
             pair `fixtures.sh` runs -- php PARSES it (`php -l`) and mc-php
             refuses it with a named message and exit 3 -- which is what
             makes "mc-php refuses what php accepts" a measurement.
  instrument the mechanism of D8 (a) itself -- the `TestCase` shim, the test
             class, the runner that names the test methods. Testing the test
             harness with the test harness is a circle.
  library    required BY the test class and BY a bench program: exercised in
             both worlds by the first and timed in both by the second.
  bench      a row in `bench10.sh`, which runs it under `php` and as an
             mc-php binary, REFUSES to time them unless the two answers are
             equal, and prints the ratio.

    python3 tests/d8check.py
"""
import os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
# BOTH quote styles: `g/72-require-dir.php` writes one of each, and the
# single-quoted form was invisible to `reach()` and to the repo-wide
# sweep, so a library or a bench helper required that way would have
# been reported as an orphan.
REQ = re.compile(r'(?:require|include)(?:_once)?\s*\(?\s*__DIR__\s*\.\s*'
                 r'(?:"/([^"]+)"|\'/([^\']+)\')')

INSTRUMENTS = {
    'bench/shim.php': 'the TestCase shim D8 (a) names (phpunit cannot run on mc-php)',
    'bench/WorkloadTest.php': 'the PHPUnit test class itself',
    'bench/run.php': 'the mc-php runner that NAMES the test methods (D6: no reflection)',
}



# A whole-line comment names a file, it does not run one. Dropping them is
# what stops a `# probes/t9/bench/unwind.php` in prose from standing in for a
# gate -- the second half of the same finding as the self-reference above.
def _uncomment(src):
    """Drop what MENTIONS a path from what RUNS one, as far as text can.

    Whole-line comments were not enough: an inline `# probes/t9/x.php` at
    the end of a command, or a python docstring naming the file it hunts,
    reads the same to a substring search. Triple-quoted blocks go first,
    then a `#` or `//` tail that is not inside a quote. What CANNOT be told
    apart this way is a path in an ordinary string literal that nothing
    executes -- the remaining hole, and the reason `required` (a parsed
    `require`) and `benched` (a resolved bench loop) are separate, exact
    answers rather than part of this scan.
    """
    src = re.sub(r'/\*[\s\S]*?\*/', '', src)      # php and C block comments
    src = re.sub(r'"""[\s\S]*?"""', '', src)
    src = re.sub(r"\'\'\'[\s\S]*?\'\'\'", '', src)
    out = []
    for line in src.splitlines():
        t = line.lstrip()
        if t.startswith('#') or t.startswith('//'):
            continue
        # a line that PRINTS a path does not run it. `echo "see
        # probes/x/y.php"` reads to a substring search exactly like
        # `"$PHP" probes/x/y.php`, and the three files this scan really
        # carries (`probes/t*/bench/run.php` and T6's `unwind.php`) are all
        # arguments of a command, never of an echo.
        if re.match(r'(echo|printf|print)\b|print\s*\(', t):
            continue
        keep, q = [], ''
        i = 0
        while i < len(line):
            c = line[i]
            if q:
                if c == '\\':
                    keep.append(line[i:i + 2]); i += 2; continue
                if c == q:
                    q = ''
            elif c in '"\'':
                q = c
            elif c == '#' or line[i:i + 2] == '//':
                break
            keep.append(c)
            i += 1
        out.append(''.join(keep))
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
            todo.append(os.path.join(os.path.dirname(f),
                                     m.group(1) or m.group(2)))
    return {rel(f) for f in seen}


def bench_programs():
    """The programs bench10.sh times, read out of the script."""
    src = open(os.path.join(HERE, 'bench/bench10.sh'), encoding='latin-1').read()
    m = re.search(r'^for prog in (.+?); do', src, re.M)
    if not m:
        sys.exit('d8check: bench10.sh has no `for prog in ...` list')
    return [w for w in m.group(1).split() if w.endswith('.php')]


def fixture_globs(probe=None):
    """The globs a probe's fixtures.sh walks -- so a fixture cannot be orphaned.

    With no argument, T10's own. With a probe directory, that probe's, and
    the empty set when it has no fixtures.sh: the repo-wide sweep used to
    exempt every `probes/*/g` and `probes/*/r` by NAME, so an unreferenced
    `probes/new/g/orphan.php` passed the only repository-wide check even
    though nothing ran it.
    """
    if probe is None:
        src = open(os.path.join(HERE, 'fixtures.sh'), encoding='latin-1').read()
        return set(re.findall(r'for f in \$P/(\w+)/\*\.php; do', src))
    # every .sh of that probe, in both spellings the repository uses: T8 and
    # T9 write `for f in probes/tN/g/*.php` in their own fixtures.sh, T5..T7
    # write it in run.sh, and T10 writes `$P/g`. A directory nothing walks is
    # not exempt whatever it is called.
    d = os.path.join(REPO, probe)
    out = set()
    try:
        names = sorted(os.listdir(d))
    except OSError:
        return out
    for n in names:
        if not n.endswith('.sh'):
            continue
        try:
            src = open(os.path.join(d, n), encoding='latin-1').read()
        except OSError:
            continue
        out |= set(re.findall(r'for \w+ in \$P/(\w+)/\*\.php', src))
        out |= set(re.findall(r'for \w+ in ' + re.escape(probe) + r'/(\w+)/\*\.php', src))
    return out


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


REPO = os.path.abspath(os.path.join(HERE, '..'))


def project_sweep():
    """No `.php` in the PROJECT outside a regime.

    `probes/` is excluded and keeps its own copy of this check: it is the
    frozen measurement record and its exemptions are archaeology (T0's and
    T4's files predate D8 by the owner's decision of 2026-09-15). This one
    covers what the project ships, which today is `tests/` and nothing else.

    `main()` already puts every `.php` under `tests/` in a regime, so all
    this adds is the part `main()` cannot see: a `.php` that is in the
    repository and NOT under `tests/` -- an `examples/` program, a fixture
    dropped at the root -- has no regime at all and no gate runs it.

    There is one such place, and it is the SEVENTH regime: `extension`. An
    `examples/<name>/` directory is a PHP extension's source, and its
    obligation is `tests/ext.sh` -- which builds it into a `.so`, loads it
    under `php` and compares its answers with php's own, on both streams and
    the exit code. That is a differential and a stronger one than a bench
    row, which is the same exemption `docs/plan.md` D8 already gives a
    fixture. What is checked here is that the gate NAMES the directory: an
    example the script does not build is in no regime again.
    """
    bad = []
    n = 0
    ext = open(os.path.join(HERE, 'ext.sh'), encoding='latin-1').read()
    for root, dirs, names in os.walk(REPO):
        # `reference/` is excluded for the reason `probes/` is: it is a
        # RECORD of what was measured by hand, in mc, before the compiler
        # could produce it -- not something this project ships and not
        # something any gate compiles. reference/README.md says so in its
        # first line, and the day mc-php emits one of those files it moves
        # to examples/ and picks up the extension regime with it.
        dirs[:] = [d for d in dirs
                   if d not in ('probes', 'build', 'php-src', '.git',
                                'reference')]
        for f in names:
            if not f.endswith('.php'):
                continue
            rp = os.path.relpath(os.path.join(root, f), REPO)
            n += 1
            top = rp.split('/')
            if top[0] == 'tests':
                continue
            if top[0] == 'examples' and len(top) == 3 and f'examples/{top[1]}' in ext:
                continue
            if top[0] == 'examples':
                bad.append(f'{rp}: under examples/ but tests/ext.sh does not '
                           f'build examples/{top[1]} (docs/plan.md D8)')
            else:
                bad.append(f'{rp}: outside tests/, so no regime and no gate '
                           f'runs it (docs/plan.md D8)')
    print(f'  {n:4d}  .php in the project (probes/ and reference/ excluded: both are records)')
    return bad


def _check_uncomment():
    """What `_uncomment` keeps, asserted rather than argued.

    The reviewer of #9 read the quote branch as dropping the characters it
    is inside, which would empty `included` and `benched` and make the two
    obligations that need them unenforceable. It keeps them: the branch
    appends like every other, and the only early path is the escape, which
    appends the PAIR. These are the lines the scan actually meets.
    """
    def one(src):
        return _uncomment(src).strip()

    assert one('require __DIR__ . "/workload.php";  // a comment') == \
        'require __DIR__ . "/workload.php";', one('require x  // c')
    assert one("require 'inc.php';") == "require 'inc.php';"
    assert one('for prog in main.php heavy.php; do') == \
        'for prog in main.php heavy.php; do'
    # a `#` and a `//` INSIDE a quote are content, not a comment
    assert one('x = "a # b"') == 'x = "a # b"'
    assert one("u = 'http://h/p.php'") == "u = 'http://h/p.php'"
    # the escape branch appends the pair and does not end the quote
    assert one('x = "a \\" # b"') == 'x = "a \\" # b"'
    # and a real tail still goes
    assert one('run x.php   # probes/t9/x.php') == 'run x.php'


def main():
    _check_uncomment()
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
            # UNCOMMENTED, like the repo-wide sweep: a `// require
            # "inc.php"` left behind after the real include was deleted
            # would otherwise keep the helper looking covered.
            for m in re.finditer(r"(?:require|include)(?:_once)?[^;]*?['\"]([^'\"]+\.php)",
                                 _uncomment(src)):
                included.add(os.path.basename(m.group(1)))

    # `refusal` is a regime of its own, and not a kind of `fixture`: an
    # `r/` file is NOT a byte-for-byte pair, because the point of it is
    # that mc-php declines it by name. Its obligation is the one
    # `fixtures.sh` enforces -- php PARSES it (`php -l`) and mc-php refuses
    # it with a named message and exit 3 -- and calling it a fixture
    # claimed a differential the gate does not run.
    counts = {'fixture': 0, 'refusal': 0, 'helper': 0, 'instrument': 0,
              'library': 0, 'bench': 0}
    bad = []
    for f in files:
        d = f.split('/')[0]
        if d in globs and os.path.basename(f) in helpers:
            if os.path.basename(f) in included:
                counts['helper'] += 1
            else:
                bad.append(f'{f}: skipped by the gate and required by no fixture')
        elif d in globs and f.count('/') == 1:
            counts['refusal' if d == 'r' else 'fixture'] += 1
        elif f in INSTRUMENTS:
            counts['instrument'] += 1
        elif f in tested and f in benched:
            counts['library'] += 1
        elif f in benched:
            counts['bench'] += 1
        else:
            bad.append(f)

    for k in ('fixture', 'refusal', 'helper', 'instrument', 'library', 'bench'):
        print(f'  {counts[k]:4d}  {k}')
    bad += test_methods_are_all_run()
    bad += project_sweep()
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

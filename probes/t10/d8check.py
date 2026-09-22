#!/usr/bin/env python3
"""D8 over every `.php` this probe wrote -- no file waives the rule for itself.

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

    python3 probes/t10/d8check.py
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


# Directories whose `.php` were written BEFORE D8 was decided (owner,
# 2026-09-15) and are not programs: T4's are one lexical construct each, fed
# to `--dump-tokens` by a glob in its own run.sh, and the gap probes' are the
# six shapes the mc lexer could not own. Each is named with its reason, and
# the sweep below FAILS when one of them is gone -- so the list cannot rot
# into an excuse for a directory nobody looks at any more.
# The pre-D8 exemption is a SNAPSHOT of the files, not a licence for the
# directory: `f.startswith(d + '/')` exempted everything those three
# directories will ever hold, so a new orphan dropped into `probes/t0`
# would have passed the only repository-wide check. These 59 are the ones
# that were there when D8 was written; a file added to one of them is an
# orphan like any other, and a file DELETED from one is reported too, so
# the list cannot quietly rot.
PRE_D8_FILES = frozenset([
    'probes/gap-lexer-ownership/a-single-quote.php',
    'probes/gap-lexer-ownership/b-single-char.php',
    'probes/gap-lexer-ownership/c-hash.php',
    'probes/gap-lexer-ownership/d-attribute.php',
    'probes/gap-lexer-ownership/e-dollar.php',
    'probes/gap-lexer-ownership/f-rawtext.php',
    'probes/t0/classify.php',
    'probes/t4/dollar/a.php',
    'probes/t4/entry/ip.php',
    'probes/t4/entry/ip2.php',
    'probes/t4/entry/plain.php',
    'probes/t4/entry/rw.php',
    'probes/t4/g/01-echo.php',
    'probes/t4/g/02-assign.php',
    'probes/t4/g/03-d4-retype.php',
    'probes/t4/g/04-function.php',
    'probes/t4/g/05-control.php',
    'probes/t4/g/06-interp.php',
    'probes/t4/g/07-class.php',
    'probes/t4/g/08-require.php',
    'probes/t4/g/09-eval.php',
    'probes/t4/g/10-float.php',
    'probes/t4/g/11-numbers.php',
    'probes/t4/g/12-singlequote.php',
    'probes/t4/g/13-hash.php',
    'probes/t4/g/14-inline-html.php',
    'probes/t4/g/inc.php',
    'probes/t4/lex/01-open-tag.php',
    'probes/t4/lex/02-close-tag.php',
    'probes/t4/lex/03-dollar-name.php',
    'probes/t4/lex/04-hash-comment.php',
    'probes/t4/lex/05-slash-comment.php',
    'probes/t4/lex/06-block-comment.php',
    'probes/t4/lex/07-single-quote.php',
    'probes/t4/lex/08-double-quote.php',
    'probes/t4/lex/09-heredoc.php',
    'probes/t4/lex/10-arrow.php',
    'probes/t4/lex/11-nullsafe.php',
    'probes/t4/lex/12-fatarrow.php',
    'probes/t4/lex/13-paamayim.php',
    'probes/t4/lex/14-ellipsis.php',
    'probes/t4/lex/15-pow.php',
    'probes/t4/lex/16-spaceship.php',
    'probes/t4/lex/17-coalesce.php',
    'probes/t4/lex/18-coalesce-assign.php',
    'probes/t4/lex/19-concat-assign.php',
    'probes/t4/lex/20-angle-ne.php',
    'probes/t4/lex/21-attribute.php',
    'probes/t4/lex/22-hex.php',
    'probes/t4/lex/23-binary.php',
    'probes/t4/lex/24-octal.php',
    'probes/t4/lex/25-underscore-int.php',
    'probes/t4/lex/26-float.php',
    'probes/t4/lex/27-namespace-sep.php',
    'probes/t4/lex/28-mc-keywords.php',
    'probes/t4/lex/29-php-keywords.php',
    'probes/t4/lex/30-single-char.php',
    'probes/t4/lex/31-single-escape.php',
    'probes/t4/main.php',
])

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
                # the UNCOMMENTED source: a `/* require __DIR__ . "/x.php" */`
                # in a php block comment was read as a real dependency and
                # would have exempted an untested file.
                for m in REQ.finditer(_uncomment(src)):
                    required.add(os.path.relpath(
                        os.path.join(os.path.dirname(f),
                                     m.group(1) or m.group(2)), REPO))
    text = '\n'.join(srcs.values())
    # RESOLVED paths, not bare basenames: a bench loop names `main.php` and
    # `heavy.php` relative to the directory the loop itself spells, so
    # matching on the basename alone would have called any other probe's
    # `main.php` benched by a bench that never sees it.
    benched = set()
    for path, src in srcs.items():
        for line in re.findall(r'^for prog in (.+?); do', src, re.M):
            for w in line.split():
                if not w.endswith('.php'):
                    continue
                # the directory the same loop reads them from
                for d in re.findall(r'"\$?\{?\w*\}?/?(probes/[\w./-]*?)/\$prog"', src) or \
                         re.findall(r'(probes/[\w./-]+)/\$prog', src):
                    benched.add(os.path.normpath(os.path.join(d, w)))
                if '/' in w:
                    benched.add(os.path.normpath(
                        os.path.join(os.path.dirname(path), w)))

    n = 0
    for f in every_php():
        n += 1
        parts = f.split('/')
        if f in PRE_D8_FILES:
            continue
        # a fixture directory is exempt only when that probe's OWN
        # fixtures.sh walks it, not because it is called g or r
        if len(parts) >= 3 and parts[2] in fixture_globs('/'.join(parts[:2])):
            continue
        if f in required:
            continue
        # every source but this one
        if any(f in t for p, t in srcs.items() if p != f):
            continue
        if f in benched:
            continue
        bad.append(f'{f}: no fixture gate runs it, no .php requires it, '
                   f'no script names it')
    # a name in the snapshot that is no longer on disk: the list is part of
    # the enforcement and a stale entry is a hole in it
    for f in sorted(PRE_D8_FILES):
        if not os.path.isfile(os.path.join(REPO, f)):
            bad.append(f'{f}: in the pre-D8 snapshot and not on disk')
    print(f'  {n:4d}  .php under probes/, swept for orphans '
          f'({len(PRE_D8_FILES)} of them pre-D8)')
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

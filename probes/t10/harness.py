#!/usr/bin/env python3
"""What why.py, diffgroup.py and arena.py all have to do, in one place.

Three findings of `docs/review-backlog.md` section 1 are here rather than in
three copies:

  * a `.why.php` / `.dg.php` / `.ar.php` written beside the `.phpt` CLOBBERS a
    sibling of that name and then deletes it. `sibling()` creates the file with
    O_CREAT|O_EXCL and never removes one it did not create.
  * `(compiled; output differs)` was recorded WITHOUT running the binary, so
    every "output differs" count since T5 really meant "compiled".
  * the grid grades stdout AND the exit code (`probes/t0/phpt-run.py`: green
    needs `output_matches(...) and cand.returncode == oracle.returncode`), so a
    comparison of stdout alone calls a pair that disagrees agreeing.

`run_pair()` is therefore the one definition of "these two agree": stdout byte
for byte and the same exit code, both taken from the SAME source file in the
SAME directory the `.phpt` sits in.
"""
import hashlib, importlib.util, os, re, shlex, signal, subprocess, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
MCPHP = os.environ.get('MCPHP_BIN', os.path.join(HERE, 'mc-php'))
PHP = os.environ.get('PHP', 'php')
SEC = re.compile(r'^--FILE--\r?\n(.*?)(?=^--[A-Z_]+--)', re.S | re.M)

# The grid's OWN section parser and ini list, imported rather than copied.
# A .phpt may carry --ARGS--, --STDIN--, --ENV-- and --INI--, and
# probes/t0/phpt-run.py passes every one of them to both sides; a tool that
# explains the grid's verdict and does not would be measuring a DIFFERENT
# program and publishing a classification for it.
_spec = importlib.util.spec_from_file_location(
    'phptrun', os.path.join(HERE, '..', 't0', 'phpt-run.py'))
_grid = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_grid)

# DEFAULT_INI is a list of bare `name=value` strings with ONE placeholder,
# and the grid turns it into `-d name=value` pairs and substitutes `{E_ALL}`
# from the running php inside main() -- which an import does not execute. So
# both steps are done here, once, exactly as `main()` and `run_php` do them:
# without the substitution php is handed a literal `error_reporting={E_ALL}`
# (it parses as 0, and every diagnostic test then disagrees for the wrong
# reason), and without the `-d` php reads `output_handler=` as the name of a
# script to run.
_SRCDIR = os.path.abspath(os.environ.get('PHP_SRCDIR',
                                          os.path.join(HERE, '..', '..', 'php-src')))
_EALL = _grid.e_all(PHP)
INI = []
for _kv in _grid.DEFAULT_INI:
    INI += ['-d', _kv.format(E_ALL=_EALL)]


class Busy(Exception):
    """A sibling of that name already exists and is not ours to overwrite."""


OWNER = '.mcphp-owner'


def _owner_path(path):
    """Where the marker lives, and it is NOT beside the test.

    The grid creates exactly one file next to a `.phpt` -- the `.php` it
    compiles -- so a marker there is a file the program can see: a .phpt
    that globs its own directory, counts entries or opens `*` would be
    classified on the harness. It goes in MCPHP_TMP (the bounded directory,
    swept with everything else) or the system temporary directory, named by
    a digest of the absolute path so two workers cannot collide.
    """
    d = os.environ.get('MCPHP_TMP')
    if not d or not os.path.isdir(d):
        d = tempfile.gettempdir()
    h = hashlib.sha256(os.path.abspath(path).encode()).hexdigest()[:24]
    return os.path.join(d, 'mcphp-owner.' + h)


def _me():
    """This process, identified well enough to tell a recycled pid apart."""
    try:
        st = subprocess.run(['ps', '-o', 'lstart=', '-p', str(os.getpid())],
                            capture_output=True).stdout.decode().strip()
    except OSError:
        st = ''
    return f'{os.getpid()}\n{st}\n'


def _stale_scratch(path):
    """Is `path` a scratch file this tool made and then lost?

    A `.php` php-src ships beside a test has no owner marker and is never
    touched. One with a marker whose process is gone -- or whose pid has
    been recycled, which the start time catches -- is a run that was killed
    between the create and its `finally`, and leaving it makes every later
    run call that test `busy` and quietly shrink the sample.
    """
    try:
        with open(_owner_path(path)) as f:
            pid, _, st = f.read().partition('\n')
    except OSError:
        return False
    try:
        os.kill(int(pid), 0)
    except (ValueError, ProcessLookupError):
        return True
    except PermissionError:
        return False
    try:
        now = subprocess.run(['ps', '-o', 'lstart=', '-p', pid],
                             capture_output=True).stdout.decode().strip()
    except OSError:
        return False
    return bool(now) and now != st.strip()


def sibling(phpt, tag):
    """Create `<base>.php` next to the .phpt, exclusively, or raise Busy.

    The file has to be beside the .phpt: `__DIR__`, a relative `require` and
    a sibling data file all resolve from there. And it has to carry the
    CANONICAL name, the one probes/t0/phpt-run.py gives the test, because a
    program that reads `__FILE__`, `basename(__FILE__)` or a path derived
    from it is otherwise not the program the grid graded.

    So there is NO fallback name. `O_CREAT|O_EXCL` means a `.php` php-src
    already ships beside a test is never clobbered, and when the name is
    taken the test is SKIPPED and counted (`busy`) rather than measured
    under a different filename. Over T10's 1352-test sample that happened
    **0 times**, so the fallback the first version had was buying nothing
    and hiding something.
    """
    base = phpt[:-5] if phpt.endswith('.phpt') else phpt
    path = f'{base}.php'
    # An OWNER marker beside it, so a run killed between the create and the
    # `finally` does not make every later run call that test `busy` and
    # quietly shrink the sample. The marker holds this process's pid and
    # start time (`probes/t10/tmp.sh` uses the same pair for the same
    # reason); a scratch file whose owner is gone is taken over, and a
    # `.php` php-src really ships has no marker and is never touched.
    fd = None
    for attempt in (0, 1):
        try:
            fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o644)
            break
        except FileExistsError:
            if attempt or not _stale_scratch(path):
                raise Busy(path)
            for q in (path, _owner_path(path)):
                try:
                    os.unlink(q)
                except OSError:
                    pass
    if fd is None:
        raise Busy(path)
    os.close(fd)
    try:
        with open(_owner_path(path), 'w') as f:
            f.write(_me())
    except OSError:
        pass
    return path


def tmpbin(prefix='mcphp.'):
    """A path for the binary -- reserved by the kernel, so no TOCTOU.

    Inside MCPHP_TMP when the caller made one: that directory is what
    run.sh's watcher samples, what its peak is measured over and what the
    next run's sweep collects, so a binary anywhere else is space this
    probe claims to bound and does not. Without it, the system default,
    which is what a bare `python3 why.py` gets.
    """
    d = os.environ.get('MCPHP_TMP') or None
    if d and not os.path.isdir(d):
        d = None
    fd, path = tempfile.mkstemp(prefix=prefix, suffix='.bin', dir=d)
    os.close(fd)
    os.unlink(path)
    return path


def unlink(*paths):
    for p in paths:
        if not p:
            continue
        try:
            os.unlink(p)
        except OSError:
            pass


def file_section(phpt):
    """The --FILE-- section, or None."""
    try:
        src = open(phpt, 'rb').read().decode('latin-1')
    except OSError:
        return None
    m = SEC.search(src)
    return m.group(1) if m else None


def sections(phpt):
    """Every section, through the GRID's own parser (resolved --*_EXTERNAL--)."""
    sec, err = _grid.parse_phpt(phpt)
    if err:
        return None
    if _grid.resolve_sections(sec, os.path.dirname(os.path.abspath(phpt))):
        return None
    return sec


def _extras(sec, testdir):
    """(argv, stdin, env-additions, extra ini) exactly as the grid builds them."""
    args = shlex.split(sec.get('ARGS', '').strip()) if sec.get('ARGS', '').strip() else []
    stdin = sec['STDIN'].encode('latin-1') if 'STDIN' in sec else b''
    # the GRID's base environment, not a bare os.environ: a .phpt that spawns
    # a nested php through TEST_PHP_EXECUTABLE runs a different program
    # without it (probes/t0/phpt-run.py's own note), and this tool exists to
    # reproduce that grid's verdict.
    env = _grid.base_environment(PHP, _SRCDIR)
    env['REDIRECT_STATUS'] = '1'
    for line in sec.get('ENV', '').splitlines():
        line = line.strip()
        if line and '=' in line:
            k, v = line.split('=', 1)
            env[k.strip()] = v.strip()
    ini = []
    for line in sec.get('INI', '').splitlines():
        line = line.replace('{PWD}', testdir)
        if '=' not in line:
            continue
        name, value = line.split('=', 1)
        name, value = name.strip(), value.strip()
        if name:
            ini += ['-d', f'{name}={value}']
    return args, stdin, env, ini


def _run(cmd, *, input=b'', stdout=subprocess.PIPE, stderr=subprocess.PIPE,
         env=None, cwd=None, timeout=None):
    """`subprocess.run`, except that a timeout kills the process GROUP.

    A .phpt may spawn a nested php (`TEST_PHP_EXECUTABLE`, which
    `base_environment` sets for exactly that reason) and the compiler is a
    child too, so killing the one process this started left descendants
    holding pipes and writing into the shared test directory while later
    workers ran. `probes/t0/phpt-run.py` does the same thing for the same
    reason; the measurement is in docs/review-backlog.md round twenty-two.
    """
    # stdout AND stderr are PIPEs by default and both come back in the
    # CompletedProcess: `run_pair` reads `c.stderr` for a compile failure
    # and `g.stderr` for every run, and only the CLEAN call asks for
    # DEVNULL.
    p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=stdout,
                         stderr=stderr, env=env, cwd=cwd,
                         start_new_session=True)
    try:
        out, err = p.communicate(input=input, timeout=timeout)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(os.getpgid(p.pid), signal.SIGKILL)
        except OSError:
            p.kill()
        p.communicate()
        raise
    return subprocess.CompletedProcess(cmd, p.returncode, out, err)


def agrees(sec, out, want, rc, wrc):
    """The grid's OWN verdict, and it is not a comparison with php's bytes.

    `probes/t0/phpt-run.py` greens a candidate whose output satisfies the
    TEST'S OWN expectation -- `output_matches`, which is `--EXPECT--` after
    `normalize` but a PATTERN for `--EXPECTF--` and `--EXPECTREGEX--` -- and
    whose exit code equals the oracle's. Two versions of this compared the
    raw bytes and then the normalized bytes of the two RUNS, so a candidate
    whose output the pattern accepts, and which the grid therefore calls
    green, came out here as a disagreement with the wrong reason attached.
    With no expectation section at all there is nothing to match against and
    php's own output is the only answer available, which is the fallback.
    """
    if rc != wrc:
        return False
    if sec and ('EXPECT' in sec or 'EXPECTF' in sec or 'EXPECTREGEX' in sec):
        return _grid.output_matches(sec, _grid.normalize(out))
    return _grid.normalize(out) == _grid.normalize(want)


def jobs():
    """The probe's bounded worker count, the one `run.sh` sets.

    The analysis tools each start a compiler AND a php AND a binary per
    worker, so `os.cpu_count()` fans out past the limit the grid honours and
    spends the temporary space this probe measures. T10_JOBS is the bound.
    """
    try:
        n = int(os.environ.get('T10_JOBS', '') or 0)
    except ValueError:
        n = 0
    return n if n > 0 else (os.cpu_count() or 8)


def run_pair(phpt, tag, budget=None):
    """Compile the test's --FILE-- and run it, beside php, on the same input.

    Returns a dict with `status` and, when it ran, the two streams and the two
    exit codes. `status` is one of:

        no-file      the .phpt has no --FILE-- section (or is unreadable)
        busy         `<base>.php` is taken; nothing was written and nothing
                     measured, because the canonical name is what the grid uses
        no-compile   mc-php refused or failed; `cerr` carries its stderr
        compile-timeout / run-timeout / error
        ran          both ran: `out`/`rc` (mc-php) and `want`/`wrc` (php)

    `agrees` is true only when stdout AND the exit code match, which is what
    the grid grades on.
    """
    # ABSOLUTE first, and it is not a tidiness: `sibling()` derives the
    # scratch `.php` from this path, and the two processes below run with
    # `cwd` set to the TEST's directory. A relative `phpt` (which is what
    # `find php-src/... | ...` writes into every wrong.txt, and so what every
    # caller hands over) therefore named a file that did not exist from
    # there, and php answered `Could not open input file` -- exit 1, empty
    # stdout -- for EVERY test. The candidate ran anyway, because its binary
    # is an absolute mkstemp path. See probes/t10/RESULTS.md: it is what the
    # `143 tests print exactly what php prints and exit 0 where php exits 1`
    # headline really was, and phpt-run.py's own `classify` starts with this
    # line for the same reason.
    phpt = os.path.abspath(phpt)
    # ONE budget for the candidate's compile AND run, and the same for php:
    # probes/t0/phpt-run.py gives the candidate `--timeout` for both together
    # (15 s by default), so a separate 40 + 20 here reported a completed
    # difference for a test the grid had already called a timeout -- and the
    # table then explained a verdict the grid never gave.
    if budget is None:
        budget = _grid.DEFAULT_TIMEOUT
    sec = sections(phpt)
    src = sec.get('FILE') if sec else file_section(phpt)
    if src is None:
        return {'status': 'no-file'}
    try:
        php = sibling(phpt, tag)
    except Busy:
        return {'status': 'busy'}
    # binf is allocated INSIDE the protected block: `tmpbin` can raise (a
    # full temporary filesystem), and doing it before the `try` left the
    # canonical sibling behind, so every later worker called that test
    # `busy` and dropped it from the sample -- the failure round
    # twenty-six's owner marker exists to recover from, reached by a
    # different road.
    binf = None
    cwd = os.path.dirname(os.path.abspath(php)) or '.'
    # The scratch file lives beside the .phpt (cwd) and `{PWD}` in an --INI--
    # expands to that directory, but the two PROCESSES run from the source
    # root, which is where probes/t0/phpt-run.py runs them (`cwd=srcdir`).
    # getcwd(), a relative fopen and a relative require all see a different
    # directory otherwise, so the classification would describe a different
    # program than the grid graded.
    argv, stdin, env, ini = _extras(sec or {}, cwd)
    run_cwd = _SRCDIR
    try:
        binf = tmpbin(prefix=tag + '.')
        open(php, 'w', encoding='latin-1', newline='').write(src)
        # The grid's order, in full: php runs FIRST, and the candidate is
        # COMPILED after it (probes/t0/phpt-run.py runs the oracle, then
        # invokes mcphp.sh, which compiles and runs). Two reasons, and the
        # first version of this had neither. A .phpt may write, delete or
        # rename a file beside itself, so whichever side runs second sees
        # what the first left -- and running the candidate first made the
        # ORACLE the contaminated one. And a .phpt that rewrites its own
        # scratch source or an included sibling while the oracle runs would
        # otherwise be COMPILED from different bytes than the grid compiled.
        e = _run([PHP] + INI + ini + ['-q', php] + argv, input=stdin or b'',
                 env=env, cwd=run_cwd, timeout=budget)
        # --CLEAN-- between the two, exactly where the grid runs it
        # (probes/t0/phpt-run.py, right after the oracle): a test that
        # creates a file and removes it there left the file behind for the
        # candidate AND for whatever ran next in the same directory, so the
        # classification could describe a state the grid never had.
        clean = (sec or {}).get('CLEAN', '')
        if clean.strip():
            cf = php[:-4] + '.clean.php'
            try:
                open(cf, 'w', encoding='latin-1', newline='').write(clean)
                # input=b'' as the grid passes: a CLEAN that reads stdin
                # would otherwise inherit the analysis process's and block
                # or eat something else's input.
                _run([PHP] + INI + ['-q', cf], input=b'',
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                     env=env, cwd=run_cwd, timeout=budget)
            except (OSError, subprocess.SubprocessError):
                pass
            finally:
                unlink(cf)
        # ONE deadline for the candidate, compile plus run. Each used to get
        # the full budget, so a compile that took nearly all of it left the
        # binary another whole one -- up to 2x the grid's timeout, reported
        # as `run-timeout` where the grid would have called it a compile.
        t0 = time.monotonic()
        cbud = max(0.001, budget - (time.monotonic() - t0))
        # the SAME environment and working directory the grid compiles in:
        # mcphp.sh is spawned by probes/t0/phpt-run.py with the test env and
        # cwd=srcdir, so a source whose include resolution depends on either
        # was being compiled under a different harness than the one graded.
        c = _run([MCPHP, '--exe', php, '-o', binf], env=env, cwd=run_cwd,
                 timeout=cbud)
        left = budget - (time.monotonic() - t0)
        # 255 is a php COMPILE-TIME fatal and not a failure to compile: php
        # reports those while parsing and exits 255, so mcphp.sh prints both
        # of the compiler's streams and passes the code through, and the
        # grid COMPARES it. Collapsing it into `no-compile` here counted a
        # test the grid graded on its output as one that never ran -- and
        # section 1 of the backlog is exactly about the two not agreeing.
        # There is no binary, so this is the whole run.
        if c.returncode == 255:
            cout = c.stdout.decode('latin-1')
            cwant = e.stdout.decode('latin-1')
            # `ran` because the GRID grades this pair on its output, and
            # `compile_fatal` because no binary was executed: arena.py's
            # denominator is "tests that RAN" and counted these, and it
            # then searched the COMPILER's stderr for `arena exhausted`,
            # which is a different arena from the one D7 is about.
            return {'status': 'ran', 'out': cout, 'rc': 255, 'sec': sec,
                    'compile_fatal': 1,
                    'err': c.stderr.decode('latin-1', 'replace'),
                    'want': cwant, 'wrc': e.returncode,
                    'agrees': agrees(sec, cout, cwant, 255, e.returncode)}
        if c.returncode != 0:
            return {'status': 'no-compile', 'crc': c.returncode,
                    'cerr': c.stderr.decode('latin-1', 'replace'),
                    'cout': c.stdout.decode('latin-1', 'replace')}
        if left <= 0:
            # the COMPILER's command: the budget was spent compiling, and
            # naming the binary here classified it as a run that timed out
            # when no binary had been started.
            raise subprocess.TimeoutExpired([MCPHP], budget)
        g = _run([binf] + argv, input=stdin or b'', env=env, cwd=run_cwd,
                 timeout=left)
    except subprocess.TimeoutExpired as t:
        # WHICH process ran out of time. The test used to be "was it the
        # compiler, else the binary", so an ORACLE that timed out -- the
        # grid's own `php-fail` bucket -- was reported as the candidate
        # binary timing out, and why.py then labelled it `(compiled; timed
        # out)` for a test that had never been compiled at all.
        cmd0 = t.cmd[0] if t.cmd else ''
        if cmd0 == PHP:
            st = 'php-timeout'
        elif cmd0 == MCPHP:
            st = 'compile-timeout'
        else:
            st = 'run-timeout'
        return {'status': st}
    except OSError as ex:
        return {'status': 'error', 'error': f'{ex.__class__.__name__}: {ex}'}
    finally:
        unlink(php, _owner_path(php), binf)
    out = g.stdout.decode('latin-1')
    want = e.stdout.decode('latin-1')
    return {'status': 'ran', 'out': out, 'rc': g.returncode, 'sec': sec,
            'err': g.stderr.decode('latin-1', 'replace'),
            'want': want, 'wrc': e.returncode,
            'agrees': agrees(sec, out, want, g.returncode, e.returncode)}

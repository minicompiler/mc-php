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
import importlib.util, os, re, shlex, subprocess, tempfile

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
INI = _grid.DEFAULT_INI


class Busy(Exception):
    """A sibling of that name already exists and is not ours to overwrite."""


def sibling(phpt, tag):
    """Create `<test>.<tag>.php` next to the .phpt, exclusively.

    The file has to be beside the .phpt: `__DIR__`, a relative `require` and a
    sibling data file all resolve from there. It must NOT clobber one that is
    already there -- php-src ships `.php` files next to its tests. A name that
    is taken is tried again with a counter, and after 64 tries the test is
    skipped rather than a stranger's file destroyed.
    """
    base = phpt[:-5] if phpt.endswith('.phpt') else phpt
    for n in range(64):
        path = f'{base}.{tag}.php' if n == 0 else f'{base}.{tag}{n}.php'
        try:
            fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o644)
        except FileExistsError:
            continue
        os.close(fd)
        return path
    raise Busy(base)


def tmpbin(prefix='mcphp.'):
    """A path for the binary -- reserved by the kernel, so no TOCTOU."""
    fd, path = tempfile.mkstemp(prefix=prefix, suffix='.bin')
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
    env = dict(os.environ)
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


def run_pair(phpt, tag, compile_timeout=40, run_timeout=20):
    """Compile the test's --FILE-- and run it, beside php, on the same input.

    Returns a dict with `status` and, when it ran, the two streams and the two
    exit codes. `status` is one of:

        no-file      the .phpt has no --FILE-- section (or is unreadable)
        busy         a sibling of that name exists; nothing was written
        no-compile   mc-php refused or failed; `cerr` carries its stderr
        compile-timeout / run-timeout / error
        ran          both ran: `out`/`rc` (mc-php) and `want`/`wrc` (php)

    `agrees` is true only when stdout AND the exit code match, which is what
    the grid grades on.
    """
    sec = sections(phpt)
    src = sec.get('FILE') if sec else file_section(phpt)
    if src is None:
        return {'status': 'no-file'}
    try:
        php = sibling(phpt, tag)
    except Busy:
        return {'status': 'busy'}
    binf = tmpbin(prefix=tag + '.')
    cwd = os.path.dirname(os.path.abspath(php)) or '.'
    argv, stdin, env, ini = _extras(sec or {}, cwd)
    try:
        open(php, 'w', encoding='latin-1', newline='').write(src)
        c = subprocess.run([MCPHP, '--exe', php, '-o', binf], stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE, timeout=compile_timeout)
        if c.returncode != 0:
            return {'status': 'no-compile', 'crc': c.returncode,
                    'cerr': c.stderr.decode('latin-1', 'replace'),
                    'cout': c.stdout.decode('latin-1', 'replace')}
        # php FIRST, then the candidate -- the order probes/t0/phpt-run.py
        # runs them in. A .phpt may write, delete or rename a file beside
        # itself, and whichever side runs second sees what the first left;
        # running the candidate first meant the ORACLE was the contaminated
        # one, which is the reverse of what a differential measurement can
        # tolerate.
        e = subprocess.run([PHP] + INI + ini + ['-q', php] + argv, input=stdin,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           env=env, cwd=cwd, timeout=run_timeout)
        g = subprocess.run([binf] + argv, input=stdin,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           env=env, cwd=cwd, timeout=run_timeout)
    except subprocess.TimeoutExpired as t:
        return {'status': 'compile-timeout' if t.cmd and t.cmd[0] == MCPHP else 'run-timeout'}
    except OSError as ex:
        return {'status': 'error', 'error': f'{ex.__class__.__name__}: {ex}'}
    finally:
        unlink(php, binf)
    out = g.stdout.decode('latin-1')
    want = e.stdout.decode('latin-1')
    return {'status': 'ran', 'out': out, 'rc': g.returncode,
            'err': g.stderr.decode('latin-1', 'replace'),
            'want': want, 'wrc': e.returncode,
            'agrees': out == want and g.returncode == e.returncode}

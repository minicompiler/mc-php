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
import os, re, subprocess, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
MCPHP = os.environ.get('MCPHP_BIN', os.path.join(HERE, 'mc-php'))
PHP = os.environ.get('PHP', 'php')
SEC = re.compile(r'^--FILE--\r?\n(.*?)(?=^--[A-Z_]+--)', re.S | re.M)

# what probes/t0/phpt-run.py hands php, so a comparison here is the grid's
INI = ['-d', 'error_reporting=30719', '-d', 'display_errors=1', '-d', 'log_errors=0',
       '-d', 'html_errors=0', '-d', 'precision=14', '-d', 'serialize_precision=-1',
       '-d', 'date.timezone=UTC', '-d', 'output_buffering=Off', '-d', 'docref_root=']


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
    src = file_section(phpt)
    if src is None:
        return {'status': 'no-file'}
    try:
        php = sibling(phpt, tag)
    except Busy:
        return {'status': 'busy'}
    binf = tmpbin(prefix=tag + '.')
    cwd = os.path.dirname(os.path.abspath(php)) or '.'
    try:
        open(php, 'w', encoding='latin-1', newline='').write(src)
        c = subprocess.run([MCPHP, '--exe', php, '-o', binf], stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE, timeout=compile_timeout)
        if c.returncode != 0:
            return {'status': 'no-compile', 'crc': c.returncode,
                    'cerr': c.stderr.decode('latin-1', 'replace'),
                    'cout': c.stdout.decode('latin-1', 'replace')}
        g = subprocess.run([binf], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           cwd=cwd, timeout=run_timeout)
        e = subprocess.run([PHP] + INI + ['-q', php], stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE, cwd=cwd, timeout=run_timeout)
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

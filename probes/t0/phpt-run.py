#!/usr/bin/env python3
"""T0 -- run a list of .phpt files under two executors and compare.

Executor A is `php` itself: the oracle. Executor B is whatever turns a .php
file into a result -- today `probes/t0/mcphp-stub.sh`, later the mc-php
binary. Both are driven with the same small protocol:

    <executor> FILE.php [ARGS...]

stdin carries the test's --STDIN-- section (or nothing); the environment
carries --ENV-- merged over this process's own. `php` additionally gets a
faithful set of `-d` INI overwrites (php-src's own run-tests.php defaults,
plus the test's own --INI-- section) and `-q`, because it is being asked to
behave exactly as php-src's own runner asks it to; B gets none of that --
the INI knobs are an artifact of running a real php.ini-reading interpreter,
not something a compiled binary has a use for, and this is a placeholder
protocol until mc-php exists to say otherwise.

--SKIPIF--, --EXTENSIONS--, --INI--, --ARGS--, --STDIN--, --ENV-- and
--CLEAN-- are honoured; --XFAIL-- is read but not retried on (a test whose
own --XFAIL-- lets it disagree with itself is not this probe's business).
SKIPIF always runs under `php`, per the task: the environment being probed
belongs to the oracle, not to the candidate.

The oracle is checked against ITS OWN --EXPECT--/--EXPECTF--/--EXPECTREGEX--
before the candidate is even asked: a .phpt that php itself cannot pass
(missing extension not caught by --EXTENSIONS--, a php-version drift, a
malformed test) is counted `php-fail` and excluded from the denominator --
it says nothing about the candidate.

For every OTHER test:
  green     -- both executors' output satisfies the test's own expectation
  wrong     -- B ran, disagreed with the expectation (or the oracle disagreed
               with B, if you prefer: it means what run-tests.php calls FAIL)
  refused   -- B exited with --refuse-code (default 3): a named compile
               refusal, counted apart from an ordinary wrong answer
  skip      -- --SKIPIF-- said so, or --EXTENSIONS-- names something `php`
               does not have loaded

Prints one line per test (unless --quiet) and a final summary line:

    phpt: green G / wrong W / refused R / skip S / php-fail F / total N

N = green + wrong + refused + skip (php-fail is excluded, per spec).
Exits 0 whenever it ran to completion (a red grid is still a measurement).

Usage:
    sh probes/t0/phpt-run.py [options] [FILE.phpt ...]
    find php-src -name '*.phpt' | sh probes/t0/phpt-run.py [options]

A scratch <name>.php (and, transiently, <name>.skip.php / <name>.clean.php)
is written NEXT TO each source .phpt, exactly where php-src's own runner
writes it -- so __DIR__/dirname(__FILE__) and sibling includes resolve --
and removed afterward. php-src/ is entirely gitignored, so this never
touches anything committed.
"""
import argparse
import os
import random
import re
import shlex
import shutil
import subprocess
import sys
import time
from types import SimpleNamespace

# -- php-src's own run-tests.php default INI overwrites (verbatim, the list
#    it builds before spawning any test; see php-src/run-tests.php around the
#    definition of $ini_overwrites). date.timezone=UTC and precision=14 are
#    what make float/date output reproducible across hosts.
DEFAULT_INI = [
    'output_handler=',
    'open_basedir=',
    'disable_functions=',
    'output_buffering=Off',
    'error_reporting={E_ALL}',
    'fatal_error_backtraces=Off',
    'display_errors=1',
    'display_startup_errors=1',
    'log_errors=0',
    'html_errors=0',
    'track_errors=0',
    'report_zend_debug=0',
    'docref_root=',
    'docref_ext=.html',
    'error_prepend_string=',
    'error_append_string=',
    'auto_prepend_file=',
    'auto_append_file=',
    'ignore_repeated_errors=0',
    'precision=14',
    'serialize_precision=-1',
    'memory_limit=128M',
    'opcache.fast_shutdown=0',
    'opcache.file_update_protection=0',
    'opcache.revalidate_freq=0',
    'opcache.protect_memory=1',
    'opcache.file_cache=',
    'opcache.file_cache_only=0',
    'zend.assertions=1',
    'zend.exception_ignore_args=0',
    'zend.exception_string_param_max_len=15',
    'short_open_tag=0',
    'date.timezone=UTC',
]

PHP_TRIM_CHARS = " \t\n\r\0\x0b"
SECTION_RE = re.compile(r'^--([_A-Z]+)--')

STRTR_MAP = {
    '%e': re.escape(os.sep),
    '%s': r'[^\r\n]+',
    '%S': r'[^\r\n]*',
    '%a': r'.+?',
    '%A': r'.*?',
    '%w': r'\s*',
    '%i': r'[+-]?\d+',
    '%d': r'\d+',
    '%x': r'[0-9a-fA-F]+',
    '%f': r'[+-]?(?:\d+|(?=\.\d))(?:\.\d+)?(?:[Ee][+-]?\d+)?',
    '%c': r'.',
    '%0': r'\x00',
}


def php_trim(s):
    return s.strip(PHP_TRIM_CHARS)


def normalize(raw):
    # php: preg_replace('/\r\n/', "\n", trim($out)) -- trim first, then CRLF.
    return php_trim(raw).replace('\r\n', '\n')


def r_sections_transform(s):
    # preg_quote every part of s except %r...%r spans, which are inserted
    # verbatim as capture groups (php's own expectf_to_regex, port of the
    # %r-scanning loop in run-tests.php).
    out = []
    length = len(s)
    start_offset = 0
    while start_offset < length:
        start = s.find('%r', start_offset)
        if start != -1:
            end = s.find('%r', start + 2)
            if end == -1:
                end = start = length
        else:
            start = end = length
        out.append(re.escape(s[start_offset:start]))
        if end > start:
            out.append('(' + s[start + 2:end] + ')')
        start_offset = end + 2
    return ''.join(out)


def strtr_tokens(s):
    out = []
    i, n = 0, len(s)
    while i < n:
        tok = s[i:i + 2]
        rep = STRTR_MAP.get(tok)
        if rep is not None:
            out.append(rep)
            i += 2
        else:
            out.append(s[i])
            i += 1
    return ''.join(out)


def expectf_to_regex(wanted):
    wanted = wanted.replace('\r\n', '\n')
    return strtr_tokens(r_sections_transform(wanted))


def output_matches(sections, output):
    if 'EXPECTF' in sections:
        pattern = expectf_to_regex(normalize(sections['EXPECTF']))
    elif 'EXPECTREGEX' in sections:
        pattern = normalize(sections['EXPECTREGEX'])
    else:
        return output == normalize(sections.get('EXPECT', ''))
    try:
        return re.match('^' + pattern + '$', output, re.DOTALL) is not None
    except re.error:
        return False


def parse_phpt(path):
    with open(path, 'rb') as f:
        raw = f.read()
    text = raw.decode('latin-1')
    lines = text.splitlines(keepends=True)
    if not lines or not lines[0].startswith('--TEST--'):
        return None, 'missing --TEST-- as the first line'
    sections = {'TEST': ''}
    cur = 'TEST'
    for line in lines[1:]:
        m = SECTION_RE.match(line)
        if m:
            cur = m.group(1)
            sections.setdefault(cur, '')
            continue
        sections[cur] += line
    return sections, None


def resolve_sections(sections, testdir):
    if 'FILEEOF' in sections and 'FILE' not in sections:
        sections['FILE'] = re.sub(r'[\r\n]+$', '', sections.pop('FILEEOF'))
    for prefix in ('FILE', 'EXPECT', 'EXPECTF', 'EXPECTREGEX'):
        key = prefix + '_EXTERNAL'
        if key in sections and prefix not in sections:
            name = sections[key].strip().replace('..', '')
            ext_path = os.path.join(testdir, name)
            try:
                with open(ext_path, 'rb') as f:
                    sections[prefix] = f.read().decode('latin-1')
            except OSError:
                return f'cannot read {key} target: {name}'
    return None


def _run(cmd, stdin, env, timeout, cwd):
    try:
        p = subprocess.run(
            cmd,
            input=(stdin.encode('latin-1') if stdin is not None else b''),
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            env=env, cwd=cwd, timeout=timeout,
        )
        return SimpleNamespace(returncode=p.returncode,
                                stdout=p.stdout.decode('latin-1'),
                                timed_out=False)
    except subprocess.TimeoutExpired:
        return SimpleNamespace(returncode=-1, stdout='', timed_out=True)
    except OSError as e:
        return SimpleNamespace(returncode=-2, stdout=f'<exec error: {e}>',
                                timed_out=False)


def run_php(php_exe, php_file, ini, args, stdin, env, timeout, cwd):
    cmd = [php_exe]
    for kv in ini:
        cmd += ['-d', kv]
    cmd += ['-q', php_file]
    if args:
        # NOT '-- ' + args: php-src's own runner uses `-f FILE -- ARGS`, but
        # this invokes php with FILE positional (no -f) -- option parsing
        # already ends at the first non-option argument, so a literal '--'
        # here would land in $argv[1] instead of separating anything.
        cmd += shlex.split(args)
    return _run(cmd, stdin, env, timeout, cwd)


def run_candidate(candidate, php_file, args, stdin, env, timeout, cwd):
    cmd = shlex.split(candidate) + [php_file]
    if args:
        cmd += shlex.split(args)
    return _run(cmd, stdin, env, timeout, cwd)


def e_all(php_exe):
    # php-src's own $ini_overwrites builds this entry as 'error_reporting=' .
    # E_ALL, evaluated by the php running run-tests.php -- not the literal
    # 32767 an older PHP would give (this host's PHP 8.5.10: 30719).
    p = subprocess.run([php_exe, '-r', 'echo E_ALL;'],
                        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    try:
        return int(p.stdout.decode('latin-1').strip())
    except ValueError:
        return 32767


def load_extensions(php_exe):
    p = subprocess.run([php_exe, '-d', 'display_errors=0', '-m'],
                        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    names = set()
    for line in p.stdout.decode('latin-1', 'replace').splitlines():
        line = line.strip()
        if not line or line.startswith('['):
            continue
        names.add(line.lower())
    return names


def classify(path, php_exe, candidate, refuse_code, exts_loaded,
             timeout, srcdir, base_env):
    # absolute, independent of the cwd every spawned process runs with
    # (php-src's own runner's: TEST_PHP_SRCDIR)
    path = os.path.abspath(path)
    sections, err = parse_phpt(path)
    if err:
        return ('php-fail', f'phpt parse: {err}')
    if 'REDIRECTTEST' in sections:
        return ('php-fail', 'REDIRECTTEST: not a standalone test')

    testdir = os.path.dirname(path)
    err = resolve_sections(sections, testdir)
    if err:
        return ('php-fail', err)

    nfile = 'FILE' in sections
    nexpect = sum(k in sections for k in ('EXPECT', 'EXPECTF', 'EXPECTREGEX'))
    if not nfile or nexpect != 1:
        return ('php-fail', 'missing --FILE-- or --EXPECT*--')

    if 'EXTENSIONS' in sections:
        needed = [e.strip().lower() for e in
                  re.split(r'[\s,]+', sections['EXTENSIONS'].strip()) if e.strip()]
        missing = [e for e in needed if e not in exts_loaded]
        if missing:
            return ('skip', f'extension missing: {" ".join(missing)}')

    base = path[:-len('.phpt')] if path.endswith('.phpt') else path
    php_file = base + '.php'
    skip_file = base + '.skip.php'
    clean_file = base + '.clean.php'

    env = dict(base_env)
    env['REDIRECT_STATUS'] = '1'
    if 'ENV' in sections:
        for line in sections['ENV'].splitlines():
            line = line.strip()
            if line and '=' in line:
                k, v = line.split('=', 1)
                env[k.strip()] = v.strip()

    def cleanup(*paths):
        for p in paths:
            try:
                os.unlink(p)
            except OSError:
                pass

    try:
        if sections.get('SKIPIF', '').strip():
            with open(skip_file, 'w', encoding='latin-1') as f:
                f.write(sections['SKIPIF'])
            try:
                r = run_php(php_exe, skip_file, DEFAULT_INI, '', None, env,
                            timeout, srcdir)
            finally:
                cleanup(skip_file)
            so = r.stdout.strip()
            head4, head5 = so[:4].lower(), so[:5].lower()
            if head4 == 'skip':
                return ('skip', so[:120] or 'SKIPIF')
            if head4 not in ('info', 'warn') and head5 not in ('xfail', 'xleak', 'flaky') and so:
                return ('php-fail', f'SKIPIF produced unexpected output: {so[:120]!r}')

        with open(php_file, 'w', encoding='latin-1') as f:
            f.write(sections['FILE'])

        ini_extra = []
        if 'INI' in sections:
            # php-src's own settings2array: split on the FIRST '=', trim each
            # side separately -- "foo  = bar" is name "foo" value "bar", not
            # value " bar" (a leading space in the value is real and some
            # tests, e.g. Zend/tests/heredoc_nowdoc/nowdoc_013.phpt, would
            # silently disagree with their own --EXPECT-- if it leaked in).
            for line in sections['INI'].splitlines():
                line = line.replace('{PWD}', testdir)
                if '=' not in line:
                    continue
                name, value = line.split('=', 1)
                name, value = name.strip(), value.strip()
                if name:
                    ini_extra.append(f'{name}={value}')
        args = sections.get('ARGS', '').strip()
        stdin = sections['STDIN'] if 'STDIN' in sections else None

        oracle = run_php(php_exe, php_file, DEFAULT_INI + ini_extra, args,
                          stdin, env, timeout, srcdir)
        if oracle.timed_out:
            return ('php-fail', 'oracle timed out')
        oracle_out = normalize(oracle.stdout)
        oracle_ok = output_matches(sections, oracle_out)

        if sections.get('CLEAN', '').strip():
            with open(clean_file, 'w', encoding='latin-1') as f:
                f.write(sections['CLEAN'])
            try:
                run_php(php_exe, clean_file, DEFAULT_INI, '', None, env,
                        timeout, srcdir)
            finally:
                cleanup(clean_file)

        if not oracle_ok:
            kind = 'EXPECTF' if 'EXPECTF' in sections else (
                'EXPECTREGEX' if 'EXPECTREGEX' in sections else 'EXPECT')
            return ('php-fail', f'php disagrees with its own --{kind}--')

        cand = run_candidate(candidate, php_file, args, stdin, env,
                              timeout, srcdir)
        if cand.timed_out:
            return ('wrong', 'candidate timed out')
        if cand.returncode == refuse_code:
            return ('refused', f'exit {refuse_code}')
        cand_out = normalize(cand.stdout)
        # green needs the OUTPUT and the EXIT CODE: a test whose expectation is
        # empty is otherwise satisfied by a candidate that prints nothing at all
        # (measured: the not-implemented stub was "green" on 89 such tests).
        if output_matches(sections, cand_out) and cand.returncode == oracle.returncode:
            return ('green', 'ok')
        if output_matches(sections, cand_out):
            return ('wrong', f'exit {cand.returncode} where php exits {oracle.returncode}')
        return ('wrong', f'exit {cand.returncode}, output disagreed')
    finally:
        cleanup(php_file)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                  formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('files', nargs='*', help='.phpt paths (default: read from stdin)')
    ap.add_argument('--php', default=os.environ.get('PHP', 'php'))
    ap.add_argument('--candidate', default=os.environ.get('MCPHP',
                     os.path.join(os.path.dirname(os.path.abspath(__file__)), 'mcphp-stub.sh')))
    ap.add_argument('--refuse-code', type=int, default=3)
    ap.add_argument('--jobs', type=int, default=os.cpu_count() or 4)
    ap.add_argument('--timeout', type=float, default=15.0)
    ap.add_argument('--sample', type=int, default=0,
                     help='random sample of N files instead of the whole list (seed 0)')
    ap.add_argument('--srcdir', default=None,
                     help='cwd for every spawned process (php-src\'s own runner uses its repo root)')
    ap.add_argument('--out', default=None, help='directory to write per-category lists into')
    ap.add_argument('--quiet', action='store_true', help='suppress the per-test line')
    args = ap.parse_args()

    files = args.files or [l.strip() for l in sys.stdin if l.strip()]
    files = sorted(set(files))
    if args.sample and args.sample < len(files):
        random.seed(0)
        files = sorted(random.sample(files, args.sample))

    if not files:
        print('phpt-run: no .phpt files given', file=sys.stderr)
        sys.exit(2)

    srcdir = args.srcdir
    if srcdir is None:
        # default: the common ancestor directory named php-src, else the
        # directory of the first file
        p = files[0]
        while p and os.path.basename(p) != 'php-src' and os.path.dirname(p) != p:
            p = os.path.dirname(p)
        srcdir = p if os.path.basename(p) == 'php-src' else os.path.dirname(files[0])
    srcdir = os.path.abspath(srcdir)

    eall = e_all(args.php)
    DEFAULT_INI[:] = [x.format(E_ALL=eall) for x in DEFAULT_INI]

    exts_loaded = load_extensions(args.php)

    # the handful of env vars php-src's own run-tests.php injects into every
    # test's environment; some .phpt (e.g. Zend/tests/exit/exit_values.phpt)
    # spawn a nested `php` themselves via getenv('TEST_PHP_EXECUTABLE...')
    # and silently do nothing useful without it.
    php_abs = shutil.which(args.php) or os.path.abspath(args.php)
    base_env = dict(os.environ)
    base_env['TEST_PHP_EXECUTABLE'] = php_abs
    base_env['TEST_PHP_EXECUTABLE_ESCAPED'] = shlex.quote(php_abs)
    base_env['TEST_PHP_SRCDIR'] = srcdir
    for k in ('SSH_CLIENT', 'SSH_AUTH_SOCK', 'SSH_TTY', 'SSH_CONNECTION'):
        base_env[k] = 'deleted'

    buckets = {'green': [], 'wrong': [], 'refused': [], 'skip': [], 'php-fail': []}

    from concurrent.futures import ThreadPoolExecutor, as_completed
    t0 = time.time()
    with ThreadPoolExecutor(max_workers=args.jobs) as ex:
        futs = {ex.submit(classify, f, args.php, args.candidate, args.refuse_code,
                           exts_loaded, args.timeout, srcdir, base_env): f for f in files}
        done = 0
        for fut in as_completed(futs):
            f = futs[fut]
            try:
                cat, reason = fut.result()
            except Exception as e:  # a bug in this script, not the corpus
                cat, reason = 'php-fail', f'phpt-run.py crashed: {e!r}'
            buckets[cat].append((f, reason))
            done += 1
            if not args.quiet:
                print(f'{cat:9s} {f}  ({reason})')
            if done % 2000 == 0:
                print(f'  ... {done}/{len(files)} in {time.time() - t0:.0f}s', file=sys.stderr)

    if args.out:
        os.makedirs(args.out, exist_ok=True)
        for cat, items in buckets.items():
            fn = os.path.join(args.out, cat.replace('-', '_') + '.txt')
            with open(fn, 'w') as f:
                for path, reason in sorted(items):
                    f.write(f'{path}\t{reason}\n')

    g, w, r, s, pf = (len(buckets[k]) for k in ('green', 'wrong', 'refused', 'skip', 'php-fail'))
    total = g + w + r + s
    elapsed = time.time() - t0
    print(f'phpt: green {g} / wrong {w} / refused {r} / skip {s} / php-fail {pf} / total {total}'
          f'  ({len(files)} tests, {elapsed:.0f}s)')
    sys.exit(0)


if __name__ == '__main__':
    main()

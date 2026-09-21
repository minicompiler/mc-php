# The review backlog

GitHub's Copilot reviewer runs on every pull request here (automatically, when the PR is marked
ready for review) and it left **59 inline findings across #1..#7** that nothing acted on: the merge
watches filtered its checks out and nobody read the annotations. They are collected here, with the
verbatim provenance in `docs/copilot-raw.txt` (PR, file, line), grouped by what they cost. Work
them in this order; strike a line only with the measurement that closes it.

**T10 worked all three sections. Every line below is struck with the measurement that closed it,
or refused with a number.** The corrected-against-published table is `probes/t10/RESULTS.md`
§ "Every number T9 published, re-measured".

The three `minicompiler/mc` pull requests of the same days (#99, #100, #101) carry **no** findings:
the reviewer errored on all three ("Copilot encountered an error and was unable to review").

## What is NOT in question

The grid. `probes/t0/phpt-run.py` runs the candidate binary and compares stdout AND the exit code,
and T0 cross-checked it against php-src's own `run-tests.php` (`strings` exact, `Zend/tests` within
8 passes / 5 skips). `green 1450` stands. What the findings below corrupt is the ANALYSIS -- the
wrong-reason table, the arena count, the fixture gate, the benchmarks -- and those numbers have
been quoted in every report since T5.

## 1. The measurements that lie -- DONE (commit `cd6b534`)

The four tools are one tool now: `probes/t10/harness.py`, which is the single definition of
"these two agree" -- stdout byte for byte AND the same exit code, the pair the grid itself grades
on -- and the three callers read it.

- ~~`why.py` / `whytable.py` label a source `(compiled; output differs)` **without ever running the
  binary**~~ (#6 `probes/t7/why.py:36`). It runs it beside php now, and the label is one of
  `output differs`, `agrees on this harness`, `same output, exit N where php exits M`,
  `crashed: signal N` or `timed out`. Every "output differs" count published since T5 meant
  "compiled"; the corrected split is in `RESULTS.md`.
- ~~`diffgroup.py` compares stdout only, while the grid counts an exit-code mismatch as `wrong`~~
  (#6/#7 `diffgroup.py:82`). A pair that agrees on stdout and not on the code has its own group,
  `an exit code`, because the fix for it is a different fix.
- ~~`arena.py` turns every exception into `None` and still divides by `len(files)`~~
  (#6/#7 `arena.py:31`). The denominator is the number of tests that RAN, every other outcome is
  its own line, and an `assert` says nothing was dropped.
- ~~`fixtures.sh` merges the two streams with `2>&1`, and command substitution strips trailing
  newlines~~ (#7 `fixtures.sh:22`). Each stream goes to its own file and `cmp` grades it, with the
  exit code beside them.
- ~~`bench/bench.sh` in t7 and t8 builds and runs **t6's** compiler, runtime and fixture~~
  (#6/#7 `bench/bench.sh:23`). Not copied forward; `bench10.sh` builds and times T10's.
- ~~`run.sh` reads `T6_JOBS` in t7 and t8~~ (#6/#7 `run.sh:32`, `:33`). `T10_JOBS`.
- ~~`why.py` writes `<test>.why.php` beside the input and deletes it in `finally`~~
  (#4 `why.py:28`). `harness.sibling()` creates it `O_CREAT|O_EXCL` and never removes one it
  did not create. Since round six it uses the CANONICAL `<base>.php` -- the name the grid
  itself gives the test, so `__FILE__` is what the grid graded -- with no fallback name at
  all: a name that is taken is skipped and counted (`busy`), which over the 1352-test sample
  is 0 tests.

**And one the section did not name, found by running out of disk.** The grid's tmp directory was
bounded by nothing: `mcphp.sh` EXECs the binary it compiled and so cannot delete it, the sweeper
collected a file only once its mtime was a minute old, and the directory carried the pid so a
killed run's directory was never collected by anyone. A full-corpus run filled a 460 GiB boot
volume at about 20000 of 21395 tests. `probes/t10/tmp.sh` is the one definition now and the
caller -- the process that WAITS -- names the binary with `MCPHP_OUT` and unlinks it the moment
the subprocess returns. **Measured: peak 1860 KiB over 6333 tests; `df -h /` identical before and
after.**

## 2. Language semantics that are wrong (a program can observe every one) -- DONE

Every line below is closed by a FIXTURE that runs under `php` and under mc-php and is compared
byte for byte on stdout, stderr AND the exit code (`probes/t10/fixtures.sh`, **75 / 75** as this pull request ends), or by
a measurement recorded beside it. The fixture is named at the end of each line.

- ~~**`&&` and `||` do not short-circuit**~~ (#5 `php.mc:2202`). Both operands were lowered and
  the right one always ran. The right side's own PENDING statements (an array literal is a run
  of inserts) had to move inside the branch with it, and `??` and `?:` had the same defect.
  `g/61-shortcircuit.php`.
- ~~**Parameters are not by value**~~ (#5 `php.mc:2968`, `:4498`). The copy is in the CALLEE's
  prologue (`ph_byval`), so every call road -- direct, forward, closure, method -- pays it once
  and none can forget; a by-reference parameter is skipped. `g/62-byvalue.php`.
- ~~**`finally` is skipped by a `return`**~~ (#5 `php.mc:3935`), from the try AND from the catch,
  nested, cascading, inside a loop, and a `return` in the `finally` itself. `g/63-finally.php`.
- ~~**A pending exception does not stop the statement**~~ (#5 `php.mc:3101`, `:3098`, `:4850`,
  `:5084`): the condition of an `if`, a `while`, a `for` and a `do`, and the prologue after
  `php_argcount`. `g/64-exception-stops.php`. The `do` arm was the last one and it is the reason
  this fixture had to be killed the first time it ran: `while` and `for` take the condition's own
  statements with `ph_take_pend` and `do` did not, so the unwinding check landed BEFORE the loop
  and `do { } while (t());` with a throwing `t()` spun for ever.
- ~~**Visibility is not enforced**~~ (#5 `php_rt.txt:3438`, `:3453`, `:3494`, `php.mc:2635`,
  `php_rt.txt:3555`): the read STOPS now, the message names `private`/`protected`, a static
  property gets a caller scope and a static method is checked at all. `g/65-visibility.php`.
- ~~**Global functions are not hoisted**~~ (#4 `php.mc:1760`, #5 `php.mc:2921`): a source
  pre-scan plus a lazy row, with the zval signature. `g/66-hoisting.php` (a call before the
  declaration, a typed one, defaults and variadics, recursion, by-reference).
- ~~**Typed method parameters are bound as `PT_MIXED`**~~ (#5 `php.mc:4834`, `:4874`, `:5062`):
  coerced with php's own message. `g/67-typed-params.php`.
- ~~**`?->` is parsed and not honoured**~~ (#5 `php.mc:1695`, `:4935`). `g/68-nullsafe.php`.
- ~~**`mixed` is refused**~~ (#5 `php.mc:1311`) -- closed BY MEASUREMENT before T10 began:
  `function f(mixed $x): mixed` compiles and agrees with php.
- ~~`2 ** -1` answers 1, not 0.5~~ (#4 `php.mc:1251`) -- and `**` is right-associative, found in
  passing (`2 ** 3 ** 2` is 512). `g/69-small-fixes.php`.
- ~~`array_values` copies the zval header only~~ (#5 `php_rt.txt:1942`), and `array_merge` with
  it. `g/69`.
- ~~`array_push($a, 1, null)` drops the explicit null~~ (#5 `php_rt.txt:4640`). `g/69`.
- ~~`spl_object_hash()` returns an integer id~~ (#5 `php.mc:5217`) -- 32 hex characters now.
  `g/69`.
- ~~Runtime-thrown throwables carry the default `file`/`line`~~ (#5 `php_rt.txt:4015`) -- closed
  BY MEASUREMENT: a `DivisionByZeroError` from `1 % 0` reports its own line.
- ~~`php_die` exits without flushing~~ (#4 `php_rt.txt:23`) -- closed BY MEASUREMENT: output
  written before an uncaught exception is on stdout, in php's order, exit 255.
- ~~`func_num_args`'s counter is capped at 10 while 12 parameters are accepted~~ (#7
  `php.mc:2544`, `:6727`, `:6765`). `g/69`.
- ~~`<?=` is accepted and emits nothing~~ (#4 `php.mc:2088`). `g/70-echo-tag.php`.
- ~~`function_exists` always answers false~~ (#4 `php.mc:1756`). `g/69`.
- ~~A global-scope variable of the same name makes a parameter look like a D4 retype~~
  (#4 `php.mc:2413`) -- closed BY MEASUREMENT: `r/d4-retype.php` refuses the real case and the
  refusal gate is 6 / 6.
- ~~`implode(1, ["a"])` passes the integer separator as a string handle~~ (#4 `php.mc:1661`).
  `g/69`.
- ~~`sprintf()`/`printf()` with no arguments reads an argument that is not there~~
  (#4 `php.mc:1428`). `g/71-sprintf-noargs.php`.
- ~~`ph_dq_read` is unreachable for the core lexer's string tokens~~ (#4 `php.mc:440`) -- closed
  BY MEASUREMENT, except for one sub-case that is NOT closed. It is not a refusal either --
  saying so was itself wrong, and the reviewer of #9 caught it: `${` is not a variable-name
  byte, so the reader emits the characters literally and never reaches `ph_refuse`.
  mc 1.1.0's `p_skip_to` gives the module the `"..."` token, so `"$x"`, `"{$x}"`, `"$a[k]"` and
  `"{$a['k']}"` all interpolate and agree with php. **`"${x}"` does not**, and it is not built:
  php 8.2 DEPRECATED that form, so matching it means emitting php's own
  `Deprecated: Using ${var} in strings is deprecated` on both streams as well as interpolating,
  and it is worth **13 tests of the three graded directories and 14 of the whole corpus**
  (`grep -lE '"[^"]*\$\{[A-Za-z_]'`). It is removed in php 9.

## 3. Process -- DONE

- ~~**D8 covers fixtures, and the owner's text says so**~~ (#4 `RESULTS.md:289`). The plan states
  the exemption and a SCRIPT enforces it: `docs/plan.md` D8 (c) gives the reason -- the unit D8
  governs is the PROGRAM, and a differential fixture is already a test, and a stronger one (both
  streams and the exit code, against the reference implementation, in both worlds by
  construction) -- and D8 (d) is `probes/t10/d8check.py`, step 0 of `run.sh`, which puts every
  `.php` under the probe into exactly one of four regimes and fails on a file in none of them.
  It found one on its first run: `probes/t10/bench/unwind.php`, T6's exception bench, copied
  forward twice and referenced by nothing -- deleted. **80 fixture / 3 instrument / 1 library /
  2 bench, 86 files**, and every `test*` the class declares is named by the runner.
- **A merge watch must not filter the reviewer's checks, and a pull request is not merged before
  its findings are read.** Standing, for every pull request from here on. T10's own reviewer
  findings are read and fixed inside its pull request before it is reported.

## 4. The reviewer's findings on T10's own pull request (#9) -- DONE

The standing rule above, applied to this pull request. Twelve inline findings, every one real.

- ~~A top-level `return` inside a `try`/`finally` took the exit and jumped over the finally~~
  (`php.mc:5160`). php runs the finally first, innermost out. The deferred-return FLAG was never
  created at the top level (`if (!ph_toplevel)` guarded its allocation), so the flag the return
  raised was read by nobody and the script simply carried on past the try; the epilogue that
  consumes it was guarded the same way. Both guards are gone and the top-level action is
  `php_exit(0)` instead of a return from `main`. `g/74-toplevel-return-finally.php` -- two
  nested `finally`s, a shutdown function and a destructor, in php's order.
- ~~`diffgroup.py` stripped trailing newlines before comparing~~ (`diffgroup.py:65`), so a pair
  differing ONLY in a final newline compared equal and was reported as `an exit code` with the
  same code on both sides. `splitlines(keepends=True)`.
- ~~`harness.py` ran the CANDIDATE before the oracle~~ (`harness.py:121`), in the test's own
  directory, so a `.phpt` that writes a file beside itself contaminated the ORACLE. php runs
  first now, which is also the order `probes/t0/phpt-run.py` uses -- a tool that explains the
  grid's verdict has to reproduce its conditions.
- ~~`harness.py` ignored `--ARGS--`, `--STDIN--`, `--ENV--` and `--INI--`~~ (`harness.py:121`)
  while the grid passes all four, so it could measure a DIFFERENT program and publish a
  classification for it. It imports `probes/t0/phpt-run.py` and uses the grid's own
  `parse_phpt`/`resolve_sections`/`DEFAULT_INI` rather than a second copy.
- ~~`nocompile.py` skipped only `(compiled; output differs)`~~ (`nocompile.py:41`), so every
  other compiled outcome -- `agrees on this harness`, `same output, exit N`, a crash, a timeout
  -- was counted as a test that DOES NOT COMPILE. It skips every message beginning
  `(compiled;`.
- ~~The D8 gate invokes neither phpunit nor `mc-php test`~~ (`run.sh:153`). Both are unavailable
  and the reason is now PRINTED by the gate rather than implied: phpunit is not installed on
  this host and `mc-php test` does not exist -- D8 (a) names it as the mechanism the compiler
  will provide. What could actually go wrong with a hand-written method list is now a gate:
  `d8check.py` fails when `WorkloadTest.php` declares a `test*` the runner does not name, or
  the reverse.
- ~~The D8 counts in § 3 above said 77 / 83~~ against the measured 79 / 85 -- stale after two
  fixtures were added. They are read from the run now (80 / 86).
- ~~The disk table said 1852 KiB where the invariants and the plan said 1872~~ -- two different
  corpus runs quoted in one document. Both are the final run's.
- ~~The derived percentage followed the wrong peak~~ (0.4% against the real 0.6%).
- ~~"737 do not compile" plus "784 compile and run" exceeded the 1352-test sample~~, which is
  the same defect as `nocompile.py`'s filter seen from the other end.
- ~~Two bench comments pointed at `probes/t10/bench/bench.sh`~~, which does not exist: the
  script is `bench10.sh`.

### And one the second round found, which is T10's own

- ~~`harness.py` handed php a RELATIVE path while running it with `cwd` set to the test's own
  directory~~, so php answered `Could not open input file` -- exit 1, empty stdout -- for
  **every test in the sample**, while the candidate ran anyway (its binary is an absolute
  `mkstemp` path). `probes/t0/phpt-run.py`'s own `classify` opens with
  `path = os.path.abspath(path)` for exactly this reason. The reviewer's finding on the
  unsubstituted `{E_ALL}` placeholder and the missing `-d` prefixes is what led to it, and both
  are fixed together: the INI is built from the grid's list the way `main()` and `run_php`
  build it, and `run_pair` starts by making the path absolute.
  **It costs T10 its own headline.** The first version of this pull request reported
  **143 tests (18.2%) that print exactly what php prints and exit with a different code** and
  recommended them as the next probe's first block. With php actually running there are
  **zero**: of the 784 sampled tests that compile, **758 really differ**, 23 crash, 2 time out
  and 1 agrees. Section 1 of this backlog was worked, and in working it T10 published a new
  number of the same kind -- which is the argument for the rule at the end of § 3, and for one
  more: **a differential tool has to be checked against a case whose answer is known.**

### And the grid's own band, which the section above says is not in question

- **"What is NOT in question: the grid"** is true of its VERDICT and not of its total. Two runs
  of the SAME BINARY over the whole corpus give **green 1676 and 1688**; the smaller set is a
  strict SUBSET of the larger, and all twelve of the difference are FILESYSTEM tests -- 9 under
  `ext/standard/tests/file`, 3 under `ext/standard/tests/dir` (`chdir_basic`, `getcwd_basic`,
  `is_dir_basic`, `is_file_basic`, `rename_variation1`, `file_get_contents_variation7` and
  their kind) -- which `chdir()` and write files in a shared working directory while six of
  them run at once. `php-fail` moves with them, which is php's own side doing the same thing.
  The three DIRECTORY numbers do not move at all: 104 / 749 / 262 came out identical on three
  separate runs across two different compilers. **A per-block move smaller than a dozen tests
  should be read on the directories**, and the corpus number belongs in a report with its band
  -- which no probe has done, T9's 1637 and T8's 1450 included. Not fixed here: isolating the
  filesystem tests is a change to `probes/t0/phpt-run.py`'s working-directory policy, T0's
  file and a decision of its own.

### Round four

- ~~`fixtures.sh`'s timeout wrapper lost SIGNAL termination~~: perl's `$?` carries a signal number
  in its low seven bits with nothing in the high byte, so `exit $? >> 8` reported **0** for a
  fixture that SEGFAULTED -- a crashed fixture could pass the comparison. It is `128 + n` now,
  the shell's own convention and a code php never answers. Measured: a child killed with SIGSEGV
  gives 139, `exit 7` gives 7, `exit 0` gives 0.
- ~~The corrected-results table still said 74 fixtures~~ where the invariant beside it said 75.

### Round five, over code the earlier rounds had not changed

- ~~`bench10.sh` compared the two programs' answers with `$(...)`~~ -- the very defect § 1 fixed
  in the fixture gate, still in the bench: a binary with a missing or extra final newline was
  timed as comparable. Each stream to its own file, `cmp`, and both exit statuses.
- ~~D8 (b) wants a committed, DATED record and `bench10.sh` only printed~~. It writes
  `probes/t10/bench/results/<date>.json` now -- host, php, mc, reps, and per program the
  medians, the bests and both ratios -- and `time2.py` writes that object itself rather than
  the caller re-parsing the line it printed (the first attempt did re-parse, and produced
  invalid JSON).
- ~~`harness.py` named its scratch file `<base>.<tag>.php` where the grid names it
  `<base>.php`~~, so a test that reads `__FILE__` was not the program the grid graded. The
  canonical name is tried FIRST, `O_CREAT|O_EXCL` so a shipped sibling is still never
  clobbered, with the tagged name as the fallback and a count of how often it was needed
  (**0** over the 1352-test sample).
- ~~`harness.py` started from a bare `os.environ`~~ where the grid seeds
  `TEST_PHP_EXECUTABLE`, `TEST_PHP_EXECUTABLE_ESCAPED`, `TEST_PHP_SRCDIR` and the sanitized
  SSH variables. `probes/t0/phpt-run.py` grew `base_environment()` and both callers use it.
- ~~`harness.py` allowed 40 s to compile and 20 s to run where the grid allows 15 s for
  both together~~, so a test the grid called a timeout could be reported here as a completed
  difference. One budget, read from the grid's own `DEFAULT_TIMEOUT`.
- ~~`run.sh`'s D8 gate read php's half through a pipeline~~, so the status it checked was
  `tail`'s. Both streams and the status are captured, and a php that writes to stderr fails
  the gate.
- ~~1860 KiB was quoted for a run whose measured peak was 1892~~, and the second corpus run's
  1908 appeared nowhere. All three peaks, with the test count each belongs to.
- ~~§ 2 above still said the fixture gate was 71 / 71~~ where it ends at 75 / 75.
- ~~The sub-population row said `99 / 102` without saying which run each belongs to.~~

**None of the five harness fixes moved a number**: 568 that do not compile, 758 / 23 / 2 / 1 of
the 784 that compile, 11 of 782 on the arena, 332 / 173 / 129 / 84 in the clustering. They make
the method right, and the answers were already right -- which is worth knowing, and is the
opposite of what the `run_pair` abspath defect did.

### Round six

- ~~The scratch file's tagged FALLBACK still measured a different program~~ when `<base>.php`
  was taken: `__FILE__` and anything derived from it changed. There is no fallback name now --
  `<base>.php` with `O_CREAT|O_EXCL`, and a name that is taken is SKIPPED and counted (`busy`)
  rather than measured under another. Over the 1352-test sample that is **0 tests**, so the
  fallback was buying nothing and hiding something.
- ~~The D8 gate's mc-php half merged its stderr into stdout and read the last line~~, while the
  php half beside it rejected any stderr at all -- a run could warn, print the expected summary
  and pass. Both halves now have their own two streams and their own exit status, and either
  one writing to stderr fails the gate.

Both re-measured: **no number moved** (568 / 758 / 23 / 2 / 1, arena 11 of 782, clustering
332 / 173 / 129 / 84, sub-populations 99 and 15).

### Round seven

- ~~The `...` spread path wrote past its buffer~~ (`php.mc:2943`): each spread appended up to
  `nsp` slots without looking at `n`, so a second or a third `...` in one call ran past the
  `maxn + 1 + PH_SPREADN` allocation and corrupted the COMPILER instead of reaching the
  too-many-arguments diagnostic the ordinary path raises. Bounded before every spread store.
  It uncovered an older bug it does not fix, recorded with its reproducer in `RESULTS.md`:
  `max(...[1,2], ...[3,9])` answers **2** where php says 9 (one spread is right).
- ~~`set -e` made the D8 gate's own status checks unreachable~~ (`run.sh:150`, `:159`): a bare
  command that fails ENDS the script, so `d8pe=$?` and everything after it never ran -- round
  five's fix was itself broken by the shell. Both halves take their status inside an
  `if ...; then :; else ...; fi`, and the two `[ -s ... ] && { ...; }` lines became `if`
  statements for the same reason (an AND-list whose test fails is a non-zero last command).
- ~~Two descriptions of `harness.sibling()` still claimed a counter and a 64-attempt
  fallback~~, which round six removed.

### Round eight

- ~~`harness.py` COMPILED the candidate before running the oracle~~, where the grid runs php
  first and only then invokes `mcphp.sh` (which compiles and runs). A `.phpt` that rewrites its
  own scratch source or an included sibling while the oracle runs would have been compiled from
  different bytes than the grid compiled. The order is the grid's now, in full.
- ~~`diffgroup.py`'s `an exit code` group was unreachable from `run.sh`~~: the filter that
  builds `dg.list` admitted only `(compiled; output differs)`, while `why.py` labels a
  stdout-equal / exit-different pair `(compiled; same output, exit ...)`. Both labels now.
  The group is EMPTY today -- that is the retraction above -- and it took a filter that could
  carry it to be able to say so.
- ~~The pull request's own description still carried the first run's headline~~ (1675 / 748 /
  73 / 85) against the checked-in 1676 and 1688 / 749 / 75 / 87.

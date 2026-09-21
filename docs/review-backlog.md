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
byte for byte on stdout, stderr AND the exit code (`probes/t10/fixtures.sh`, **80 / 80** as this pull request ends), or by
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
  **zero**: of the 812 sampled tests that compile, **788 really differ**, 22 crash, 2 time out
  and none agrees. Section 1 of this backlog was worked, and in working it T10 published a new
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

**None of the five harness fixes moved a number**: 570 that do not compile, 757 / 23 / 2 / 1 of
the 784 that compile, 11 of 782 on the arena, 332 / 173 / 126 / 86 in the clustering. (Those are
the round-six numbers; rounds fifteen and sixteen moved four of them again -- the final sample is
539 / 812 with 788 / 22 / 2 / 0, 11 of 810 on the arena and 338 / 181 / 143 / 86.) They make
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

### Round nine

- ~~The D8 gate kept only the last LINE of each half and accepted anything ending in
  `0 failed`~~, which a runner that executed nothing at all would satisfy -- and `d8check.py`
  compares the names STATICALLY, so it cannot prove one was invoked. The gate now counts the
  `test*` methods the class DECLARES, requires that many `ok` lines from each half, and `cmp`s
  the two whole outputs against each other. Measured: **6 declared, php ran 6, mc-php ran 6,
  and the two worlds printed the same thing**, with nothing on either stderr.

### Round ten -- two of T9's, reproduced and fixed

- ~~`readonly` used the VALUE as the "has it been written" mark~~ (`php_rt.txt:4351`), which its
  own comment admitted: a property deliberately initialised to NULL could be written a second
  time and php refuses that. Reproduced: `public readonly ?int $x` set to null in the
  constructor and then to 5 -- accepted, and php throws. The mark is per OBJECT now, kept in
  the object's own property table under a key beginning with a SPACE, which no php property
  name can be.
- ~~`sscanf`'s outputs were READ rather than taken by reference~~ (`php.mc:1183`): the name was
  missing from the by-reference mask table, so `sscanf("age 25", "%s %d", $w, $v)` warned
  `Undefined variable $w` and wrote nothing back. And the runtime's "was anything passed" test
  was `a1` is not null, which is false for every undefined `$out` at its first use. The mask is
  registered (positions 2..7) and the call site passes `php_zundef()` for a slot it did not
  write, the same marker `register_shutdown_function` uses.

`g/76-readonly-null-sscanf.php` covers both, and the default compiler's answer for each was
measured before the fix.

### Round eleven

- ~~`do { ...; continue; } while (cond)` looped for ever~~: mc's `continue` jumps to the top of
  the `N_LOOP` and the test was placed AFTER the body, so `continue` skipped both the
  condition's own statements and the test. `do { $i++; continue; } while ($i < 1);` never
  terminated where php runs it once. The test is at the top now, behind a first-iteration gate
  -- `ph_loop_of`'s own shape, applied to the condition rather than to the step -- so every
  edge into the next iteration passes through it.
- ~~The readonly mark was kept in the object's PROPERTY table~~ (round ten's own fix), where
  `var_dump`, `print_r`, `foreach`, a clone and a dynamic read would all have seen it. The
  object record grew a table of its own (`php_obj_romarks`, `OBJ_HDR` 32 -> 40) and the marks
  are invisible: `var_dump($c)` and `print_r($c)` agree with php byte for byte.
- ~~`g/inc.php` was counted and RUN as a fixture~~, so the gate said 76 where there are 75
  numbered fixtures. It is a HELPER two fixtures `require`; the gate skips it by name and
  `d8check.py` gained a fifth regime for it, which also checks that some fixture really does
  include it.

### Round twelve

- ~~`harness.py` ran both subprocesses from the TEST's directory~~ where `probes/t0/phpt-run.py`
  runs them from the source root (`cwd=srcdir`). `getcwd()`, a relative `fopen` and a relative
  `require` all saw a different directory, so the classification could describe a different
  program. The scratch file still lives beside the `.phpt` and `{PWD}` still expands to that
  directory -- only the two processes moved.
- ~~`PH_SPREADN` was 10 while `ph_read_args` is called with `maxn` 16~~, so a spread carrying
  11 to 16 values was silently TRUNCATED before dispatch: `printf("%d"x12, ...$a)` with twelve
  of them dropped two and said nothing. It is 16.
- ~~`clone` left the new object's readonly marks empty~~ (rounds ten and eleven's own fix), so
  an already-initialised readonly property could be written on the clone. php keeps it
  initialised and refuses. The marks are copied with the properties.

### Round thirteen -- three findings, and all three were MEASURED before anything was written

Two of them are wrong, and the measurement is how that is known rather than asserted.

- **"Spread argument exceptions are not checked before unpacking"** (`php.mc:2939`) -- the
  structural point is right (the spread path does not isolate `ph_can_throw` or emit a
  `ph_check()` the way the ordinary-argument path does) and the OBSERVABLE case does not
  reproduce: `function boom() { throw new Exception("boom"); } f(...boom());` inside a `try`
  prints `caught boom` then `end` under mc-php, byte for byte php's, and the callee's body
  does not run. Left as it is, with the reproducer: adding the boundary is a few lines, but it
  would change the lowering of every `f(...$x)` and the grid was measured without it, and the
  case it would fix is not one this corpus has produced.
- ~~"Method visibility incorrectly checked against property table"~~ (`php_rt.txt:4267`) --
  **incorrect.** `php_ce_method` writes a method's visibility into table 72 as well
  (`php_rt.txt:4068`, `vis * 8 + 1`, the tag that tells a method from a property), so the
  lookup is right. `g/65-visibility.php` exercises exactly the two the finding names, a
  `private function im()` and a `private static function sm()`, and both raise.
- ~~"Protected access incorrectly permits ancestor scopes"~~ (`php_rt.txt:4274`) --
  **incorrect about php.** The manual's rule is "within the class itself and by inheriting and
  PARENT classes", and php agrees: `class A { function peek(B $b) { return $b->p; } }` with
  `class B extends A { protected $p = 1; }` prints 1 under php, and so does mc-php, for a
  protected property and for a protected method. Measured side by side.

### One more, found by sweeping up after the last grid

- A pid is RECYCLED, so the orphan sweep's `kill -0` can find a LIVE process that is some other
  program entirely and keep a dead run's directory for ever -- the failure the sweep exists to
  stop. It now also removes any sibling a day old whatever its pid says.

### Round fourteen

- ~~Three stale numbers~~: `CLAUDE.md`'s T10 headline still said `green 1637 -> 1688` above a
  line reading 1689, `probes/README.md` still said `strings` 262, and `RESULTS.md`'s
  re-measured table still said 1967 refusals against the 1929 the grid above it reports.
- **"Invoke the compiler instead of mcphp.sh for the D8 benchmark"** (`bench10.sh:43`) --
  **incorrect.** `bench10.sh` calls `probes/t10/mc-php --exe ... -o ...`, the compiler, and
  `grep -n mcphp.sh probes/t10/bench/bench10.sh` finds nothing. The bench runs: its output and
  the record it writes, `probes/t10/bench/results/2026-09-21.json`, are in the tree.

### Round fifteen -- and one of them says this report was wrong

- ~~`bench10.sh` took its two exit statuses with a bare `cmd > out 2> err; ae=$?`~~ under
  `set -e`, so a workload that exits non-zero ENDS the script before the assignment and the
  advertised exit-code and stream gate is unreachable. **Round seven reported this fixed and
  it was fixed in `run.sh` only**; the claim was wrong and the reviewer was right. Both are
  inside an `if` now, and so is the compile above them. Measured: the old form dies before
  its own `echo`, the new one reaches it with `ae=1`.
- ~~`d8check.py` walked `probes/t10` alone~~ while D8 covers every `.php` in the repository,
  so the orphan it exists to catch could sit anywhere else -- and three did:
  `probes/t7/bench/unwind.php`, `t8`'s and `t9`'s, byte-identical copies of T6's, referenced
  by nothing (t7's and t8's own bench scripts run T6's, which is § 1's finding seen from the
  file side). It walks `probes/` now, **356 `.php`**, with three enumerated pre-D8 exemptions
  the sweep fails on if they vanish. The three copies are deleted; T6's original is untouched
  and still reproduces. One thing the widening needed: **the checker must not read ITSELF** --
  its own doc comment names t9's orphan, which was enough to make the sweep believe something
  referenced it, and t9's copy stayed invisible until that line was added.
- ~~`harness.py` collapsed exit 255 into `no-compile`~~. 255 is a php COMPILE-TIME fatal, which
  php reports while parsing and the grid COMPARES: `mcphp.sh` passes it through deliberately.
  It is a run now, with the compiler's two streams as the program's. Measured on
  `g/28-compile-fatal.php`: `status ran, rc 255, wrc 255, agrees True`, where it was
  `no-compile` before.
- **D8 (a)'s PHPUnit half** is now an EXEMPTION in `docs/plan.md` D8 (e) with its two reasons
  -- phpunit is not installed here and `mc-php test` does not exist -- and `run.sh` prints
  what the gate does and does not prove, rather than leaving it looking like it proved the
  other thing.
- The three number findings were already fixed when the review was generated (`1967` survives
  only in this file, describing what WAS wrong). `grep -rn 1967` over `RESULTS.md`,
  `CLAUDE.md`, `probes/README.md` and `docs/plan.md` is empty.
- **"Invoke the compiler instead of mcphp.sh for the D8 benchmark"** remains **incorrect**:
  `bench10.sh:43` is `probes/t10/mc-php --exe ... -o ...`, and `grep -n mcphp.sh
  probes/t10/bench/bench10.sh` finds nothing. The `set -e` half of the same comment WAS right
  and is the first line above.

### Round sixteen

- ~~The committed dated bench record disagreed with every number quoted around it~~: the JSON
  said 6.84x / 1.48x while the pull request said 7.43x / 1.42x and the reports 7.21x / 1.44x --
  three runs, one of them committed, and the prose quoting the others. The record is
  regenerated and **every report now reads its four numbers out of it**, which is the whole
  point of D8 (b) asking for a dated one: a bench number in prose has nowhere to be checked.
  The machine was loaded for this run (php's own start-up is 77 ms against T9's 38 ms), and a
  dated record is what makes that visible rather than confusing.

### Round seventeen

The reviewer's seventeenth pass carried **1 open finding and 14 "previously
missed"** -- findings in code that had not changed since the pass before, which
is the first time this review surfaced that category. Every one of the fifteen
is answered below.

**The open one, and it is a real defect in the compiler.**

- ~~`php.mc`: a spread argument that throws is not checked before unpacking.~~
  The ordinary argument path saves and clears `ph_can_throw`, hoists a throwing
  argument into a temporary and inserts `ph_check` between the temporary and the
  call; the `...` path did neither, so `f(...boom())` ran `php_unpack_at` and
  then the CALLEE'S BODY with the exception still pending. Reproduced against a
  compiler built from the previous commit: `g/77-spread-throw.php` printed
  `body` before `caught boom`, where php prints only `caught boom`. Six added
  lines in `ph_read_args` give the spread the same boundary; the fixture is
  byte-identical to php on both streams and the exit code now, and it carries
  the ordinary spread and a spread after a positional argument beside the
  throwing case.

**The nine tools and scripts.**

- ~~`bench/shim.php`: `class_exists(..., false)` never autoloads.~~ Correct. A
  real PHPUnit run that has registered its autoloader but not yet touched
  `TestCase` answered "not there" and got the shim -- the one case the guard
  exists to lose. The `false` is gone. mc-php has no autoloader, so its answer
  is unchanged and the shim still wins there.
- ~~`d8check.py`: `f in text` treats a mention as a reference.~~ Correct, and the
  self-reference was the sharp edge: the sweep concatenated every `.sh`, `.py`
  and `.php` under `probes/` INCLUDING the candidate, so an orphan naming its own
  path passed. The sources are kept one per file now and each candidate is
  searched in every OTHER one, with whole-line comments dropped first. Proved by
  measurement: a `probes/t10/scratchx/orphan.php` whose only mention of itself is
  its own comment is reported (`no fixture gate runs it, no .php requires it, no
  script names it`), where the old sweep passed it.
- ~~`why.py` and `diffgroup.py` oversubscribe past `T10_JOBS`.~~ Correct, and it
  is the same resource this probe's first commit was written to bound. One
  `harness.jobs()` -- `T10_JOBS` when set, `os.cpu_count()` otherwise -- is what
  both pools take now.
- ~~`fixtures.sh` accepts a fixture that timed out in both worlds.~~ Correct: 124
  is `lim`'s own alarm, and two empty streams with two 124s compared equal. The
  `g/` gate fails on a 124 from either side before it compares. (The `r/` gate
  already required exit 3 exactly.)
- ~~`harness.py` reports an oracle timeout as a candidate run timeout.~~ Correct.
  The test was "the compiler, else the binary", so a php that ran out of time --
  the grid's `php-fail` -- came back as `run-timeout` and `why.py` labelled it
  `(compiled; timed out)` for a test that was never compiled. There is a
  `php-timeout` status now and `why.py` prints `(php timed out)`.
- ~~`nocompile.py` counts non-test statuses as tests that do not compile.~~
  Correct in principle. A compiler diagnostic is `file:line: message` and never
  begins with a bracket, so the filter is now "any message that opens with `(`",
  which covers the five compiled outcomes and equally `(compiler timed out)`,
  `(php timed out)`, `(a sibling ...)`, `(no --FILE-- section)` and `(error)`.
  **It moves nothing in this run**: the published `why.tsv` has 0 rows in those
  statuses, so the block is 539 before and after.
- ~~`subpop.py` omits `EXPECT_EXTERNAL` from the population.~~ Correct, and fixed
  by going through the grid's own `parse_phpt` + `resolve_sections` rather than a
  second regex. **It moves nothing either**: the corpus has **2**
  `EXPECT*_EXTERNAL` tests and **neither** asserts a diagnostic line, so the
  population is 4647 with the fix and without it.
- **`tmp.sh`: `-maxdepth` is a GNU primary that BSD `find` does not have.** This
  one is wrong, and the measurement is one command. macOS's own
  `/usr/bin/find` documents `-maxdepth` (`man 1 find`, line 307: `"-maxdepth 0"
  limits the whole search to the command line arguments`) and performs it:
  `touch -t 202001010000 d && /usr/bin/find d -maxdepth 0 -mtime +1 -exec rm -rf
  {} +` removes the directory, exit 0, on Darwin 25.6.0. The fallback works on
  the platform the finding says it fails on.

**The five stale splits** (`CLAUDE.md`, `docs/plan.md`, this file, `probes/README.md`
and `RESULTS.md` twice) all carried `784 / 757 / 23 / 2 / 1`, which rounds
fifteen and sixteen replaced. Each now reads the final sample, recounted from
the committed `out/why.tsv` rather than copied from prose: **1351 tests,
812 compile, 788 differ, 22 crash, 2 time out, 0 agree**, 539 that do not
compile, and 338 / 181 / 143 / 86 in the clustering.

### Round eighteen

Nine findings: six new and three more in code that had not changed. Seven
needed a change, one is a documentation correction the previous round caused,
and one is a re-reading of an amendment this probe already recorded.

- ~~`bench10.sh` truncates the dated record before it measures.~~ Correct, and
  it is the file D8 (b) asks for precisely because it survives: a compile
  failure, a stream mismatch, a timeout or a `^C` left half a JSON object at
  the committed path and destroyed the previous valid one. The record is built
  in `$tmp`, parsed with `json.load` and MOVED into place on success.
- ~~`harness.py` never runs `--CLEAN--`.~~ Correct, and measured in both
  directions: `run_pair` on `ext/standard/tests/file/005_basic.phpt` left
  `005_basic` and `005_basic.tmp` in the source tree before the fix and leaves
  **nothing** after it. The section runs between the oracle and the compile,
  which is where `probes/t0/phpt-run.py` runs it.
- ~~`harness.py` compiles with the analysis process's environment and working
  directory.~~ Correct: the grid spawns `mcphp.sh` with the test environment and
  `cwd=srcdir`, so a source whose include resolution depends on either was
  compiled under a different harness than the one graded. The compiler
  subprocess takes `env` and `cwd=run_cwd` now, as the binary already did.
- ~~`arena.py` hard-codes six workers.~~ Correct -- it was the one analysis tool
  round seventeen did not reach. `harness.jobs()`.
- ~~`run.sh` does not export the RESOLVED job limit.~~ Correct, and it is what
  made round seventeen's fix incomplete: with no `T10_JOBS` in the caller's
  environment the grid ran 12 workers and `harness.jobs()` fell back to
  `os.cpu_count()`. `T10_JOBS=$JOBS; export T10_JOBS`.
- ~~`docs/plan.md` D8 (e) still quotes `class_exists(..., false)`.~~ Correct, and
  the previous round caused it. Both it and the two stale paragraphs in
  ~~`bench/shim.php`~~ now describe the autoloading lookup that is there.
- ~~The pull request's own description says "784 sampled tests that compile and
  run".~~ Correct: the measured breakdown is 812 that compile, of which 810 run
  to completion (788 differ, 22 crash) and 2 time out. The description is
  rewritten from the same recount as the five files of round seventeen.
- **`docs/plan.md` D8 (c): a differential fixture is not the mandated
  coverage.** Recorded as an amendment rather than an omission, and the shape
  was the owner's to choose. D8's unit is the PROGRAM. A `g/` fixture IS a test,
  and a stronger one than the PHPUnit row D8 (a) asks for: it is compared
  against php byte for byte on stdout AND stderr AND the exit code, where a
  PHPUnit assertion compares what the test's own author thought to assert. A
  benchmark row for a four-line fixture measures process start-up. What makes
  it an exemption and not prose is `d8check.py`: the fixture regime is a regime
  with its own obligation -- every `g/` and `r/` file must be walked by
  `fixtures.sh`'s own globs, which the script reads OUT of `fixtures.sh` and
  fails if they change -- and the repo-wide sweep then requires every other
  `.php` under `probes/` to be in one of the five regimes or named by a gate.
  (e) records the PHPUnit half as exempt for as long as `mc-php test` does not
  exist, with the mechanism named.

### Round nineteen

Nine findings again: four new in the compiler and the runtime, five in code
that had not changed. Six changed something, one is a number recount, one is a
recorded gap with its size, and one is the probe contract.

**Four in what mc-php actually does, three of them fixed.**

- ~~A runtime spread is truncated at 16 values.~~ Real, and silent: `f(...range(1,20))`
  answered **16** where php answers 20. The compiler emits a fixed number of
  slots and cannot see the array, so the honest answer is a named failure
  rather than a wrong number: `php_unpack_check` counts the elements before
  the call and, past the slots, `php_die`s with
  `mc-php: a spread of more than 16 values is not implemented yet` (exit 255).
  It is mc-php's own limit and not a php error, so it reads like
  `arena exhausted` and not like a TypeError. An unbounded variadic path is a
  block for a later probe: it needs a call convention the fixed `MAXPARAMS`
  frame does not have.
- ~~`php_unpack_at` returns 0 for a non-array operand and raises nothing.~~ Real:
  `f(...1)` called `f` with no arguments where php raises before entering it.
  The same `php_unpack_check` raises php's own message --
  `TypeError: Only arrays and Traversables can be unpacked, int given` -- and
  the two worlds are byte identical on it now.
- ~~A declared parameter type is dropped when the parameter has a default or a
  forward call fixed the signature.~~ Real: `function f(int $x = 1)` then
  `f([])` ran the body where php raises a TypeError. The declared primitive is
  kept beside the forced `PT_MIXED` and the prologue calls the same
  `php_param_coerce` the method path already used -- which returns its argument
  unchanged when it is 0, so "not passed" still reaches the default. Measured on
  all five primitives, on a forward call, and on a variadic.
  `g/78-spread-and-types.php`.
- **A declared type that is not one of the five primitives is still not
  checked**, and this one is recorded rather than fixed. `?int`, a union, a
  class, `callable`, `object` and `iterable` all collapse to `PT_MIXED` in
  `ph_type_word`, so the information is gone before the prologue is built:
  `function n(?int $x)` accepts `"abc"` and `function c(C $o)` accepts `5`,
  where php raises a TypeError for both. Fixing it needs the declared NAME
  carried to the prologue and an `instanceof` at run time -- feature work, not
  a guard. Its size, measured: **493 `.phpt` of the corpus** declare a
  non-primitive parameter type.

**Five in the tools and the documents.**

- ~~`harness.py` gives the compile and the run a whole budget each.~~ Correct: a
  compile that took nearly the limit left the binary another one, so a pair
  could run for almost 2x the grid's timeout and be reported as `run-timeout`.
  One deadline covers both now.
- ~~`harness.py` compares raw stdout where the grid normalizes.~~ Correct. The
  grid grades through `normalize` (php trim, then CRLF), so a trailing-newline
  difference was a disagreement here and the same output there. `_agree` runs
  the grid's own `normalize` on both sides; the raw streams stay in the result
  because the first-difference tables want the bytes.
- ~~The fixture count is 76, not 75.~~ It is **77** now, with this round's
  `g/78`. Every document says 77 and the number comes from the gate.
- ~~The disk peak is quoted four different ways.~~ Correct, and they were four
  different runs. `RESULTS.md` has the table (1860 KiB over 6333 tests, 1908
  over 27728, **2152 over the same 27728 on the round-seventeen re-run**) and
  every other document now says which run it quotes. The claim is unchanged and
  the band is worth having: 13% on a 2 MB number while the corpus varies by 4.4x.
- **The one-number contract.** T10 answers ONE question -- the backlog -- and
  its number is the corpus grid's green/total, the pair every probe since T1
  has ended on; the tables above it are the analysis § 1 of this backlog
  demands, each its own script a reader can run alone. What was missing is that
  the contract was asserted and not checkable, so `run.sh` now ends on
  `T10: <green> / <total>`, read off the grid's own summary line rather than
  recounted from the bucket files (a `.phpt` name can carry a newline).

The round-nineteen grid, re-run because the compiler changed: directories
identical (104 / 749 / 263), corpus **green 1688 / wrong 14489 / refused 1929
/ skip 2947 / php-fail 342 / total 21053**. Two deltas against the published
run and both are named -- one green lost (`is_dir_basic`, one of the band's
own twelve) and **20 tests out of `php-fail` into `wrong`**, because the
source tree was cleaned of the leftovers the pre-CLEAN harness had made. The
round-eighteen finding, measured from the other side: the contamination was
costing the grid 20 tests of its denominator.

### Round twenty

Thirteen findings. Twelve changed something; one is refuted with a
measurement.

**The compiler and the runtime.**

- **`function f(int &$x)` accepts an invalid value.** Refuted for the ordinary
  function, where mc-php **refuses it at compile time** -- `/tmp/r1.php:2:
  mc-php: a php parameter: & is not implemented yet`, exit 2 -- because the
  path reads `&` before the type word and a type before the `&` never reaches
  a `$`. ~~The METHOD path does accept it, and there IS a divergence there --
  a different one.~~ The TypeError is raised correctly; what was lost is the
  WRITE-BACK: php coerces the caller's own variable (`m(int &$x)` with `"5"`
  leaves 6 behind) and mc-php left `'5'`, because `php_param_coerce` returns a
  new zval and the alias went with it. `php_param_coerce_ref` stores the
  coerced value into the same cell and returns that cell; measured, the two
  worlds are byte identical now.
- ~~The unpack check rejects a Traversable.~~ Correct, and the message it
  raised claimed Traversables are supported. php iterates one; mc-php does
  not, so an object operand is now the named limit
  `mc-php: a spread of a Traversable is not implemented yet` rather than a
  TypeError that says the opposite of what it does.
- ~~The slot-limit message hard-codes 16.~~ Correct: the cap is 16 for a plain
  function, 6 for a method, 5 for a callable. The message is built from the
  cap now -- and, found while measuring it, **the check itself was wrong for a
  non-variadic callee**: `$m->m(...[1..7])` on a six-parameter method prints
  php's answer, because php IGNORES arguments past the arity, and the new
  check was killing it. The count is checked only when the ceiling is this
  compiler's buffer (`nsp == PH_SPREADN`), not when it is the callee's own
  arity. Both cases measured against php.

**The tools.**

- ~~`fixtures.sh` treats exit 124 as its timeout.~~ Correct: a fixture may
  exit(124) legitimately. The alarm writes a marker file and the gate reads
  THAT; `g/79-exit-124.php` is the case, and it FAILS under the old condition
  (`77 / 78`, `FAIL 79-exit-124.php (timed out: php 124, mc-php 124)`) and
  passes under the new one (78 / 78).
- ~~`d8check.py` exempts `probes/*/g` and `*/r` by NAME.~~ Correct -- an
  unreferenced `probes/new/g/orphan.php` passed the only repo-wide sweep. The
  exemption is derived from the probe's own scripts now, in both spellings the
  repository uses (`$P/g` in T10's `fixtures.sh`, `probes/tN/g` in T8/T9's and
  in T5..T7's `run.sh`). Measured: the real tree is clean and a synthetic
  `probes/t99/g/orphan.php` is the one thing reported.
- ~~`tmpbin()` puts analysis binaries outside the bounded directory.~~ Correct,
  and it is the space this probe claims to bound: `MCPHP_TMP` when the caller
  made one, the system default otherwise.
- ~~`why.py` and `diffgroup.py` compare raw output before classifying an
  exit-code-only mismatch.~~ Correct, and `run_pair`'s own verdict already used
  the grid's `normalize`: the three now agree.
- ~~`run.sh`'s last line is prose.~~ Correct. `T10: <green> / <total>` is last.
- ~~The bench record does not carry the php runtime configuration.~~ Correct, and
  D8 (b) asks for it. The record now has `opcache`, `jit` and `jit_buffer`,
  including the disabled values (here: `loaded-off-cli`, `disable`, `64M`).
  Regenerating it moved the two ratios to **6.73x** and **1.41x**, and every
  report reads them out of the file.
- ~~Three stale gate counts~~ (`CLAUDE.md`, `docs/plan.md`, `RESULTS.md`): 84
  fixture files, 91 `.php` in a T10 regime, 359 swept, `lencheck` 501.

### Round twenty-one

Nine findings, all real, all in the scripts -- the compiler and the runtime
were not touched.

- ~~`tmp.sh` deletes a LIVE run's directory once it is a day old.~~ Correct, and
  worse than the orphan it was guarding against: a corpus grid runs for an
  hour and a long one would have had its binaries removed from under it. The
  owner writes its own start time (`ps -o lstart= -p $$`) into the directory
  and the sweep compares it: same pid AND same start time is the real owner,
  a different start time is a recycled pid, no pid at all is a dead run.
- ~~`tmp.sh` reads `peak` without waiting for the watcher.~~ Correct. It waits
  now -- and the fix had a defect of its own, measured before it was believed:
  the watcher dies of the signal, `wait` answers 143, and under `set -e`
  inside an EXIT trap that ended the trap before it printed. With `|| :` on
  both the kill and the wait: `tmp peak: 508 KiB`, exit 0.
- ~~`mcphp.sh` leaves the compiler running when the wrapper is killed.~~
  Correct, and it is the orphan the disk bound exists to prevent. The
  compiler runs in the background and is waited for, with INT and TERM
  killing it and removing the three files.
- ~~Three signal traps clean up and RETURN.~~ Correct: an interrupted run
  carried on with its temporary directory gone and ran the handler again on
  the way out. `fixtures.sh`, `grid.sh` and `run.sh` now keep the cleanup on
  EXIT and exit 130 / 143 on the signals. Measured: a TERM'd run prints its
  peak, does NOT reach the statement after the sleep, exits 143 and leaves
  no directory.
- ~~`d8check.py` exempts a file by BASENAME when a bench loop names one.~~
  Correct -- any other probe's `main.php` counted as benched. The paths are
  resolved against the directory the loop itself spells; measured, a
  synthetic `probes/t98/main.php` is reported and the real tree is clean.
- ~~The fixture count is 77 in `docs/plan.md` and `probes/README.md`.~~ 78.

### Round twenty-two

Four findings, all real.

- ~~A SIGKILL on the wrapper leaves the compiler running.~~ Correct, and the
  previous round's fix could not cover it: `subprocess.run`'s timeout and
  `lim`'s alarm both send SIGKILL, which runs no trap. **Measured, both
  ways**: a 3-million-statement source compiled for two seconds and then
  killed leaves **1 surviving compiler** when the wrapper alone is killed and
  **0** when the process group is. `probes/t0/phpt-run.py` starts the
  candidate with `start_new_session` and kills the group on a timeout;
  `fixtures.sh`'s perl child calls `setpgrp` and the alarm kills the negative
  pid. The TERM/INT traps in `mcphp.sh` stay for a polite kill.
- ~~`harness.py`, `why.py` and `diffgroup.py` compare the candidate with php's
  BYTES where the grid matches the test's own expectation.~~ Correct, and it
  is the sharper version of round eighteen's normalization finding: the grid
  greens a candidate that satisfies `--EXPECTF--` or `--EXPECTREGEX--`, not
  one that reproduces php's particular output. `agrees(sec, ...)` is the
  grid's `output_matches` over the parsed sections now, with php's output as
  the fallback when a test carries no expectation at all, and the two
  analysis tools ask the same function.
  **It moves nothing in this sample, and the reason is worth writing down**:
  the 1351 tests are the grid's own `wrong` bucket, so `output_matches` is
  false for every one of them by construction. Re-measured end to end --
  812 compile, 788 differ, 22 crash, 2 time out, 0 agree, 539 do not compile,
  and the clustering 338 / 181 / 143 / 86 -- all identical. Where it does
  change an answer is OUTSIDE that sample:
  `ext/standard/tests/file/is_dir_basic` (a green) is `agrees True` under the
  matcher and was False against php's bytes, because php's own run printed a
  `mkdir(): File exists` warning its EXPECTF tolerates.

### Round twenty-three

Five findings: two new, two in code that had not changed, and one re-post.

- **`fixtures.sh`'s alarm kills only the wrapper.** Refuted, and measured:
  `kill -9, $p` is how perl spells the process GROUP (`perldoc -f kill`: a
  negative SIGNAL kills process groups), and the child makes itself the
  leader with `setpgrp(0, 0)` one line above. A harness whose child spawns a
  `sleep 30` and is killed by the alarm leaves **no grandchild** -- exit 124,
  `grandchild gone`. The redundant `kill 9, $p` after it is dropped and the
  measurement is in the comment.
- ~~`harness.py`'s own subprocesses are not group-aware.~~ Correct, and it is
  the same finding one level in: `base_environment` sets
  `TEST_PHP_EXECUTABLE` precisely so a .phpt CAN spawn a nested php, and the
  compiler is a child too. All four calls -- oracle, CLEAN, compiler,
  binary -- go through one `_run` that starts a session and kills the group
  on a timeout, the same shape `probes/t0/phpt-run.py` got in round
  twenty-two.
- ~~The CLEAN call inherits the analysis process's stdin.~~ Correct: the grid
  passes an empty buffer and a CLEAN that reads stdin would otherwise block
  or eat something else's input. `input=b''`, as every other call in the
  function now has.
- **`run_pair` does not run `--SKIPIF--`.** Recorded, not fixed, and the
  reason is what the section IS: the grid runs SKIPIF **to decide whether to
  run the test at all**, and a test it skips never reaches `why.py` -- the
  lists these tools read are `wrong.txt`, which is disjoint from `skip.txt`
  by construction. What the finding is really about is a SKIPIF with a side
  effect, which is rare and which no test in the sample has; running it here
  would also mean reproducing the grid's skip DECISION, which is a second
  behaviour rather than a fix. Recorded in `RESULTS.md` with the reasoning.

### Round twenty-four

Two documentation findings, and a third the review's own summary line named
without filing -- which turned out to be the most serious thing in this
round.

- **A FAILED typed by-reference coercion wrote NULL into the caller's
  variable.** Not in the findings list; the overview sentence said "failed
  typed by-reference coercions mutating caller values" and it was right.
  `php_param_coerce` raises and answers `php_znull()` on a refusal, and
  round twenty's `php_param_coerce_ref` stored that answer back before the
  exception unwound. Measured: `m(int &$x)` with an array printed `NULL`
  where php prints `array(0) {}`. The write-back is skipped when an
  exception is pending; `g/80-byref-typed.php` carries the coercion that
  succeeds (`"5"` leaves 6 behind), the one that fails (the caller's array
  untouched) and the value that needs none.
- ~~The backlog's own headline still said 77 / 77.~~ 79 / 79.
- ~~`RESULTS.md` said `probes/t9/` is left exactly as it was~~, and this pull
  request deletes `probes/t9/bench/unwind.php`. It now says what was deleted
  and why: an orphan copied forward from T6 that no gate ran, found by
  `d8check.py`, with T7's and T8's copies and T6's original untouched.

### Round twenty-five

Three findings, all real, and one of them moves a published number.

- ~~`arena.py` counts a php COMPILE-TIME fatal as a test that RAN.~~ Correct,
  and it is the same distinction round fifteen drew from the other side:
  `run_pair` calls exit 255 `ran` because the GRID grades that pair on its
  output, but no binary was executed -- and `arena.py` was then searching
  the COMPILER's stderr for `arena exhausted`, which is a different arena
  from the one D7 asks about. The result carries `compile_fatal` and
  `arena.py` gives it a bucket of its own. **It moves the number**:
  `arena exhausted in 11 of 810` is `11 of 779`, with `not run: 31
  compile-fatal` on its own line. The eleven tests are the same eleven.
- ~~`WorkloadTest`'s tie branch never executed.~~ Correct: `wl_make_records`
  steps the score by 7919 modulo 1000, which has period 1000, so 40 records
  have 40 distinct scores and the equal-score comparison the test is named
  after was dead. Three records now share a score with their names out of
  order, and the tie is asserted by name. Proved to have teeth: negating the
  `strcmp` makes it `5 ok / 1 failed`, in both worlds.
- ~~`RESULTS.md`'s re-measurement table still said 77 fixtures~~ where the
  invariant section of the same file said 79.

### Round twenty-six

Four findings, all real, and none of them moves a measured number -- which
is itself the point of three of them: each is a hole through which a FUTURE
measurement could go wrong.

- ~~The pre-D8 exemption is by DIRECTORY.~~ Correct: `f.startswith(d + '/')`
  exempted everything `probes/t0`, `probes/t4` and
  `probes/gap-lexer-ownership` will ever hold, so a new orphan dropped into
  one of them passed the only repository-wide check. The exemption is a
  SNAPSHOT of the 59 files that were there when D8 was written, and it
  cannot rot in either direction: a file added to one of those directories
  is an orphan like any other (measured -- `probes/t0/orphan-new.php` is
  reported) and a name in the snapshot that is no longer on disk is
  reported too.
- ~~A killed run's scratch `.php` makes every later run call that test
  `busy`.~~ Correct, and it would shrink the sample silently. The scratch
  file carries an owner marker with this process's pid and start time (the
  pair `tmp.sh` uses, for the same reason): a `.php` php-src really ships
  has no marker and is never touched, one whose owner is gone is taken
  over, one whose owner is alive is still `busy`. All three measured.
- ~~`nocompile.py` drops a silent compile failure.~~ Correct, and it was
  round seventeen's own doing: the filter became "any message that opens
  with a bracket" and `why.py` wrote `(exit N, silent)` for a compile
  failure with no stderr. The message is now
  `the compiler failed with exit N and said nothing`, which is what it is
  and which the rule already covers. Re-measured: the sample has 0 of them,
  so the block is 539 either way and the two tables are unchanged.
- ~~`CLAUDE.md` says T10 is measured on mc 1.1.0 while the rules say the
  repository consumes mc 1.0.0.~~ Correct, and the rule was the imprecise
  half. Both files now say what is true: a consumer of mc's **1.0 frozen
  surface**, BUILT with whatever 1.x is installed -- the freeze is additive,
  so a later minor keeps every name 1.0.0 published -- with each probe
  recording the version it measured on.

### Round twenty-seven

Six findings. Two fixed in the compiler and the scripts, three refuted with
a measurement, one re-posted and answered again.

- ~~`max`/`min` silently drop everything past the tenth value.~~ Correct, and
  it is the sharpest thing in this round: `php_maxmin` carries ten values
  (`MAXPARAMS` is 12 and two are spent on the direction and the count) and
  the loop stopped there without saying so. Measured: `max(1,...,11)`
  answered **10** where php says 11, `min(11,...,1)` answered **2** where
  php says 1, and `max(...[1..10,99])` answered **10** where php says 99.
  max and min are ASSOCIATIVE, so the call folds in chunks of ten -- the
  same answer, no new runtime entry point and no second array.
  `g/81-maxmin-wide.php` carries the three plus the shapes that were
  already right (two values, an array, string comparison, a float).
- ~~The watcher's age sweep can delete an active binary.~~ Correct: it took
  every file older than a minute except `peak` and `owner`, which is a
  binary a slow compile is still writing and the `d8p.out` that `run.sh`
  writes and then reads. It is five minutes now -- twenty times the grid's
  own 15-second budget -- and only the four artefact names these tools
  create (`mcphp*`, `why.*`, `dg.*`, `ar.*`), so nothing else in the
  directory is its business.
- **`_run()` sends stderr to DEVNULL and returns none.** Refuted: the
  default is `stderr=subprocess.PIPE` and the helper returns a
  `CompletedProcess` carrying both streams; only the CLEAN call asks for
  DEVNULL. Measured: a run gives `err len 0` and a no-compile gives a
  populated `cerr`, and `why.py` completed over all **1351** tests after
  that change. The contract is now written above the `Popen`.
- **`ph_argref` leaks to the next call.** Refuted by reading and by
  measurement: `ph_read_args` copies it into a local and CLEARS it at
  entry, and the assignment is the statement before the call. `sscanf`
  followed by `str_replace` and `substr` is byte for byte php's.
- **`ph_had_spread` leaks to later calls.** Refuted for every order tried.
  The line the finding points at restores the value the ENCLOSING argument
  list had, which is what a nested call needs. Measured: after
  `f(...[1,2])`, `max(3, 4)` takes the two-argument fast path and
  `strlen("abc", "extra")` still raises `the wrong number of arguments for:
  strlen` -- the diagnostic the clamp at line 3942 would have skipped -- and
  both are byte for byte what they are without the spread before them.
- **The one-number contract** was re-posted and is answered in round
  nineteen: `run.sh` ends on `T10: <green> / <total>`, and the tables above
  it are the analysis section 1 of this backlog demands, each its own
  script.

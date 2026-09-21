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
  (#4 `why.py:28`). `harness.sibling()` creates it `O_CREAT|O_EXCL`, tries a counter, gives up
  after 64, and never removes one it did not create.

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
byte for byte on stdout, stderr AND the exit code (`probes/t10/fixtures.sh`, **71 / 71**), or by
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
  BY MEASUREMENT, except for one sub-case that is NOT closed and is refused with its number.
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
  forward twice and referenced by nothing -- deleted. **77 fixture / 3 instrument / 1 library /
  2 bench, 83 files.**
- **A merge watch must not filter the reviewer's checks, and a pull request is not merged before
  its findings are read.** Standing, for every pull request from here on. T10's own reviewer
  findings are read and fixed inside its pull request before it is reported.

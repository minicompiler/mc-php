# T10 -- the review backlog: the measurements that lie, the semantics that are wrong, and D8 over the fixtures

Question (`docs/plan.md` § 4): GitHub's Copilot reviewer left **59 inline
findings across #1..#7** and nothing acted on them -- the merge watches
filtered its checks out and nobody read the annotations. They are collected
in `docs/review-backlog.md`, grouped by what they cost, and T10 works all
three groups in that order: the measurements that LIE (they choose what
every other block works on), the semantics a program can OBSERVE, and D8
over the fixtures.

Run: `sh probes/t10/run.sh`. Host: macOS 26 / arm64, **mc 1.1.0**, PHP 8.5.10
(Homebrew, NTS), php-src at `php-8.5.10`.

`probes/t9/` is left exactly as it was. Every measurement here was taken
against a SNAPSHOT of the compiler (`probes/t10/grid.sh`,
`probes/t10/fixtures.sh`), which is T7's own note: the first baseline there
measured a binary that was being rebuilt underneath it.

## Answer: green 1637 -> 1688

| grid | green | wrong | refused | skip | php-fail | total | T9's green |
|---|---|---|---|---|---|---|---|
| `tests/lang` | **104** | 141 | 36 | 12 | 1 | 293 | 102 |
| `Zend/tests` | **749** | 3754 | 691 | 112 | 6 | 5306 | 709 |
| `ext/standard/tests/strings` | **262** | 311 | 107 | 54 | 0 | 734 | 262 |
| **the whole corpus** | **1688** | 14433 | 1967 | 2947 | 360 | 21035 | 1637 |

`refused` fell **2309 -> 1967** over the corpus and **725 -> 691** under
`Zend/tests`, and that is one block: `require __DIR__ . "/x.php"` and a
top-level `return` were refusals and are not any more (block 4). `wrong`
rose with it, because a test that now COMPILES gets far enough to print
something that can disagree.

**1663 of the 1688 greens are in T0's "touched by none" set** -- the 84.2% of
the corpus none of § 3's decisions touches -- against T9's 1626 of 1637.

T9's line on the same corpus and harness:
`green 1637 / wrong 14140 / refused 2309 / skip 2947 / php-fail 362 / total 21033`.
T8's: `green 1450`. T7's: `green 1218`. T6's: `green 1073`. T5's: `green 80`.
T0's, before any compiler existed: `green 0`.

The green moved **+51 on a block of pure CORRECTNESS work**, which is the
smallest per-block move of any probe so far and is the expected shape: § 2 of
the backlog fixes what a program OBSERVES, not what it can express, and a
`.phpt` that was already green does not become greener for being right about
short circuit. The two numbers to read are `refused`, down 342, and this:

## Every number T9 published, re-measured

The first column is what `probes/t9/RESULTS.md` says. The second is this
tree, with the § 1 tools. A row in bold is one where the METHOD was wrong,
not the compiler.

| number | T9 published | T10 measured | |
|---|---|---|---|
| corpus green | 1637 | **1688** | |
| corpus refused | 2309 | **1967** | block 4 |
| `tests/lang` / `Zend/tests` / `strings` | 102 / 709 / 262 | **104 / 749 / 262** | |
| greens in T0's "touched by none" | 1626 of 1637 | **1663 of 1688** | |
| **the sampled `wrong` tests that "compile and differ"** | **327 of 718** | **758 of 784 that compile** | **never ran the binary** |
| **the arena** | **2 of 1572** | **11 of 782 that RAN** | **the denominator counted tests it never ran** |
| **fixtures byte for byte** | **60 of 60, merged streams** | **74 of 74, each stream and the exit code** | **`2>&1` and `$(...)`** |
| refusals named, exit 3 | 6 of 6 | 6 of 6 | |
| **the D8 tests, "in BOTH worlds"** | **6 ok / 0 failed** | **6 ok / 0 failed, both halves** | **php's half alone** |
| **the D8 bench** | **5.85x and 1.45x** | **7.27x and 1.46x** | **T9's own compiler refuses its own `main.php`** |
| assert a php diagnostic line | 93 green of 4647 | **102 green of 4647** | |
| mention `__destruct` | 14 green of 333 | **15 green of 333** | |
| `lencheck` / `aritycheck` | 468 / 272 | **496 / 272** | |

### What "compiled; output differs" really was

`why.py` never ran the binary, so every test that COMPILED was labelled
`(compiled; output differs)`. Running them, over a sample of 1352 `wrong`
tests of which **784 compile** (782 run to completion, 2 time out):

| label | count | share of the 784 |
|---|---|---|
| the output really does differ | **758** | 96.7% |
| crashed (a signal) | 23 | 2.9% |
| timed out | 2 | 0.3% |
| agrees on both: the `.phpt`'s own expectation is what the grid graded | 1 | 0.1% |
| **the output agrees and the exit code does not** | **0** | **0%** |

**The last row is a retraction, and it is T10's own.** The first version of
this document reported **143 tests (18.2%) that print exactly what php
prints and exit with a different code**, called it "the single largest
nameable group left" and recommended it as the next probe's first block.
It does not exist. It was `run_pair` handing php a RELATIVE path while
running it with `cwd` set to the test's own directory, so php answered
`Could not open input file` -- exit 1, empty stdout -- for every test in the
sample, and every mc-php run that printed nothing and exited 0 came out as
"the same output with a different exit code". The candidate ran anyway,
because its binary is an absolute `mkstemp` path. `phpt-run.py`'s own
`classify` opens with `path = os.path.abspath(path)` for exactly this
reason; `run_pair` did not, from the § 1 commit until the reviewer of #9
found the INI defect beside it and this came out with it.

So section 1 of the backlog was worked, and in working it T10 published a
new number of the same kind. What that says about the method is the useful
part: **a differential tool has to be checked against a case whose answer is
known**, and neither T10's first draft nor any probe before it did that for
`run_pair`. What survives is the shape of the correction rather than its
size -- the label `(compiled; output differs)` covered four outcomes and
covers one now, and 26 of the 784 are a crash, a timeout or a test the grid
graded on its own expectation.

### What "the arena is the answer" really was

`arena.py` turned every exception into `None` and divided by `len(files)`.
Of T10's 1352-test list, **568 do not compile and 2 time out**: a denominator
of 1352 understates by 1.7x, and the outcome it hides is the one that most
needs reporting. The line is `arena exhausted in 11 of 782 tests that RAN
(1352 in the list)`, with every other outcome on its own line and an
`assert` that nothing was dropped. The eleven are all large-string
programs -- `explode_bug`, `wordwrap_memory_limit`, `chunk_split_variation3`,
`htmlentities-utf-3` and their kind -- which is the shape D7 predicted and
T6, T7 and T8 each measured. Copy-on-write is still not built.


## Block 1: the four measurements that lie (commit `cd6b534`)

They are one tool now -- `probes/t10/harness.py`, the single definition of
"these two agree": stdout byte for byte AND the same exit code, which is the
pair `probes/t0/phpt-run.py` itself grades on. The three callers read it.

| what it said | what it was doing |
|---|---|
| `why.py` labelled a test `(compiled; output differs)` | it never ran the binary. Every "output differs" count published since T5 meant **"compiled"** |
| `diffgroup.py` grouped a pair as agreeing | it compared stdout only, while the grid counts an exit-code mismatch as `wrong` |
| `arena.py`: "11 of 1396 exhaust the arena" | every exception -- a compile failure, a timeout -- became `None`, and the denominator was still `len(files)` |
| `fixtures.sh`: "byte for byte on both streams" | `2>&1` merged them, and `$(...)` strips every trailing newline |
| `bench/bench.sh` in t7 and t8 | built and timed **t6's** compiler, runtime and fixture |
| `run.sh` reading `T6_JOBS` in t7 and t8 | the documented knob was dead |
| `<test>.why.php` written beside the input | it CLOBBERED a sibling of that name and then deleted it |

`harness.sibling()` creates the scratch file `O_CREAT|O_EXCL`, tries a
counter, gives up after 64 rather than destroy a stranger's file, and never
removes one it did not create.

## Block 1b: the grid's disk cost, which the section did not name

The full-corpus grid filled a **460 GiB boot volume** at about 20000 of 21395
tests and was killed at ENOSPC. The sweeper and the trap already in the tree
answered neither of its two mechanisms.

* **The peak.** `mcphp.sh` EXECs the binary it compiled -- it must, or
  python's timeout kills the shell and leaves the program spinning -- so it
  cannot delete it. The sweeper collected a file only once its mtime was a
  minute old and woke every 20 s, so about 3000 binaries of ~2 MB were live
  at once. The fix belongs to the CALLER, which is the process that WAITS:
  `mcphp.sh` honours `MCPHP_OUT` and `probes/t0/phpt-run.py` names the file
  and unlinks it the moment the subprocess returns. (`harness.py` already did
  this, so `why.py`, `diffgroup.py` and `arena.py` were already bounded.)
* **The orphans**, and this is where the tens of gigabytes came from. The
  directory carries the pid, so a run killed with SIGKILL left its whole
  directory and no later run collected it. `mcphp_tmp_init` sweeps the
  siblings whose pid is gone, at startup.

`probes/t10/tmp.sh` is the one definition of both, and the sweeper samples
the directory and keeps the maximum so the claim carries a number.

| | tmp peak | disk before | disk after |
|---|---|---|---|
| 6333 tests (three directories) | **1860 KiB** | 212Gi free | 212Gi free |
| 27728 tests (three directories and the corpus, one run) | **1860 KiB** | 212Gi free | 212Gi free |

**The grid's disk cost is bounded by the job count, not by the corpus size**:
4.4x the tests, the same peak to the kilobyte. 4184 orphaned binaries (665 MB)
from the killed run were swept before any of this was measured.

`fixtures.sh` set no `MCPHP_TMP` at all, so every fixture run leaked its
binary into `$TMPDIR` for ever; it uses the shared helper now and removes the
binary per fixture. It also bounds each fixture with an alarm -- one of the
new ones loops for ever when the compiler is wrong, and it hung the gate with
no output at all until it was killed by hand.

## Block 2: the semantics a program can observe

Twenty-two lines. Seventeen are fixed in the compiler and closed by a
FIXTURE -- a `.php` run under `php` and under mc-php and compared byte for
byte on stdout, stderr AND the exit code -- five were already true and are
closed by measurement, and one sub-case is refused with its number. The
per-line table is `docs/review-backlog.md` § 2; what is worth keeping here is
the shape of the two that were not one-liners and the two finds that were not
on the list at all.

* **Short circuit is not one `if`.** The right operand of `&&`, `||`, `??`
  and `?:` carries PENDING STATEMENTS of its own -- an array literal is a run
  of inserts -- and those have to move inside the branch with it. Lowering
  only the operand and leaving its construction outside evaluates half of
  what php does not evaluate at all. `g/61`.
* **By value is the CALLEE's job.** Putting the copy at the call site means
  every call road -- direct, forward, closure, method -- has to remember it.
  It is in the prologue (`ph_byval`), so there is one place and a
  by-reference parameter is the only thing that skips it. `g/62`.

### The find that was not on the list: `ph_cast(TY_U8, <pointer>)`

`(u8) x` in this compiler keeps the **low byte**, so `if ((u8) zval_ptr)` is
**false for every address that happens to end in `0x00`**. It silently
skipped the by-value copy above, and -- pre-existing since T9 --
`func_num_args`'s own counter, depending on nothing but where the arena
landed: two class methods rather than one or three was enough to arrange it.
There is no diagnostic and no test that fails reproducibly; it moves with
the size of the program.

`ph_truthy(n)` -- `!!n`, mc's own 64-bit test, twice -- replaces both, and
the comment above it in `probes/t10/php.mc` says why. **Anything in this
compiler that asks "is this pointer non-null" must use it.**

### The find the last fixture made: `do { } while (cond)`

`while` and `for` take the condition's own statements with `ph_take_pend` and
splice them into the loop body; `do` did not. So the unwinding check that
`ph_cond_checked` pends landed BEFORE the loop, and
`do { ... } while (t());` with a throwing `t()` spun for ever. It is what
killed the first run of `g/64` and it is why `fixtures.sh` bounds a fixture
now.

### Refused with its number

`"${x}"` does not interpolate. php 8.2 DEPRECATED the form, so matching it
means emitting php's own `Deprecated: Using ${var} in strings is deprecated`
on both streams as well as interpolating, and it is worth **13 tests of the
three graded directories and 14 of the whole corpus**
(`grep -lE '"[^"]*\$\{[A-Za-z_]'`). It is removed in php 9. Everything else
`ph_dq_read` was accused of is reached: mc 1.1.0's `p_skip_to` gives the
module the `"..."` token, so `"$x"`, `"{$x}"`, `"$a[k]"` and `"{$a['k']}"`
all agree with php.

## Block 3: D8 over the fixtures -- the exemption is a script

D8's text covers "fixtures, any part of the runtime or standard library
written in PHP, examples", and the `.php` under `probes/*/g` and
`probes/*/r` carried neither a PHPUnit class nor a bench row. The reason they
are exempt is now in `docs/plan.md` D8 (c): **the unit D8 governs is the
PROGRAM, and a differential fixture is not one -- it is already a test, and a
stronger one.** Its oracle is the reference implementation rather than a
value someone typed into an `assertSame`, it grades both streams and the exit
code, and it runs in both worlds by construction. It carries no bench row
because a three-line program measures process start-up and nothing else (T9
measured php paying ~38 ms before the first statement, against a whole
`main.php` of 39.5 ms).

A probe cannot waive a rule for itself, so the exemption is D8 (d):
`probes/t10/d8check.py`, step 0 of `run.sh`. Every `.php` under the probe
goes into exactly one of four regimes -- `fixture` (matched by the two globs
`fixtures.sh` ACTUALLY walks, read out of the script, so a third directory
cannot be added silently), `instrument` (the `TestCase` shim, the test class,
the runner that names the methods: the mechanism of D8 (a), which cannot test
itself), `library` (required BY the test class AND BY a bench program) and
`bench` (a row in `bench10.sh`, which refuses to time a program until php and
mc-php print the same answer) -- and a file in none of them fails the run.

It found one on its first run: `probes/t10/bench/unwind.php`, T6's exception
bench, copied forward twice and referenced by nothing -- no test, no bench
row, no caller. Deleted; T6's original is untouched and still reproduces.

## Block 4: D8's mc-php half had NEVER run, under any probe

Step 10 of `run.sh` printed `tests: 6 ok / 0 failed` and T9 reported it as
"in BOTH worlds". Step 11 printed two bench ratios. **Both were php's side
alone**, and it took running the step with its stderr visible to see it: the
step piped each half to `tail -1` with nothing behind them, so the mc-php
half's refusal went to stderr and its stdout was empty.

Two compiler defects behind it.

* **`require __DIR__ . "/x.php"` was refused** as "an include of a computed
  path" (D1). It is not one: `__DIR__` is a compile-time constant and the
  concatenation of two literals is a literal, so the path is known while
  compiling, which is the whole of what D1 is about -- and it is php-src's
  own spelling, which every probe's `bench/run.php` and `bench/main.php`
  opens with. Measured on T9's own tree: `probes/t9/mc-php` refuses
  `probes/t9/bench/main.php`, so T9's two bench ratios cannot be reproduced
  either. Nothing else is folded; a variable, a call or an interpolation is
  still refused by name. `g/72`.
* **A top-level `return` returned from the generated `main`**, jumping over
  `php_shutdown`, `php_flush` and the exit code. The program printed NOTHING
  and exited with a junk status -- **54, 82, 94, 142 and 178 on five runs of
  the same source** -- because the output buffer was never written. In the
  ENTRY file it is php's `exit` exactly now (shutdown functions, then
  destructors, then the flush, status 0 -- a value returned there does not
  set it); in an INCLUDED file php ends the include and the CALLER CONTINUES,
  which an inlined include cannot express, so that is refused by name rather
  than answered wrongly. `g/73`.

`probes/t10/bench/shim.php` depended on the second: it guarded its
declarations with `if (class_exists(...)) { return; }`, which is correct
under php only because php had already HOISTED the unconditional class above
it. It is a conditional declaration now -- a class inside an `if` is not
hoisted and is declared when the branch runs, php's own idiom -- so it needs
no top-level return at all.

Step 10 is GATED: both lines are printed, both are required, and they have to
agree.

```
  php     tests: 6 ok / 0 failed
  mc-php  tests: 6 ok / 0 failed        <- the first time, in any probe
```

## The tables that choose the next block

A sample of **1352** `wrong` tests -- every one under `tests/lang` and
`ext/standard/tests/strings`, plus the first 900 of `Zend/tests` -- run
beside php. **568 do not compile and 784 compile**, and 568 + 784 is the
sample exactly. (T10's first draft of this section said 737, which was
`nocompile.py` counting every compiled outcome it did not have in its skip
list; the reviewer of #9 caught it, and 568 is now the same number the arena
section reports from the other side.)

The block that does not compile, by the compiler's own message:

```
    56  expected ; after a php expression        (returnByReference, foreach
    54  mc-php: <a named limit>                   over an IteratorAggregate)
    31  PHP Fatal error                          (asymmetric visibility)
    30  expected ; after a php property          (property hooks)
    29  expected ) in a php call                 (passByReference)
    23  expected ; after a php assignment
    17  a reference to a php variable of type    (array 7, object 4)
    15  a php function ... : spl_autoload_register
    14  ... crypt          12  a reference &$x
    11  expected = after a php array index
    10  a php file that does not open with <?php (leading inline html)
```

and the 758 that compile and really do print something else, by the shape of
the first differing line:

```
   332  var_dump of a value
   173  a php diagnostic
   129  a blank line       (one side printed a banner the other did not:
    84  other text          the program died before it, or after)
    16  a float        11  an integer        9  print_r of a container
     2  var_export of an element    1  print_r of an element
     1  a container delimiter
```

**The head is still flat**, as T9 left it: the largest single
first-difference PAIR is worth 26 (`php 'int(N)' / mc ''` -- mc-php printed
nothing where php printed a value) and the next 20 (`php 'array(N) {' / mc
''`). What is left in the graded directories is a bounded feature with a
name -- property hooks (30), asymmetric visibility (31), references
(29 + 17 + 12), generators (§ below, unchanged from T9) -- or a long tail of
one function each.

**The group worth naming is `var_dump of a value`, 332 of the 758**, and its
head says what it is: php prints a value and mc-php prints nothing, which is
a program that stopped early rather than a value formatted wrongly. That,
and the 23 that CRASH, is what the next probe should take first.

## D7, re-measured

`probes/t10/arena.py` over the 1352-test list: **11 of the 782 that RAN**.
The table above says why that is not comparable with T9's "2 of 1572" as a
rate -- T9's denominator counted 570 tests that never ran -- but the tests
themselves are the same shape they have been since T6: eleven programs that
build a very large string on purpose. Nothing new, and copy-on-write is
still not built.

## The two sub-populations

| population | T7 | T8 | T9 | T10 |
|---|---|---|---|---|
| assert a `Warning:`/`Deprecated:`/`Notice:`/`Fatal error:` line (4647) | 71 | 83 | 93 | **102** |
| mention `__destruct` (333) | 11 | 14 | 14 | **15** |

Neither was a target.

## D8: the tests and the bench, both halves, for the first time

```
  php     tests: 6 ok / 0 failed
  mc-php  tests: 6 ok / 0 failed

  == main.php ==   both answer 13608   the binary is 314354 bytes
    php 0.0396 s   mc-php 0.0054 s   php -r (start-up) 0.0392 s
    php / mc-php = 7.27x        php WORK / mc-php = 0.08x
  == heavy.php ==  both answer 99450
    php 0.0429 s   mc-php 0.0294 s   php -r (start-up) 0.0421 s
    php / mc-php = 1.46x        php WORK / mc-php = 0.03x
```

The two ratios measure different things and both are honest: mc-php wins the
whole program because php pays ~39 ms of start-up before the first
statement, and LOSES the work by more than an order of magnitude. D7 names
the cause (no refcount, so a php array is copied EAGERLY at every hand-over)
and T10 does not dispute it. T9 published 5.85x and 1.45x for the same two
programs; its own compiler cannot compile either of them, so where those
numbers came from is not recoverable -- these are measured with both halves
running and `bench10.sh` refusing to time a pair that does not agree.

## Invariants

* `probes/t10/g/` -- **74 of 74** fixtures byte for byte php's, on stdout,
  stderr and the exit code, each stream graded separately.
* `probes/t10/r/` -- **6 of 6** refusals named, exit 3.
* `lencheck` **496 literal lengths, 0 wrong**; `aritycheck` **272 library
  rows, 0 wrong**.
* `d8check` -- **80 fixture / 3 instrument / 1 library / 2 bench**, 86 `.php`,
  every one in a regime with its obligation, and every `test*` the class
  declares named by the runner (6 of 6).
* the grid's tmp peak **1860 KiB over 27728 tests**; `df -h /` identical
  before and after.
* `probes/t9/` untouched.

## Cost

`probes/t10/php.mc` 7177 -> 7821 lines, `probes/t10/php_rt.txt` 8780 -> 8977.
**No new external name.** Everything the four blocks needed was already
called by `php.mc`: the same 58 T9 listed -- 48 frozen, four core intrinsics
(`ld8`/`ld64`/`st8`/`st64`), three `<float>`'s, and three libc (`write`,
`exit`, `realpath`).

## mc gaps

**No new one.** The one T5 reported is unchanged and T10 hits it exactly as
often: **10 of the sampled tests** (38 of the 21219 `.phpt` with a `--FILE--`
section over the whole corpus) open with inline HTML and are refused by name,
because nothing can own the bytes before the FIRST token.

Two things worth writing down for the next probe, neither of them mc's:

* **`ph_cast(TY_U8, <pointer>)` keeps the low byte.** `if ((u8) p)` is false
  for every address ending in `0x00`. Use `ph_truthy(p)`. It cost an
  afternoon and it has no reproducible failure: it moves with the size of the
  program.
* **A condition's PENDING statements belong to the loop, not to the
  statement around it.** `while` and `for` take them with `ph_take_pend`;
  `do` did not, and a throwing condition made it spin for ever.

## Two divergences observed and NOT fixed, with their numbers

* `"${x}"` does not interpolate -- deprecated in php 8.2, removed in php 9,
  worth 13 tests of the three graded directories and 14 of the corpus.
* `intdiv(PHP_INT_MIN, -1)` answers `-9223372036854775808` where php throws
  `ArithmeticError`, and a throwable's `getFile()` is the path as WRITTEN
  where php's is the path it RESOLVED (visible only under a symlinked
  `$TMPDIR`; no `.phpt` runs there). Neither is in the backlog; both are
  recorded here so the next probe does not have to find them again.

## The reviewer of this probe's own pull request (#9)

The standing rule of `docs/review-backlog.md` § 3 -- a pull request is not
merged before its findings are read -- applied to T10 itself. Twelve inline
findings, **every one real**, listed with their fix in `docs/review-backlog.md`
§ 4. Six needed code, and two of those are worth repeating here because they
are the same family the probe is about:

* **A top-level `return` inside a `try`/`finally` took the exit and jumped
  over the finally.** The cause was ONE guard: `if (!ph_toplevel)` around
  the allocation of the deferred-return flag, so at the top level the flag a
  `return` raised was read by nobody -- and the epilogue that consumes it
  carried the same guard, so the script simply carried on past the try. The
  VALUE local still exists only inside a function, because php ignores what
  a top-level return returns. `g/74-toplevel-return-finally.php`.
* **`harness.py` ran the CANDIDATE before the oracle**, in the test's own
  directory, and ignored `--ARGS--`, `--STDIN--`, `--ENV--` and `--INI--`
  while the grid passes all four. So a `.phpt` that writes a file beside
  itself contaminated the ORACLE, and a test with a section could be
  measured as a DIFFERENT program. php runs first now -- the grid's own
  order -- and the sections come from the grid's own `parse_phpt`, imported
  rather than copied.

And **`nocompile.py`'s skip list named one compiled outcome of five**, so the
other four were counted as tests that do not compile: the block was published
as **737** and is **568**, which is now the same number the arena section
reports from the other side. It is the one place where T10 published a
number with the same defect it was written to remove, and the reviewer is
what caught it.

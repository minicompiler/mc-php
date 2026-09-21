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

`probes/t9/` is left as it was but for one deletion, and it is on purpose:
`probes/t9/bench/unwind.php` was an orphan copied forward from T6 that no
gate ran, which `d8check.py` found; T7's and T8's copies went with it and
T6's original is untouched. Nothing else under `probes/t9/` was changed. Every measurement here was taken
against a SNAPSHOT of the compiler (`probes/t10/grid.sh`,
`probes/t10/fixtures.sh`), which is T7's own note: the first baseline there
measured a binary that was being rebuilt underneath it.

## Answer: green 1637 -> 1689

| grid | green | wrong | refused | skip | php-fail | total | T9's green |
|---|---|---|---|---|---|---|---|
| `tests/lang` | **104** | 141 | 36 | 12 | 1 | 293 | 102 |
| `Zend/tests` | **749** | 3754 | 691 | 112 | 6 | 5306 | 709 |
| `ext/standard/tests/strings` | **263** | 310 | 107 | 54 | 0 | 734 | 262 |
| the whole corpus | **1689** | 14469 | 1929 | 2947 | 361 | 21034 | 1637 |

Re-run three times more, same snapshot discipline, `T10_JOBS=6`. After the
round-twenty compiler change (`php_param_coerce_ref`, the Traversable limit
and the slot check scoped to this compiler's own buffer) the corpus is
**green 1689 / wrong 14489 / refused 1929 / skip 2947 / php-fail 341 / total
21054** with the directories identical again -- and the green set is
**test for test the published one**: `comm` gives 0 lost and 0 gained against
the after-grid's own 1689. The remaining difference from it is the 20 tests
that left `php-fail` when the tree was cleaned. Peak 1908 KiB, `df -h /` 12Gi
used and 212Gi available before and after.

After the round-nineteen compiler change (`php_unpack_check` and the declared type on a
parameter with a default) the three directories are **identical** again --
104 / 749 / 263 -- and the corpus is **green 1688 / wrong 14489 / refused 1929
/ skip 2947 / php-fail 342 / total 21053**. Two deltas against the published
run, both named: **one green lost**, `ext/standard/tests/file/is_dir_basic`,
one of the band's own twelve; and **20 tests left `php-fail` for `wrong`**,
because the source tree was cleaned of the leftovers the pre-CLEAN harness had
made -- dba, phar and `spl/DirectoryIterator_getInode_basic` and their kind,
whose ORACLE had been failing its own expectation on a stale file. That is the
round-eighteen contamination finding measured from the other side: it was
costing the grid 20 tests of its denominator. Peak 1908 KiB, `df -h /` 12Gi
used and 212Gi available before and after.

After the round-seventeen change (the spread's compute-then-check boundary): the
three directories are **identical** -- 104 / 749 / 263 -- and the corpus is
**green 1677 / wrong 14481 / refused 1929 / skip 2947 / php-fail 361 / total
21034**. The 12 greens between the two runs are named rather than assumed:
`comm` over the two green sets gives **12 lost, 0 gained**, and all twelve are
the filesystem tests of the band below (`dir/chdir_basic`, `dir/getcwd_basic`,
`file/is_dir_basic`, `file/rename_variation1` and nine of their kind). Not one
of them contains a `...`, so the fix is isolated from the band. Disk: `df -h /`
reports **12Gi used, 212Gi available before AND after**, tmp peak **2152 KiB**
over the whole 21395-test run.

**The corpus number carries a band of about +/- 12, and it was MEASURED.**
The backlog says the grid is what is not in question; nobody had run it
twice. Two runs of one binary, earlier in this pull request, gave **1676 and
1688** -- and the 1676 set is a strict SUBSET of the 1688 set -- 0 tests green in A and not in B, 12 the other way -- and all
twelve are filesystem tests: **9 under `ext/standard/tests/file`, 3 under
`ext/standard/tests/dir`** (`chdir_basic`, `getcwd_basic`, `is_dir_basic`,
`is_file_basic`, `rename_variation1`, `file_get_contents_variation7` and
their kind). They `chdir()` and write files in a shared working directory
while the grid runs SIX of them at once, so they interfere with each other
and not with the compiler. `php-fail` moves with them (361 / 360), which is
php's own side doing the same thing.

So **the corpus green carries about +/- 12, and the three directory numbers
do not**: `tests/lang` 104 and `Zend/tests` 749 came out identical on five
separate runs across four compilers, and `strings` moved 262 -> 263 exactly
once, for round ten's `sscanf` fix. A per-block move smaller than a dozen
tests should be read on the directories, and the corpus number is worth
quoting with its band -- which no probe has done, T9's 1637 and T8's 1450
included.

`refused` fell **2309 -> 1929** over the corpus and **725 -> 691** under
`Zend/tests`, and that is one block: `require __DIR__ . "/x.php"` and a
top-level `return` were refusals and are not any more (block 4). `wrong`
rose with it, because a test that now COMPILES gets far enough to print
something that can disagree.

**1664 of the 1689 greens are in T0's "touched by none" set** -- the 84.2% of the corpus none of § 3's decisions touches --
against T9's 1626 of 1637.

T9's line on the same corpus and harness:
`green 1637 / wrong 14140 / refused 2309 / skip 2947 / php-fail 362 / total 21033`.
T8's: `green 1450`. T7's: `green 1218`. T6's: `green 1073`. T5's: `green 80`.
T0's, before any compiler existed: `green 0`.

The green moved **+52 on a block of pure CORRECTNESS work**, which is
the smallest per-block move of any probe so far and is the expected shape:
§ 2 of the backlog fixes what a program OBSERVES, not what it can express,
and a `.phpt` that was already green does not become greener for being right
about short circuit. The two numbers to read are `refused`, down 342, and
this:

## Every number T9 published, re-measured

The first column is what `probes/t9/RESULTS.md` says. The second is this
tree, with the § 1 tools. A row in bold is one where the METHOD was wrong,
not the compiler.

| number | T9 published | T10 measured | |
|---|---|---|---|
| corpus green | 1637 | **1689** (band +/- 12, measured) | |
| corpus refused | 2309 | **1929** | blocks 4 and the review rounds |
| `tests/lang` / `Zend/tests` / `strings` | 102 / 709 / 262 | **104 / 749 / 263** | |
| greens in T0's "touched by none" | 1626 of 1637 | **1664 of 1689** | |
| **the sampled `wrong` tests that "compile and differ"** | **327 of 718** | **788 of the 812 that compile** | **never ran the binary** |
| **the arena** | **2 of 1572** | **11 of 779 that RAN** | **the denominator counted tests it never ran** |
| **fixtures byte for byte** | **60 of 60, merged streams** | **80 of 80, each stream and the exit code** | **`2>&1` and `$(...)`** |
| refusals named, exit 3 | 6 of 6 | 6 of 6 | |
| **the D8 tests, "in BOTH worlds"** | **6 ok / 0 failed** | **6 ok / 0 failed, both halves** | **php's half alone** |
| **the D8 bench** | **5.85x and 1.45x** | **6.73x and 1.41x**, from the committed dated record | **T9's own compiler refuses its own `main.php`** |
| assert a php diagnostic line | 93 green of 4647 | **102 green of 4647** | |
| mention `__destruct` | 14 green of 333 | **15 green of 333** | |
| `lencheck` / `aritycheck` | 468 / 272 | **501 / 272** | |

### What "compiled; output differs" really was

`why.py` never ran the binary, so every test that COMPILED was labelled
`(compiled; output differs)`. (And a php COMPILE-TIME fatal -- exit 255,
which `mcphp.sh` passes through and the grid compares -- was collapsed into
"does not compile" until the review of #9 caught it, which is why the block
that does not compile fell 570 -> **539** and the block that compiles rose
781 -> **812**: those 31 are tests the grid had been grading on their
output all along.) Running them, over a sample of 1351 `wrong`
tests of which **812 compile** (810 run to completion, 2 time out):

| label | count | share of the 812 |
|---|---|---|
| the output really does differ | **788** | 97.0% |
| crashed (a signal) | 22 | 2.7% |
| timed out | 2 | 0.2% |

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
covers one now, and 24 of the 812 are a crash, a timeout or a test the grid
graded on its own expectation.

### What "the arena is the answer" really was

`arena.py` turned every exception into `None` and divided by `len(files)`.
Of T10's 1351-test list, **539 do not compile, 31 are a php COMPILE-TIME
fatal and 2 time out**: a denominator of 1351 understates by 1.7x, and the
outcome it hides is the one that most needs reporting. (The 31 came out of
the denominator in round twenty-five, and they are the same distinction:
`run_pair` calls a compile-time fatal `ran`, because the GRID grades that
pair on its output, but no binary was executed and searching the COMPILER's
stderr for `arena exhausted` asks about a different arena than D7's.) The line is `arena exhausted in 11 of 779 tests that RAN
(1351 in the list)`, with every other outcome on its own line and an
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

`harness.sibling()` creates the scratch file `O_CREAT|O_EXCL` and never
removes one it did not create. Since round six of the review it uses the
CANONICAL `<base>.php` -- the name `probes/t0/phpt-run.py` itself gives the
test, so `__FILE__` and anything derived from it are what the grid graded --
and there is NO fallback name: a name that is taken is skipped and counted
(`busy`), which over the 1351-test sample is 0 tests.

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
| 27728 tests (three directories and the corpus, one run) | **1908 KiB** | 212Gi free | 212Gi free |
| 27728 tests again, the round-seventeen re-run | **2152 KiB** | 212Gi free | 212Gi free |

**The grid's disk cost is bounded by the job count, not by the corpus size**:
4.4x the tests for a 2.6% larger peak, over six runs, and **2152 KiB** on the
seventh -- a 13% band on a 2 MB number, where the corpus it measures varies by
4.4x. Every other figure in this repository is one of these three rows, and
where a document quotes one it now says which. 4184 orphaned binaries (665 MB)
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
closed by measurement, and one sub-case is NOT built and is recorded with its number as a divergence. The
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

### NOT built, and recorded rather than refused

`"${x}"` does not interpolate: mc-php prints the five characters and says
nothing. It is **not** a named refusal, which the first version of this
document claimed -- `${` is not a variable-name byte, so `ph_dq_read` emits
them literally and never reaches `ph_refuse`, and the reviewer of #9 is what
caught the claim. php 8.2 DEPRECATED the form, so matching it
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
  mc-php  tests: 6 ok / 0 failed
  6 test* methods declared; php ran 6, mc-php ran 6, and the two outputs
  are byte for byte the same

  == main.php ==   both answer 13608   the binary is 314594 bytes
    php 0.0774 s   mc-php 0.0115 s   php -r (start-up) 0.0764 s
    php / mc-php = 6.73x        php WORK / mc-php = 0.09x
  == heavy.php ==  both answer 99450
    php 0.0754 s   mc-php 0.0534 s   php -r (start-up) 0.0772 s
    php / mc-php = 1.41x        php WORK / mc-php = 0.00x
```

**Those four numbers are read out of the committed record**,
`probes/t10/bench/results/2026-09-21.json`, which D8 (b) asks for and which
`bench10.sh` writes on every run (`time2.py` writes the object itself, so
nothing re-parses a printed line). The reviewer of #9 caught the report
quoting a LATER run than the one committed -- 7.43x and 1.42x against the
record's 6.73x and 1.41x -- and that is why the record exists: a bench
number in prose has nowhere to be checked against. The machine was loaded
when this one was taken (php's own start-up is 77 ms here against 38 ms in
T9's), which is exactly the kind of thing a dated record makes visible. The
record carries the php runtime configuration the ratio depends on as well --
`opcache` loaded-off-cli, `jit` disable, `jit_buffer` 64M -- which D8 (b) asks for and the
first version of it did not have: a record that says only the version cannot
be compared with one taken on a host that had opcache on.

The two ratios measure different things and both are honest: mc-php wins the
whole program because php pays ~39 ms of start-up before the first
statement, and LOSES the work by more than an order of magnitude. D7 names
the cause (no refcount, so a php array is copied EAGERLY at every hand-over)
and T10 does not dispute it. T9 published 5.85x and 1.45x for the same two
programs; its own compiler cannot compile either of them, so where those
numbers came from is not recoverable -- these are measured with both halves
running and `bench10.sh` refusing to time a pair that does not agree.

## Invariants

* `probes/t10/g/` -- **80 of 80** numbered fixtures byte for byte php's, on stdout,
  stderr and the exit code, each stream graded separately.
* `probes/t10/r/` -- **6 of 6** parse under `php -l` and are refused by
  mc-php with a named message, exit 3. That pair IS the differential for a
  refusal fixture, and `d8check.py` gives `r/` a regime of its own for it:
  an `r/` file is not a byte-for-byte pair, because the point of it is that
  mc-php declines what php accepts.
* `lencheck` **501 literal lengths, 0 wrong**; `aritycheck` **272 library
  rows, 0 wrong**.
* `d8check` -- **80 fixture / 6 refusal / 1 helper / 3 instrument / 1 library / 2 bench**, 93 `.php`,
  and the repo-wide sweep over **361** `.php` under `probes/`,
  every one in a regime with its obligation, and every `test*` the class
  declares named by the runner (6 of 6).
* the grid's tmp peak **1908 KiB over 27728 tests** on the round-nineteen run
  (2152 KiB on the round-seventeen one, 1908 the largest of the six before it);
  `df -h /` identical
  before and after.
* `probes/t9/` untouched.

## Cost

`probes/t10/php.mc` 7177 -> 7933 lines, `probes/t10/php_rt.txt` 8780 -> 9032.
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

* `"${x}"` does not interpolate and is not diagnosed: mc-php prints the five
  characters. Deprecated in php 8.2, removed in php 9, worth 13 tests of the
  three graded directories and 14 of the corpus.
* **Two `...` spreads in one call answer the wrong thing**, and a third is
  now a named refusal rather than a buffer overrun. `max(...[1,2], ...[3,9])`
  is **2** where php says 9; one spread (`max(...[1,2,3,9])`) is right. Found
  by the reviewer of #9 as an OVERRUN -- each spread appended up to `nsp`
  slots without looking at `n`, so a second or third wrote past the
  `maxn + 1 + PH_SPREADN` buffer and corrupted the compiler instead of
  reaching a diagnostic. The overrun is fixed here (a bound before every
  spread store); the wrong ANSWER for two spreads is older, is a different
  bug in how the slots are filled, and is left with its reproducer. A THIRD
  defect on the same path, found by the same reviewer on its seventeenth
  pass, IS fixed: a spread whose expression throws had no compute-then-check
  boundary, so `f(...boom())` ran `php_unpack_at` and then the callee's body
  with the exception pending -- `g/77-spread-throw.php` printed `body`
  before `caught boom` against a compiler built from the commit before.
  Six lines give the spread what the ordinary argument path already had.
* A closure registered with `register_shutdown_function` does not get its
  DEFAULT parameter values: `function ($a = 'x')` sees null. The argument
  COUNT is right now (the row records it and `php_shutdown` passes it, the
  reviewer of #9's finding), but a closure called through `php_call_zv` does
  not apply its own defaults -- a separate gap, in the call path and not in
  the shutdown list. `register_shutdown_function('name')` with a STRING
  callback does not fire at all; that is older than T10 and unchanged by it.
* **A declared parameter type that is not one of the five primitives is not
  checked.** `?int`, a union, a class name, `callable`, `object` and
  `iterable` all collapse to `PT_MIXED` in `ph_type_word`, so the name is gone
  before the prologue is built: `function n(?int $x)` accepts `"abc"` and
  `function c(C $o)` accepts `5`, where php raises a TypeError for both. The
  five primitives ARE checked, including on a parameter with a default and on
  one a forward call fixed (round nineteen). Carrying the declared name to the
  prologue and testing it with an `instanceof` is feature work, not a guard;
  its size is **493 `.phpt` of the corpus** that declare one.
* **A spread of more than 16 values is a named runtime failure**, not a wrong
  answer and not a php error: `f(...range(1, 20))` answered 16 before round
  nineteen and now prints `mc-php: a spread of more than 16 values is not
  implemented yet` and exits 255. The compiler emits a fixed number of slots
  and cannot see the array's length, so an unbounded variadic path needs a
  call convention the fixed `MAXPARAMS` frame does not have -- a block for a
  later probe, and until then the limit says so instead of losing values.
* `intdiv(PHP_INT_MIN, -1)` answers `-9223372036854775808` where php throws
  `ArithmeticError`, and a throwable's `getFile()` is the path as WRITTEN
  where php's is the path it RESOLVED (visible only under a symlinked
  `$TMPDIR`; no `.phpt` runs there). Neither is in the backlog; both are
  recorded here so the next probe does not have to find them again.

## The reviewer of this probe's own pull request (#9)

The standing rule of `docs/review-backlog.md` § 3 -- a pull request is not
merged before its findings are read -- applied to T10 itself. **Seventeen
rounds and 59 findings**, listed one by one with their fix, their measurement
or their refutation in `docs/review-backlog.md` § 4. The first twelve were
inline and every one was real. Six needed code, and two of those are worth repeating here because they
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
as **737** and is **539**, which is now the same number the arena section
reports from the other side. It is the one place where T10 published a
number with the same defect it was written to remove, and the reviewer is
what caught it.

Three of the seventeen rounds are worth naming because of what they say about
the method rather than the code. **Round fourteen** caught `run_pair` handing
php a relative path, which is what retracted this probe's own headline (§ 69).
**Round sixteen** caught the committed dated bench record disagreeing with
every number quoted beside it -- the exact failure D8 (b) asks for a dated
record to prevent -- and the four numbers are read out of that file now.
**Round seventeen** raised fourteen findings in code that had not changed
since the round before, of which **thirteen were real** and one, a claim that
macOS `find` has no `-maxdepth`, is refuted by one command on this host. Of
the thirteen, two moved no number and say so with the count behind it: the
corpus has **2** `EXPECT*_EXTERNAL` tests and neither asserts a diagnostic, and
the published `why.tsv` has **0** rows in the statuses `nocompile.py` was
miscounting. That is the useful shape -- a tool can be wrong and its answer
right, and only the measurement tells you which.

**Round eighteen** found the two that matter most for anything measured after
this probe, both in `harness.py`: it never ran a test's `--CLEAN--` section,
and it compiled with the analysis process's own environment and working
directory rather than the grid's. The first is measured in both directions --
`run_pair` on `ext/standard/tests/file/005_basic.phpt` left `005_basic` and
`005_basic.tmp` in the source tree before the fix and leaves nothing after it.
It also caught `bench10.sh` truncating the dated record before it had measured
anything, so any failure destroyed the previous valid one: the record is built
in `$tmp`, parsed, and moved into place only on success.

**Round nineteen** was the first to find the compiler wrong in a way no
fixture had: a runtime spread of more than sixteen values silently lost the
rest, `f(...1)` called the callee with nothing where php raises before
entering it, and a declared `int` stopped being checked the moment the
parameter had a default. The first is now a named limit, the other two are
byte-identical to php, and `g/78-spread-and-types.php` holds all three with
the five primitives, a forward call and a variadic beside them. It also asked
for the probe's own contract to be checkable rather than asserted, so
`run.sh` ends on `T10: <green> / <total>` read off the grid's summary line.

**Round twenty-one** was all scripts, and two of its nine are worth keeping:
`tmp.sh` would have deleted a LIVE run's directory once it was a day old --
a corpus grid takes an hour, and a slow one would have lost its binaries
mid-measurement -- so the owner writes its start time and the sweep compares
it rather than trusting a pid; and `mcphp.sh` let the compiler keep running
when the wrapper was killed, which is exactly the orphan the disk bound
exists to prevent. Three signal traps cleaned up and RETURNED, so an
interrupted run continued with its temporary directory gone; they exit now,
measured.

**Round twenty-two** sharpened the same point twice. The grid does not ask
"is this php's output", it asks "does this satisfy the test's own
expectation" -- an `--EXPECTF--` pattern greens a candidate that does not
reproduce php's bytes -- so `harness.agrees` is `output_matches` over the
parsed sections now, and `why.py` and `diffgroup.py` ask that same function.
It moves nothing here, for a reason worth keeping: this sample is the grid's
`wrong` bucket, where `output_matches` is false by construction. And a
SIGKILL runs no trap, so round twenty-one's compiler-child fix could not
cover the timeout that actually happens: the candidate is started in its own
process group and the group is what the timeout kills -- measured at 1
surviving compiler before and 0 after.

**Round twenty-three** put `harness.py`'s own four subprocesses behind one
group-aware runner -- `base_environment` sets `TEST_PHP_EXECUTABLE` so a
.phpt CAN spawn a nested php, and the compiler is a child too -- and refuted
one finding with a measurement (`kill -9, $p` is how perl spells the process
group, and a grandchild `sleep 30` is gone after the alarm). One is recorded
rather than fixed: **`run_pair` does not run `--SKIPIF--`**, because the grid
runs that section to decide whether to run the test AT ALL and a test it
skips never reaches these tools -- `wrong.txt` and `skip.txt` are disjoint by
construction. The real case is a SKIPIF with a side effect, which no test in
this sample has, and reproducing it here would mean reproducing the skip
DECISION as well.

**Round twenty-four** found the sharpest defect of the last few rounds in a
sentence the reviewer did not file as a finding: a typed by-reference
coercion that FAILS raised and answered null, and round twenty's write-back
stored that null into the caller's own variable before the exception
unwound. php leaves the variable exactly as it was. `g/80-byref-typed.php`.

**Round twenty-five** moved a published number for the fourth time in this
review, and by the same kind of distinction: a php compile-time fatal is a
pair the GRID grades on its output and a test that never ran a binary, so
the arena's denominator had 31 of them in it. `11 of 810` is **`11 of 779`**;
the eleven are the same eleven. It also found that `WorkloadTest`'s
equal-score branch had never executed -- 7919 modulo 1000 has period 1000,
so 40 records have 40 distinct scores -- which is a test that passed without
testing what it is named after.

**Round twenty-six** closed three holes that no measurement had fallen
through yet: the pre-D8 exemption was by DIRECTORY, so a new orphan in
`probes/t0` would have passed the repository-wide sweep (it is a snapshot of
59 named files now, and a name that leaves the disk is reported too); a
killed run's scratch `.php` made every later run call that test `busy` and
shrink the sample silently (it carries an owner marker now -- a file php-src
ships has none and is never touched, one whose owner is gone is taken over,
one whose owner is alive is still `busy`, all three measured); and
`nocompile.py` dropped a silent compile failure, which was round seventeen's
own doing.

**Round twenty-seven** found the last wrong ANSWER of the review, and it was
a silent one: `php_maxmin` carries ten values and the lowering stopped there
without a word, so `max(1,...,11)` was **10** and `max(...[1..10,99])` was
**10**. max and min are associative and the call folds in chunks of ten now
(`g/81-maxmin-wide.php`). Three more findings are refuted with measurements
-- `_run` does return stderr, `ph_argref` is cleared at entry by the
function that reads it, and `ph_had_spread` does not leak in any order tried
-- and the watcher's age sweep, which would have deleted a binary a slow
compile was still writing, is five minutes and four names instead of one
minute and everything.

**Round twenty-eight** was two gates claiming more than they ran. The `r/`
loop never invoked php at all, while `d8check` classified those files as
`fixture` -- whose D8 exemption rests on being a differential in both
worlds. A refusal fixture cannot be a byte-for-byte pair, so the pair is
`php -l` plus the named refusal, and `r/` has a regime of its own now. And
the orphan sweep's `_uncomment` dropped whole-line comments only, so an
inline one or a docstring naming a path read as a reference.

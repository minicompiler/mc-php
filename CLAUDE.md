# mc-php -- operating rules

Read `docs/plan.md` first. This repository is a CONSUMER of mc's **1.0 frozen surface**
(`docs/reference/hooks.md` § 8 there): it never edits mc's `src/`; a surface gap is reported to mc
with a reproducer, never patched around here. It is BUILT with whatever 1.x is installed -- the
freeze is additive, so a later minor keeps every name 1.0.0 published -- and each probe records
the version it measured on (T5 onward on **mc 1.1.0**, which is what `mc --version`
answers here).

- A `.php` file is PHP: it must run under `php` unchanged. No dialect. mc-php accepts a SUBSET:
  no `eval`/interpreter (D1) and static variable types (D4); a refusal is a named compile error.
- The oracle is php-src's `.phpt` corpus under `php` and under the mc-php build; every claim
  carries its green/total number.
- Comments, messages and docs in English; ASCII identifiers; no emojis.
- Every probe under `probes/` prints one number and exits 0 only when it measured it.
- Every `.php` written here has PHPUnit tests run under `php` AND under `mc-php test` (D8), and a
  row in `bench/` timing `php` against the mc-php binary. No PHP lands without both.
- One agent at a time; measurements before design; a decision in `docs/plan.md` § 3 is taken only
  by the probe that decides it.

## State
- 2026-09-15: repository created; plan and test grid written; no probe run yet.
- T1 done (`probes/t1`): the Zend shim is **169 symbols** -- 157 functions + 12 data globals, the
  union over `ctype`, `pdo_sqlite` and `mbstring` built as real `.so` by `phpize` against PHP
  8.5.10. `ctype` alone needs 7 functions and no data global; the fast ZPP macros are inline in the
  header, so the string path of an internal function calls nothing. `ext/json` cannot be built
  shared at all -- it is D2(a), not shim.
- T2 done (`probes/t2`): **export yes, variadic callee yes.** A `.so` built exactly as a php
  extension resolves symbols an mc binary defines, on all three link roads including `mc --exe`
  (`-export_dynamic` is not needed on macOS; dyld falls back to the classic symbol table, proved by
  patching `LC_DYSYMTAB.nextdefsym` to 0 and watching it break). An mc function is a valid variadic
  C callee with no mc change: on Apple arm64 variadic argument N is mc parameter 8 + N, capped at 4.
- T3 done (`probes/t3`): **yes.** php-src's own `ctype.so` runs `ctype_digit` on a
  `zend_execute_data` and a `zval` laid out by mc; `php` agrees on all five inputs, and the
  extension calls back into a variadic `php_error_docref` written in mc and reads the right
  argument. 39 layout facts are checked against the installed headers on every run. Two of the
  seven imported Zend symbols are implemented and really reached; five are stubs that name
  themselves and abort, and none fired.
- T4 done (`probes/t4`): **the grammar yes, the lexer no.** 14 grammar steps -- `echo`, typed
  functions, `if`/`while`/`for`/`foreach`, a `class`, `"x=$x"` interpolation, `require`/`_once`,
  and the D4 and D1 refusals -- all hanging off **one** registration, `syntax("<?php", &f)`;
  10 of them are byte for byte what `php` prints, and `mc build` with `[project].entry =
  "main.php"` works end to end. Of 31 PHP lexical constructs, 10 die under the stock lexer,
  `tok_add` fixes 6, and 4 are the core lexer's own -- `'`, `#`, `#[` and a region of raw bytes --
  plus `$name`, a `T_HOLE` that no registration reaches. D4 is implemented and proved: a second
  assignment of another type is a named compile error.
- A second mc gap found, reported in `docs/plan.md` § 5 and reduced to
  `probes/gap-lexer-ownership/`: a module cannot own the lexing of a source it claims. The
  workaround (rewriting the `on_source` buffer in place) is on record with what it costs, and the
  smallest additive fix is named: one function, `p_skip_to(uptr q)`, the generalisation of
  `p_take_lit`.
- One mc gap found, reported in `docs/plan.md` § 5 and reduced to `probes/gap-bss-exports/`: an
  `mc --exe` binary's exported symbols become invisible to `dlopen` once `__bss` makes `__DATA`'s
  vmsize exceed its filesize by one 16 KiB page (`__LINKEDIT`'s memory offset stops matching its
  file offset). The `[linker]` road is immune. Nothing was worked around: T3 uses `[linker]`.
- T0 done (`probes/t0`): the phpt grid runs, `phpt: green 0 / wrong 18109 / refused 0 / skip 2947 / php-fail 339 / total 21056  (21395 tests; sapi/ excluded)`; oracle cross-checked against
  php-src's own `run-tests.php` (`strings` exact, `Zend/tests` within 8 passes/5 skips); breakdown: 21560 classifiable tests; D1 143 (0.7%), D5 1569 (7.3%), D6 1719 (8.0%), D4-suspect 123 (0.6%); touched by at least one 3409 (15.8%), by none 18151 (84.2%); extension-specific 9028, of which 1899 touched.
- T5 done (`probes/t5`), on **mc 1.1.0**: the first runtime and the first compiler, and **green
  moves off zero** -- `phpt: green 80 / wrong 15367 / refused 2639 / skip 2947 / php-fail 362 / total 21033` over the whole
  corpus (T0's baseline on the same harness was `green 0 / wrong 18109 / refused 0`); per
  directory `tests/lang` 12, `Zend/tests` 38, `ext/standard/tests/strings` 12.
  All 80 greens are in T0's "touched by none" set -- the 84.2% of the corpus none of § 3's
  decisions touches. Two files: `probes/t5/php.mc` (the compiler --
  ONE `syntax("<?php")` plus `syntax_expr("$")`, the module's own expression grammar, D4's
  static types with their named errors) and `probes/t5/php_rt.txt` (the runtime -- D10's table:
  `string` is a `type_new` handle to T3's `zend_string` layout, binary-safe and never
  encoding-validated, `float` is `<float>`'s `f64`, `array` is a packed HOMOGENEOUS vector with
  keys 0..n-1, `int|false` is the one union and exists only because `strpos` has it; one 48 MiB
  arena per D7, never freed). The grid's third column is real: a refusal is
  `mc-php: <what> is refused by design (docs/plan.md D<n>)` and exit 3, and a construct T5 has
  not built yet is a DIFFERENT message and an ordinary compile error -- counting the second as
  the first would make the column a lie. Fifteen fixtures under `g/` are byte for byte php's on
  every run and six under `r/` are refused by name.
- mc 1.1.0 closed both open T4 gaps, measured by T5: `p_skip_to` owns `'...'`, `#`, `#[Attr]`
  and inline HTML **and `"..."`** (which is what gives php's own `\xNN`/`\u{...}`/octal escapes
  and an escaped `\$`; the core decodes its own set before any handler runs), `syntax_expr("$")`
  makes `$name` two tokens -- **T4's in-place `on_source` rewrite is deleted** and the
  `don't` -> `don"t` corruption with it -- and of the 48 external names `php.mc` calls, 45 are in
  `tests/golden/surface.txt` and the three that are not are `<float>`'s. One new gap is reported
  in `docs/plan.md` § 5: nothing can own the bytes before the FIRST token, so a `.php` opening
  with inline HTML is refused by name (38 of 21219 `.phpt`).
- T6 done (`probes/t6`), on **mc 1.1.0**: T5's wrong-reason table worked in descending value, and
  re-measured. **green 80 -> 1073**:
  `phpt: green 1073 / wrong 13374 / refused 3657 / skip 2947 / php-fail 344 / total 21051` over the
  whole corpus; per directory `tests/lang` 74 (was 12), `Zend/tests` 452 (was 38),
  `ext/standard/tests/strings` 180 (was 12). 1066 of the 1073 greens are in T0's "touched by none"
  set. Six blocks, one commit each: a zval and php's ordered hash (`mixed` is a php type whose
  lowering is a zval, which answers three of the four places T5 said D4 had no answer);
  classes/interfaces/traits/enums/objects reached BY NAME through a registry (dispatch, not
  reflection -- D6); functions `mixed` by default with defaults, variadics and closures;
  exceptions over a pending-exception flag (there is no VM and no setjmp: mc targets a board with
  no libc, and the flag is measured against the alternative in `probes/t6/bench/`); constants,
  references, `static`/`global`, heredoc, `switch`, `match`, the full `printf`; and a library
  table of 173 rows whose arity invariant the probe checks. `probes/t5/` is untouched and still
  reproduces its own number; `probes/t6/` is its two files grown, 2541 + 843 -> 5477 + 5022, and
  it calls 51 names from outside itself, 48 frozen and 3 `<float>`'s. **No new mc gap**; the one
  T5 reported (nothing can own the bytes before the FIRST token) is unchanged, 38 of 21219.
  Two decisions measured rather than assumed: a php array is a VALUE and D7 removed the mechanism
  php uses for it, so T6 copies EAGERLY and the arena is exhausted between 500 and 1000 copies of
  a 2000-element array; and 4657 of the 21386 tests with an expect section (21.8%) assert a
  `Warning:`/`Deprecated:`/`Notice:`/`Fatal error:` line, which T6 does not produce and which is
  the largest single item left for T7.
- T7 done (`probes/t7`), on **mc 1.1.0**: php's DIAGNOSTIC channel, and T6's
  `(compiled; output differs)` block taken apart by a tool that groups it. **green 1073 ->
  1218**: `phpt: green 1218 / wrong 13968 / refused 2917 / skip 2947 / php-fail 345 / total 21050`
  over the whole corpus; per directory `tests/lang` 82 (was 74), `Zend/tests` 539 (was 452),
  `ext/standard/tests/strings` 194 (was 180). **1211 of the 1218 greens are in T0's "touched by
  none" set**, the same seven outside it as T6. `refused` fell 3657 -> 2917 and `wrong` rose
  13374 -> 13968, which is two named refusals being retired and their tests moving into the
  column that says what they print.
  The two blocks T6 pointed at, each measured on its own population: the **4657** tests that
  assert a `Warning:`/`Deprecated:`/`Notice:`/`Fatal error:` line go **5 -> 71 green**, and the
  **333** that mention `__destruct` go **8 -> 11**.
  * **The diagnostic channel.** The POSITION is two runtime globals the compiler stores into
    once per statement (`php_pos`) -- threading a file and a line through 179 library rows is
    the alternative and it is not one; the file is absolutised the way php resolves it
    (`host_getcwd`), and the known inexactness is written down: a diagnostic raised after a user
    function RETURNED, inside the same statement, reports the line that callee last set. The two
    streams are written in php's own order (`PHP Warning:  ` on stderr first with
    `log_errors=On`, then `\nWarning: ...` on stdout; the phpt runner sets `log_errors=0` and
    grades stdout alone). Seventeen messages, each php-src's own text checked against php
    8.5.10, plus `error_reporting()`, `trigger_error()` and `@`.
  * **Two named refusals retired.** `Warning: Undefined variable $x` closes the last place T6
    said D4 had no answer -- php warns and yields null, null is a value of `mixed`, and `mixed`
    is already a zval, so the READ costs the variable no type and a later `$x = 5` still
    declares it an int. `@` is a suppression depth in the runtime, so `@EXPR` is a pending
    statement on each side of a temporary (D1's refusal gone).
  * **A php COMPILE-TIME `Fatal error:` is output, not a compile failure.** php reports some
    errors while parsing, prints the text on stdout and exits 255; `ph_phpfatal` does the same
    from inside the compiler and `probes/t7/mcphp.sh` passes 255 through, so the grid can
    compare it (the grid compares the exit code too). The first four on that road are the
    duplicate-modifier family.
  * **`probes/t7/diffgroup.py`** (new) is what chose every block after the diagnostics: it runs
    php and the mc-php binary on the same `--FILE--`, finds the FIRST differing line and groups
    by its shape. Its biggest single pair was a SPURIOUS warning (`??` reading through the
    warning getter), then the float tail (`1.7E-300` printed `3.720368547758E-299`; two
    independent bugs, `ph_pow10` dividing into the subnormals and `ph_digits` scaling by an
    infinite 10^316), the visibility marks `var_dump`/`print_r` owe a class and the object form
    `var_export` did not have, a zval's unary minus converting to INT first, php's BYTEWISE
    `& | ^` between two strings, `<< >>` as a TypeError on a non-numeric string, php's shift
    errors, and `var_dump("65" / "0")` printing NULL before the catch -- T6's own rule (the
    unwinding check goes between computing a value and using it) was implemented for `echo` and
    not for a CALL's arguments.
  * **php's assignment is an EXPRESSION.** `if (!($fp = fopen(...)))` was 22 of the 417 `wrong`
    tests under `ext/standard/tests/strings` alone. It is the store as a pending statement and
    the variable as the value; that turned a refusal into a wrong answer for
    `while (($n = f()) < 4)`, because a loop CONDITION's statements have to run every iteration,
    which `ph_loop_of` now splices after the step and before the test (a `for`'s condition was
    running them once, as part of the preamble).
  * **`__destruct`, and the first draft was a net LOSS.** D7 has no refcount, so the only point
    php also has is the END OF THE PROGRAM, in php's own reverse creation order (measured).
    Arming at allocation gave 8 -> 6: php does not destruct an object whose CONSTRUCTOR threw
    and never creates one when an ARGUMENT to `new` threw first, both said by php-src's own
    tests. Arming when the object is fully CREATED gives 8 -> 11. An object that dies EARLY --
    a local at scope end, an `unset`, a temporary -- is a documented difference.
  * **The array copy does not bite, and copy-on-write is NOT built.** `probes/t7/arena.py`:
    **9 of 1460** sampled `wrong` tests exhaust the arena and **not one is an array copy** --
    four build a very large string, four allocate without bound on purpose and expect php's own
    `Allowed memory size exhausted`, one is wrong for another reason as well. A 4x arena was
    measured as the cheap alternative and buys one test, so it is not taken either.
  * Six of T6's most-wanted library names (`class_alias`, `register_shutdown_function`,
    `strtok`, `strnatcmp`, `strnatcasecmp`, `addcslashes`) and the arities `explode`, `implode`
    and `substr_count` were short of.
  **No new mc gap**; the one T5 reported (nothing can own the bytes before the FIRST token) is
  unchanged, 38 of 21219. `php.mc` calls **53** names from outside itself -- 48 frozen, 3
  `<float>`'s, and `write`/`exit`, which the module declares `extern` itself for the
  compile-time fatal. `probes/t6/` is untouched and `probes/t7/out/base/` reproduces its three
  numbers (74 / 452 / 180) to the test; `probes/t7/grid.sh` exists because the first baseline
  here measured a binary that was being rebuilt underneath it.
  Fixtures: **30 of 30** under `g/` byte for byte php's on both streams, **5 of 5** under `r/`
  refused by name with exit 3; `lencheck` 97 / 0 wrong, `aritycheck` 179 / 0 wrong.
- T10 done (`probes/t10`), on **mc 1.1.0**: the review backlog -- 59 Copilot findings across
  #1..#7 that nothing had acted on (`docs/review-backlog.md`), all three sections, plus one
  the sections did not name and a disk that ran out. **green 1637 -> 1689**:
  `phpt: green 1689 / wrong 14469 / refused 1929 / skip 2947 / php-fail 361 / total 21034`;
  per directory `tests/lang` 104 (was 102), `Zend/tests` 749 (was 709),
  `ext/standard/tests/strings` 263 (was 262). **1664 of the 1689 greens are in T0's
  "touched by none" set**; `refused` fell **2309 -> 1929**. The green moved only +52 because
  the work is CORRECTNESS -- a `.phpt` that was already green does not become greener for the
  compiler being right about short circuit -- and what the probe is worth is the corrected
  numbers below.
  * **Four tools reported numbers they had never measured**, and they are what chose every
    block since T5. They are one tool now, `probes/t10/harness.py`: stdout byte for byte AND
    the same exit code, which is the pair the grid itself grades on. `why.py` labelled a test
    `(compiled; output differs)` WITHOUT running the binary -- of 812 sampled tests that
    compile, **788 really differ**, 22 crash, 2 time out and none agrees on both. The
    clustering of the 788 is worth the sample: **338 are `var_dump of a value`** and its head
    is `php 'int(N)' / mc ''` -- php printed a value and mc-php printed nothing, a program
    that stopped early rather than a value formatted wrongly.
    `arena.py` divided by `len(files)` while turning every failure into `None`: of the
    1352-test list only **782 RAN**, so the rate understated by 1.7x. `fixtures.sh` merged the
    streams with `2>&1` and compared with `$(...)`, which strips trailing newlines.
    `bench/bench.sh` in t7 and t8 built and timed **t6's** compiler. `<test>.why.php`
    clobbered a sibling of that name. And `nocompile.py`'s skip list named ONE compiled
    outcome of five, so the other four were counted as tests that do not compile: that block
    was published as 737 and is **539** -- the reviewer of this probe's own pull request
    caught it, in T10's first draft. Seventeen review rounds in all: the last one raised
    fourteen findings in code that had not changed since the round before, thirteen of them
    real (a spread argument that throws had no compute-then-check boundary, so
    `f(...boom())` ran the CALLEE'S BODY with the exception pending; `class_exists(..., false)`
    in the PHPUnit shim never autoloaded; `d8check.py`'s orphan sweep believed a file that
    named its own path; `why.py`/`diffgroup.py` fanned out past `T10_JOBS`; `fixtures.sh`
    called two 124s agreement; `harness.py` reported an ORACLE timeout as the candidate's) and
    one refuted by one command (macOS `/usr/bin/find` does have `-maxdepth`). Two of the
    thirteen moved no number and say so with the count: the corpus has 2 `EXPECT*_EXTERNAL`
    tests and neither asserts a diagnostic, and `why.tsv` has 0 rows in the statuses
    `nocompile.py` was miscounting. Re-running the corpus grid after the compiler change gives
    the same three directories (104 / 749 / 263) and **green 1677** -- 12 fewer, every one of
    them a filesystem test of the measured band and none containing a `...`.
  * **Twenty-two semantics a program can observe**, seventeen fixed and closed by a fixture,
    five closed by measurement, one recorded as a divergence with its number: short circuit (`&&`, `||`, `??`,
    `?:`, and the right side's own PENDING statements move inside the branch with it),
    parameters BY VALUE (in the callee's prologue, so no call road can forget), `finally` on a
    `return` from the try and from the catch, a pending exception stopping the CONDITION of
    `if`/`while`/`for`/`do`, visibility actually enforced, global function hoisting, typed
    method parameters coerced, `?->`, and thirteen one-liners. Refused with its number:
    `"${x}"`, deprecated in php 8.2 and worth 13 tests of the graded directories.
  * **`ph_cast(TY_U8, <pointer>)` keeps the LOW BYTE**, so `if ((u8) zval_ptr)` is false for
    every address ending in `0x00`. It silently skipped the by-value copy, and -- pre-existing
    since T9 -- `func_num_args`'s own counter, depending on nothing but where the arena landed:
    two class methods rather than one or three was enough to arrange it. No diagnostic, no
    reproducible failure, it moves with the size of the program. `ph_truthy` (`!!x`, mc's own
    64-bit test, twice) replaces both, and **anything here that asks "is this pointer non-null"
    must use it**.
  * **D8's mc-php half had NEVER run, under any probe.** `run.sh`'s step 10 piped both halves
    to `tail -1` with nothing behind them, so "6 ok / 0 failed in BOTH worlds" and T9's two
    bench ratios were php's side alone -- and T9's own compiler refuses T9's own
    `bench/main.php`. Two compiler defects: `require __DIR__ . "/x.php"` refused as a computed
    path (it is not -- both halves are compile-time literals, and it is php-src's own
    spelling), and a top-level `return` returning from the generated `main`, skipping
    `php_shutdown`, `php_flush` and the exit code, so the program printed NOTHING and exited
    with a junk status (54, 82, 94, 142 and 178 on five runs of the same source). Both halves
    run now: **6 ok / 0 failed in each**, `main.php` 6.73x, `heavy.php` 1.41x (the committed record).
  * **D8 over the fixtures** (backlog § 3): the plan states the exemption -- the unit D8
    governs is the PROGRAM, and a differential fixture is already a test and a stronger one --
    and `probes/t10/d8check.py` ENFORCES it, putting every `.php` in one of four regimes and
    failing on a file in none. It found `bench/unwind.php`, copied forward twice and referenced
    by nothing.
  * **The grid had no bound on its disk** and a full-corpus run filled a 460 GiB boot volume at
    about 20000 of 21395 tests. `mcphp.sh` EXECs the binary and cannot delete it; the caller,
    which WAITS, names it with `MCPHP_OUT` and unlinks it the moment the subprocess returns,
    and each run sweeps the dead siblings at startup. **Peak 1908 KiB over a run of 27728
    tests, 2152 KiB over the round-seventeen re-run of the same 27728 and 1860 KiB over one of
    6333 -- so it
    is bounded by the job count and not the corpus**; `df -h /` identical before and after.
  * **`do { } while (cond)` dropped its condition's pending statements**, so the unwinding
    check landed before the loop and a throwing condition spun for ever. `while` and `for` take
    them with `ph_take_pend`; `do` did not.
  * **The reviewer of T10's own pull request (#9) left twelve findings and every one was
    real** -- the standing rule of the backlog's § 3, applied to T10 itself. Six needed code:
    a top-level `return` inside a `try`/`finally` took the exit and jumped over the finally
    (ONE guard, `if (!ph_toplevel)` around the deferred-return flag's allocation, so the flag
    a return raised was read by nobody); `harness.py` ran the CANDIDATE before the oracle in
    the test's own directory and ignored `--ARGS--`/`--STDIN--`/`--ENV--`/`--INI--` while the
    grid passes all four, so a `.phpt` that writes a file beside itself contaminated the
    ORACLE and a test with a section could be measured as a DIFFERENT program (php runs
    first now, and the sections come from the grid's own `parse_phpt`, imported rather than
    copied); `diffgroup.py` stripped trailing newlines before comparing; `nocompile.py`
    counted four of the five compiled outcomes as failures to compile; and the D8 gate now
    prints why it invokes neither phpunit nor `mc-php test` and `d8check.py` fails when the
    class declares a `test*` the runner does not name.
  * **The second review round cost T10 its own headline, and that is the entry worth
    keeping.** The reviewer found that `harness.py` imported the grid's `DEFAULT_INI`
    without the `-d` prefixes `run_php` adds or the `{E_ALL}` substitution `main()` does --
    and chasing it found the bigger one: `run_pair` handed php a RELATIVE path while running
    it with `cwd` set to the test's own directory, so **php answered `Could not open input
    file` for every test in the sample** while the candidate ran anyway (its binary is an
    absolute `mkstemp` path). `probes/t0/phpt-run.py`'s own `classify` opens with
    `os.path.abspath` for exactly this reason. The first version of this probe reported
    **143 tests (18.2%) that print exactly what php prints and exit with a different code**
    and named them the next block; with php actually running there are **zero**. T10 worked
    section 1 of the backlog and published a new number of the same kind in the doing, which
    is the argument for one more rule: **a differential tool has to be checked against a case
    whose answer is known.**
  * **And the grid itself has a band, which no probe had measured.** The backlog says the grid
    is what is NOT in question; nobody had run it twice. Two runs of the SAME BINARY over the
    whole corpus give **green 1676 and 1688 (an earlier binary)**, the smaller a strict SUBSET of the larger, and
    all twelve of the difference are FILESYSTEM tests -- 9 under `ext/standard/tests/file`,
    3 under `ext/standard/tests/dir` -- which `chdir()` and write files in a shared working
    directory while six of them run at once. The three directory numbers do NOT move: 104 /
    749 / 262 came out identical on four separate runs across three compilers, and 263 on
    the fifth (round ten's sscanf fix).
    **A per-block move smaller than a dozen tests should be read on the directories**, and the
    corpus number is worth quoting with its band -- T9's 1637 and T8's 1450 included.
  Fixtures: **80 of 80** numbered under `g/` byte for byte php's on each stream and the exit code,
  **6 of 6** under `r/` refused by name with exit 3; `lencheck` 501 / 0 wrong, `aritycheck`
  272 / 0 wrong, `d8check` 93 `.php` in a regime and 361 under `probes/` swept for orphans. **No new mc gap**, and no new external
  name: the 38-of-21219 inline-HTML refusal T5 reported is unchanged.
- T9 done (`probes/t9`), on **mc 1.1.0**: D6's correction built, and T8's two blocks
  worked from a UNIFORM corpus-wide sample (every ninth of `wrong.txt`, split so the
  three GRADED directories are not drowned by `ext/dom` 734, `ext/spl` 713,
  `ext/date` 570, `ext/reflection` 467). **green 1450 -> 1637**:
  `phpt: green 1637 / wrong 14140 / refused 2309 / skip 2947 / php-fail 362 / total 21033`;
  per directory `tests/lang` 102 (was 93), `Zend/tests` 709 (was 635),
  `ext/standard/tests/strings` 262 (was 223). **1626 of the 1637 greens are in T0's
  "touched by none" set**; `refused` fell 3024 -> 2309, which is one block.
  * **The php type words, the biggest block and it REMOVED a refusal.** T5's table
    refused `array`, `mixed`, `iterable`, `callable`, `object`, `never`, `self`,
    `static`, `null`, `?T`, `T|U`, `A&B` and a class name in a parameter or a return
    because T5 had no zval; **T6 built one and the table was never re-measured**, and
    D4 (c) and D9 already said every one of them lowers to a zval. `Zend/tests`'s
    refused column fell by 229. Namespaces are FLATTENED with it (one program, one
    class table -- D1), with the collision cost on record.
  * **`#[\Override]` is checked, not ignored** (0 -> 28 of 67). Not reflection: php
    checks it while COMPILING the class. Three rules measured rather than assumed --
    a property's fatal carries the CLASS's line and a method's its own, a PRIVATE
    parent member is not a match, and an abstract or interface method IS one.
  * **Late static binding** (`static::`, `new static`, `get_called_class`): one
    runtime global saved and restored around every call that can change it, an
    instance call binding the object's class and a static call the named one unless
    it FORWARDS. `static` needed a cursor lookahead (`ph_dcolon_next`), because the
    module has no token lookahead.
  * **`readonly`** (94 tests in the graded directories name one), **argument
    unpacking `f(...$args)`** (one slot per parameter the callee could take, and
    `php_unpack_at` answers "not passed"), **`max`/`min` over N values with php's own
    comparison**, **`ext/json` written in mc** (D2 (a)), the three by-reference
    targets T8 left, **`sscanf`**/`setlocale`, the **trigonometric family from libm**
    (php prints 14 digits and a hand-rolled series does not survive it), `getcwd`/
    `chdir`/`chmod`/`putenv`, and **`set_error_handler` made real** -- it was a no-op
    STUB, which is why a test installing one to OBSERVE a diagnostic printed nothing.
  * **Five string edges** the strings diffgroup named, each measured against php
    8.5.10: `strrpos`/`strripos` ignored the offset, `strspn`/`strcspn` ignored
    `(offset, length)`, `str_split("")` is `[]` since 8.2, `wordwrap` with `cut`
    cuts at EXACTLY the width, and `trim`'s charlist reads `x..y` as a RANGE.
  * **D8 met for the first time**: nothing here had ever written a `.php` outside a
    `.phpt` fixture. `probes/t9/bench/workload.php` (a JSON round trip, a template
    renderer, a sort-heavy pass) runs under `php` unchanged; its PHPUnit `TestCase`
    is **6 ok / 0 failed in BOTH worlds** (the mc-php half NAMES its test methods,
    because D6 forbids discovering them at run time); and the bench reports TWO
    ratios because they measure different things -- **mc-php wins the whole program
    (5.85x, 1.45x)** because php pays ~38 ms of start-up, and **LOSES the work**
    (php's own work is 1.5 ms of `heavy.php`'s 39.5 against mc-php's 27, so the
    generated code is 8x to 23x slower than php's VM). D7 names the cause: every
    value is arena-allocated and never freed, an array copies eagerly, a string is
    immutable. The JSON phase is also the first thing the 48 MiB arena has bounded
    that this repository WANTED to do rather than a corpus test doing it on purpose
    (60 records x 3 fits, 80 does not).
  * **The generator decision, with its number, and generators are NOT built**: 252 of
    the 13623 `wrong` tests use `yield` (1.8%; 260 of 5312 under `Zend/tests`) and
    **145 of the 252 use the manual Generator API**. The shape if it is built is a
    state machine the compiler makes out of the function body -- mc has no goto and
    D7 forbids a VM and a second stack -- which needs a CFG pass `php.mc` does not
    have and is the largest single piece of work in the probe (600-1000 lines plus
    the `Generator` class). The cheap shape (inverting a `foreach`-only generator
    into a callback) is correct and costs ~150 lines but serves at most 107 of the
    252 and would make the other 145 a trap, so it was refused as a WRONG answer
    rather than a missing one. Recorded for T10 to weigh against its own list.
  * The re-measured tables are FLAT at the head: of 718 sampled `wrong` tests in the
    graded directories, 391 do not compile and 327 compile and differ, and the
    largest single first-difference pair left is worth 6 tests. What is bounded and
    named is property hooks (25) and asymmetric visibility; the rest is one function
    each.
  * Sub-populations: the 4647 tests asserting a php diagnostic go 83 -> **93**, the
    333 mentioning `__destruct` stay at **14**. D7 re-measured: **2 of 1572** sampled
    `wrong` tests exhaust the arena (T8's was 11 of 1396), both building a very large
    string on purpose. **No new mc gap**; the one T5 reported is unchanged, 38 of
    21219. `probes/t8/` untouched and `probes/t9/out/base/` reproduces its three
    numbers to the test. Fixtures **60 of 60** byte for byte php's on both streams
    and the exit code, refusals **6 of 6** named with exit 3 (T8's `d9-nullable.php`
    stopped being a refusal and moved to `g/`), `lencheck` 468 / 0 wrong,
    `aritycheck` 272 / 0 wrong.
- T8 done (`probes/t8`), on **mc 1.1.0**: the block T7 named -- `(does not compile)`, 878 of
  1460 sampled `wrong` tests -- taken apart group by group, and the 288 missing names worked in
  descending frequency. **green 1218 -> 1450**:
  `phpt: green 1450 / wrong 13607 / refused 3026 / skip 2947 / php-fail 365 / total 21030` over the whole
  corpus; per directory `tests/lang` 93 (was 82), `Zend/tests` 635 (was 539),
  `ext/standard/tests/strings` 223 (was 194). **1441 of the 1450 greens are in T0's "touched
  by none" set**; `refused` rose 2917 -> 3026 and `wrong` fell 13968 -> 13607, which is a test
  that now COMPILES getting far enough to hit a design refusal it never reached before. The
  `php-fail` column is php's OWN and this run had 365 against the previous run's 346 -- the
  machine was loaded, and five of the nineteen were green in that run and are green again when
  re-run with the same binary, so the tree's number is 1455 and 1450 is what the loaded run
  measured. Two sub-populations moved without being targets: the 4647 tests that assert a php
  diagnostic go 71 -> 83 and the 333 that mention `__destruct` go 11 -> 14.
  **`probes/t8/nocompile.py`** (new) is what made the block workable: `whytable.py` prints its
  head as a flat top-22 with no way back to a file, and this reads the SAME `why.tsv` -- so no
  compiler run is repeated -- masks the variable part of each message, groups, and prints the
  count with three example files per group.
  * **References, 83 of the sample across four messages, the biggest single theme.** A
    by-reference parameter is FREE once the caller's variable is a zval -- a `mixed` local
    already holds a zval pointer and a ref writes THROUGH it (`php_zv_store`), the mechanism
    `$a = &$b` and `global $x` have used since T6 -- and what was missing is that nothing made
    the CALLER's variable one. The source scan grew two passes: `ph_scan_brf` finds every
    `function name(... &$x ...)` (its own pass, because a call may come before the declaration)
    and `ph_scan_brf_calls` puts every `$variable` inside the parentheses of a call to one of
    them into the ref set. It does not track argument POSITIONS: over-marking costs a zval and
    nothing else, which is what the rule above it already costs. An UNBOUND name passed by
    reference is CREATED rather than read (php does not warn for one), which is what makes an
    output parameter work. With that in place: `use (&$x)` (the capture is the enclosing zval's
    ADDRESS, carried through the use array as an integer -- the array slot `php_arr_set` writes
    is a different cell and could not alias), a by-reference METHOD parameter (free: every
    method parameter is already a zval pointer) and `function &f()` (D7 has no refcount, so what
    `&` can mean is that the value is not copied on the way out).
  * **The lvalue chain, 71.** `ph_lv_walk` walked `[k]` only, so `$a[0]->p = 1`, `$t->x[0][0]`
    and `$c = &$t->list` had nowhere to go; it walks `[k]` and `->p` in any order and to any
    depth now and answers a container plus either a key or a property name. `isset`/`empty` read
    the same chain QUIETLY -- php warns for nothing either touches, and what is not there reads
    as null, which is the answer both want.
  * **A method's `: void`, 37.** `ph_skip_type` tested `ph_tid == T_IDENT` and `void` is one of
    mc's OWN keywords, so the skip consumed nothing and the body's `{` was never reached.
  * The **alternative syntax** (all five, one helper), **`list()`/`[$a,$b] =`** (the pattern
    collected first, as a flat list of paths), **anonymous classes** (an ordinary declaration
    under a generated name; the constructor arguments sit between the keyword and `extends`),
    **a compound assignment to an array element** (`??=`, `++` and `--` too), **`@` on a
    STATEMENT**, **`$s[9] = "x"`**, **`$f();` as a statement** (`ph_expr` split into its primary
    half and `ph_expr_tail`), **`int ...$n`**.
  * **The names.** Files and streams -- the biggest block, 39 library rows over a php
    `resource`, which is a zval of type `IS_RESOURCE` indexing one table; mc's `open` is not
    variadic, so a create is `creat()` + reopen. `pack`/`unpack` (every code with its repeater;
    the byte orders spelled out rather than probed, because a compiled program must give the
    same answer on all five targets). Output buffering, which NESTS -- it was one level, a
    capture for `print_r($x, true)`, so `ob_start(); print_r($x, true);` lost the outer buffer.
    `get_html_translation_table` with php's own 253 entries. `fprintf`/`vfprintf`,
    `serialize`/`unserialize`, `settype`, `parse_str`, `array_splice`, `str_getcsv`,
    `str_decrement`, `uniqid`, `quoted_printable_*`, `convert_uu*`, `mb_internal_encoding`, and
    **`func_num_args`/`func_get_arg`** -- answered inside the callee from its own parameters,
    which needs no run-time type table (`func_get_args` IS named by D6 and stays refused; the
    measurement is in `docs/plan.md` D6 and the decision is the owner's).
  * **Four defects the blocks found, none of them in the block being built.** (1) The source
    scans read BYTES and a comment is not code: one line of the RUNTIME's own commentary --
    `// array_splice(&$a, offset, ...)` -- put `$a` in the ref set, so every `$a` in every
    program became a zval and the D4 refusal `$a = "one"; $a = 1;` stopped firing;
    `probes/t8/r/d4-retype.php` caught it. `ph_scan_hop` skips `//`, `#` (but not `#[`),
    `/* */` and both quote forms. (2) The unwinding check was missing on `return` -- T6's rule
    is that it goes BETWEEN computing a value and using it, and the return statement put it
    after, where nothing runs, so `return f();` inside a `try` left the exception pending.
    (3) A class member's DEFAULT may be an array literal, and an array literal is pending
    statements plus a local: `public $x = [1, 2];` captured the local before those ran, so the
    property came out `array(0)` and, with another array literal earlier in the file, the
    program SEGFAULTED. (4) `lencheck` did not cover `php_str_new("...", N)`, which is how most
    of the runtime spells a literal: three lengths were wrong, one of them ten bytes long.
    100 pairs -> 418.
  * **A node may appear in an mc AST ONCE**, which is not written down anywhere: the arguments
    of a call are its SIBLING chain, so sharing a hoisted container between the read and the
    write of a compound assignment made the chain a CYCLE -- a stack overflow in the walker and
    not a diagnostic.
  **No new mc gap**; the one T5 reported is unchanged, 38 of 21219. `php.mc` calls 58 names
  from outside itself: 48 frozen, four core intrinsics (`ld8`/`ld64`/`st8`/`st64`), three
  `<float>`'s, and three libc -- `write` and `exit` (T7's) plus `realpath`, which `<mc/host>`
  declares and which php needs because it reports the path it RESOLVED (on macOS every
  diagnostic under `/tmp` printed the wrong one of `/tmp` and `/private/tmp`).
  Fixtures: **46 of 46** under `g/` byte for byte php's on both streams and the exit code,
  **5 of 5** under `r/` refused by name with exit 3; `lencheck` 418 / 0 wrong, `aritycheck`
  241 / 0 wrong.

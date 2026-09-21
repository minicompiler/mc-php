# probes

Preliminary measurements. Each answers one question from `docs/plan.md` § 4, each is a script that
prints one number, and each exits 0 only when it measured it. They run before any of the compiler
exists, because the decisions in `docs/plan.md` § 3 depend on them.

Host these were measured on: macOS 26 / arm64, PHP 8.5.10 (Homebrew, NTS), mc 1.0.0,
php-src at tag `php-8.5.10` (`34308a66`). Every number below is per-host; a Linux or Windows host
has to run them again.

Build dependencies: `php-config`, `phpize`, `clang`, `re2c` (php-src's SQL parser generator),
`python3` (used by the probes only to read Mach-O load commands).

## T1 -- how big is the Zend shim

**169 symbols** (157 functions + 12 data globals), the union over `ctype`, `pdo_sqlite` and
`mbstring` built as real `.so` by `phpize`. `ctype` alone needs **7 functions and no data**. The
split between "Zend/PHP API" and "libc" is not a name heuristic: a symbol is shim iff the `php`
binary exports it, which is exactly what dyld resolves it against.

`sh probes/t1/run.sh` -- clones nothing, but needs `php-src` at the repository root
(`git clone --depth 1 --branch php-8.5.10 https://github.com/php/php-src php-src`). Lists land in
`probes/t1/out/`. Details: `probes/t1/RESULTS.md`.

## T2 -- can an mc binary export a symbol to a `.so`, and take a variadic call

**Yes and yes.** A `.so` built exactly as a php extension resolves symbols an mc binary defines, on
all three link roads -- `mc --exe` included, and `-export_dynamic` is not needed on macOS. And a
function written in mc can be the callee of a variadic C call with no mc change, because on Apple
arm64 variadic argument N lands exactly where mc reads parameter 8 + N. The ceiling is **4**
variadic arguments (`MAXPARAMS` is 12, one goes to the format).

`sh probes/t2/run.sh`. Details, including the control that proves which table dyld reads:
`probes/t2/RESULTS.md`.

## T3 -- does a real extension run on our zval

**Yes.** php-src's own `ctype.so` runs `ctype_digit` on a `zend_execute_data` and a `zval` laid out
by mc, and `php` agrees on all five inputs. **39** layout facts are checked against the installed
headers with `offsetof`/`sizeof` on every run. Two of the seven Zend symbols `ctype.so` imports are
implemented (both really reached, one of them variadically); five are stubs that name themselves and
abort, and none of them fired.

`sh probes/t3/run.sh` (after T1, which builds `ctype.so`). Details: `probes/t3/RESULTS.md`.

## T4 -- does Tier 3 take PHP's grammar

**The grammar yes, the lexer no.** 14 grammar steps, 10 of them byte for byte what `php` prints,
all hanging off **one** registration -- `syntax("<?php", &ph_program)`. What Tier 3 does not reach
is the byte stream: of 31 PHP constructs, **10 die under the stock lexer, `tok_add` fixes 6, and 4
are the lexer's own** (`'`, `#`, `#[`, and a region of raw bytes), plus `$name`, which is a
`T_HOLE` no registration reaches. `mc build` with `[project].entry = "main.php"` works end to end.

`sh probes/t4/run.sh`. Details: `probes/t4/RESULTS.md`.

## gap-bss-exports -- an mc gap T3 hit

Not a plan probe: the minimal reproducer for the one mc gap these three found, kept so it can be
handed to mc and re-run when mc changes. An `mc --exe` binary's exported symbols become invisible to
`dlopen` once its `__bss` reaches one 16 KiB page. `sh probes/gap-bss-exports/run.sh` prints the
segment numbers at four sizes and exits 0 only when it still reproduces. Reported in
`docs/plan.md` § 5.

## gap-lexer-ownership -- an mc gap T4 hit

A module cannot own the lexing of a source it claims. With `source_claim` answering 1 for every
source and every lexeme PHP needs added with `tok_add`, `'` is still a char literal, `#` is still a
directive, `$name` is still a `T_HOLE` no registration reaches, and a region of raw bytes still
cannot be skipped. `sh probes/gap-lexer-ownership/run.sh` exits 0 only while it reproduces.
Reported in `docs/plan.md` § 5, with the one additive function that would close three of the four.

## T0 -- how far is 0 from N

The grid: every `.phpt` under php-src, `php` against a placeholder executor B
(`probes/t0/mcphp-stub.sh`, which does not exist as a compiler yet and always disagrees). Also the
corpus breakdown -- how much of it `docs/plan.md` § 3's decisions actually touch, measured with
the real tokenizer (`token_get_all()`, never a regex over PHP source) -- and a cross-check of this
probe's own harness against php-src's own `run-tests.php` over `Zend/tests` and
`ext/standard/tests/strings`, which found and fixed three real bugs in `phpt-run.py` along the way
(a stray `--` corrupting `--ARGS--`, an unquoted space leaking out of `--INI--`, and a hardcoded
`E_ALL` that does not match this PHP build's actual 30719).

The numbers: `phpt: green 0 / wrong 18109 / refused 0 / skip 2947 / php-fail 339 / total 21056`
(21395 files, `sapi/` excluded; green requires the exit code too). Breakdown: of 21560 classifiable
tests, D1 touches 143 (0.7%), D5 1569 (7.3%), D6 1719 (8.0%), D4-suspect 123 (0.6%) -- **18151
(84.2%) are touched by none**; 9028 are extension-specific, 1899 of those touched.

`sh probes/t0/run.sh` (`T0_CROSSCHECK=1` also re-runs php-src's own runner, ~8 minutes). Details:
`probes/t0/RESULTS.md`.

## T5 -- does the runtime agree with php

**Green moves off zero:**
`phpt: green 80 / wrong 15367 / refused 2639 / skip 2947 / php-fail 362 / total 21033`
over the whole corpus, against T0's
`green 0 / wrong 18109 / refused 0 / skip 2947 / php-fail 339 / total 21056` on the same harness.
Per directory: `tests/lang` 12, `Zend/tests` 38, `ext/standard/tests/strings` 12.
All 80 greens are in T0's "touched by none" set -- the 84.2% of the corpus none of
`docs/plan.md` § 3's decisions touches.

Two files and nothing else: `probes/t5/php.mc`, a compiler that hangs on ONE
`syntax("<?php")` plus `syntax_expr("$")`, and `probes/t5/php_rt.txt`, the runtime D10's table
describes -- `bool` as `u8`, `int` as `i64`, `float` as `<float>`'s `f64`, `string` as a
`zend_string`-shaped handle that is binary-safe and never encoding-validated, over one arena
(D7). The third column is real for the first time: a refusal is a NAMED design answer
(`mc-php: <what> is refused by design (docs/plan.md D<n>)`, exit 3) and is a different message
from something T5 has not built yet, which is an ordinary compile error.

mc 1.1.0 is what made it possible. `p_skip_to` closed three of T4's four lexer gaps and a fourth
T4 had not asked for -- `"..."`, which is the only way to get php's own `\xNN`/`\u{...}`
escapes and an escaped `\$` -- and `syntax_expr("$")` closed the last. **T4's in-place
`on_source` rewrite is deleted**, and the `don't` -> `don"t` corruption with it. One gap is left
and it is in `docs/plan.md` § 5: there is no way to own the bytes before the FIRST token, so a
`.php` that opens with inline HTML is refused by name (38 of 21219).

`sh probes/t5/run.sh` (about 12 minutes: fifteen fixtures, six refusals, four grids and the
breakdown intersection). Details: `probes/t5/RESULTS.md`.

## T6 -- how far does the wrong-reason table move

**A factor of 13:**
`phpt: green 1073 / wrong 13374 / refused 3657 / skip 2947 / php-fail 344 / total 21051`
over the whole corpus, against T5's `green 80` on the same harness. Per directory:
`tests/lang` **74** (was 12), `Zend/tests` **452** (was 38),
`ext/standard/tests/strings` **180** (was 12). **1066 of the 1073 greens are in T0's
"touched by none" set**; the other 7 are the first greens a decision in `docs/plan.md` § 3 has
an opinion about.

T5 left a table of WHY its 15367 `wrong` tests were wrong. T6 works it in descending value, one
commit per block, re-measuring between blocks so the next one is chosen by a number:

* **a zval and php's ORDERED HASH** -- `zend_array` field for field, a 32-byte Bucket, the u32
  hash slots before `arData`, integer and string keys with php's numeric-string rule, insertion
  order and the holes `unset` leaves. `mixed` is a php type whose lowering is that zval, which is
  what D4 (c) always said a union lowers to -- and it answers three of the four places T5 said
  D4 had no answer (an untyped parameter, `int / int`, `$x = null`).
* **classes, interfaces, traits, enums and objects**, every member reached BY NAME through a
  registry -- dispatch, not reflection (D6). Inheritance, promotion, statics, class constants,
  `::class`, `clone`, `instanceof`, run-time visibility and the magic methods D6 keeps.
* **functions** that are `mixed` by default, with defaults, `...$rest` and closures; a callable
  as a VALUE, which is what `array_map`/`usort` take.
* **exceptions** over a pending-exception flag, because mc's five targets include a bare board
  with no libc and there is no setjmp to have. The flag is MEASURED against the alternative
  (`probes/t6/bench/`): the check is 33% of the hot function's instructions and below the noise
  floor of code layout in wall clock.
* **constants, references, `static`/`global`, heredoc, `switch`, `match`, the full `printf`.**
* **a library TABLE**, 173 rows, whose one invariant (`max` = the runtime's arity) the probe
  checks -- it found 37 mismatches at once.

Two things the probe measures that are decisions and not bugs: a php array is a VALUE and D7
removed the mechanism php uses for it, so T6 copies EAGERLY and the 48 MiB arena is exhausted
between 500 and 1000 copies of a 2000-element array (php stays at 25 MB); and **4657 of the
21386 tests with an expect section -- 21.8% -- assert a `Warning:`/`Deprecated:`/`Notice:`/
`Fatal error:` line**, which T6 does not produce and which is the largest single item left.

`sh probes/t6/run.sh` (about 45 minutes: 24 fixtures, 5 refusals, four grids, the breakdown
intersection and the wrong-reason table re-measured). Details: `probes/t6/RESULTS.md`.

## T7 -- php's diagnostics, and the tests that compile and print the wrong thing

**green 1073 -> 1218:**
`phpt: green 1218 / wrong 13968 / refused 2917 / skip 2947 / php-fail 345 / total 21050`
over the whole corpus. Per directory: `tests/lang` **82** (was 74), `Zend/tests` **539**
(was 452), `ext/standard/tests/strings` **194** (was 180). **1211 of the 1218 greens are in
T0's "touched by none" set.** `refused` fell 3657 -> 2917: two named refusals were retired.

T6 left two numbers pointing at what to do next: **21.8% of the corpus asserts a php DIAGNOSTIC
line** (4657 of the 21386 tests with an expect section) and T6 produced only the
uncaught-throwable form of `Fatal error:`; and **536 of 1417 sampled `wrong` tests compiled, ran,
and printed the wrong thing**. T7 builds the first and takes the second apart.

* **The diagnostic channel.** The POSITION is two runtime globals the compiler stores into once
  per statement -- a file and a line threaded through 179 library rows is the alternative, and
  it is not one. The file is absolutised the way php resolves it, the two streams are written in
  php's own order (the `PHP Warning:  ` form on stderr first, then `\nWarning: ...` on stdout),
  and the known inexactness is written down: a diagnostic raised after a user function RETURNED,
  inside the same statement, reports the line that callee last set.
* **Seventeen messages**, each php-src's own text checked against php 8.5.10 -- undefined
  variable, undefined array key, array to string, non-numeric value, array offset on a scalar,
  uninitialized string offset, undefined property, read property on null, `foreach()` argument,
  two `strtok`/`addcslashes` warnings, four implicit-conversion and increment deprecations, and
  the duplicate-modifier COMPILE-TIME fatals. `error_reporting()`, `trigger_error()` and `@` are
  real.
* **`Warning: Undefined variable $x` retires a D4 refusal** -- the one place T6 said the rule
  had no answer. php warns and yields null, null is a value of `mixed`, and `mixed` is already a
  zval, so the READ costs the variable no type at all.
* **A php COMPILE-TIME `Fatal error:` is output, not a compile failure.** php reports some
  errors while parsing, prints the text on stdout and exits 255; `probes/t7/mcphp.sh` passes 255
  through so the grid can compare it.
* **`probes/t7/diffgroup.py`** (new) runs php and the mc-php binary on the same `--FILE--`,
  finds the FIRST differing line and groups by its shape. That table chose every block after the
  diagnostics; what it named and what came of each is in `probes/t7/RESULTS.md` § 2.
* **`probes/t7/arena.py`** (new) answers D7's open question with a number: **9 of 1460 sampled `wrong` tests exhaust the arena and not one is an
  array copy** (four build a huge string, four expect php's own memory_limit fatal), so the
  copy-on-write T6 left open is NOT built and the number is why.
* **`__destruct`** runs at the end of the program, in php's own reverse creation order -- the
  only destructor point D7 also has. The 333 tests that mention it go **8 -> 11**; the first
  draft was a net LOSS (8 -> 6) until php-src's own tests said that an object whose CONSTRUCTOR
  threw is never destructed. An object that dies EARLY -- a local, an `unset`, a temporary -- is
  a documented difference.

`sh probes/t7/run.sh`. Details: `probes/t7/RESULTS.md`.

## T10 -- the review backlog: the measurements that lie, the semantics that are wrong

**green 1637 -> 1689.**
`phpt: green 1689 / wrong 14469 / refused 1929 / skip 2947 / php-fail 361 / total 21034`
over the whole corpus; per directory `tests/lang` **104** (was 102), `Zend/tests` **749**
(was 709), `ext/standard/tests/strings` **263** (was 262). **1664 of the 1689 greens are in
T0's "touched by none" set**, and `refused` fell **2309 -> 1929** -- one block, because
`require __DIR__ . "/x.php"` and a top-level `return` were refusals and are not any more.

The green moved only +52, and that is the expected shape: this is CORRECTNESS work, and a
`.phpt` that was already green does not become greener for the compiler being right about short
circuit. What the probe is worth is the corrected numbers.

* **Four tools reported numbers they had never measured** (`docs/review-backlog.md` § 1), and
  they are what chose every block since T5. `probes/t10/harness.py` is the single definition of
  "these two agree" now -- stdout byte for byte AND the same exit code, which is the pair
  `probes/t0/phpt-run.py` itself grades on. `why.py` labelled a test
  `(compiled; output differs)` **without ever running the binary**: of 812 sampled tests that
  compile, **788 really differ**, 22 crash, 2 time out and none agrees on both. The clustering
  of the 788 is what the sample is for: **338 are `var_dump of a value`**, and its head is
  `php 'int(N)' / mc ''` -- php printed a value and mc-php printed nothing, a program that
  stopped early rather than a value formatted wrongly. `arena.py`
  divided by `len(files)` while turning every failure into `None`: of the 1352-test list only
  **782 RAN**. `fixtures.sh` merged the streams with `2>&1` and compared with `$(...)`. And
  `nocompile.py`'s skip list named ONE compiled outcome of five, so the block that does not
  compile was published as 737 and is **539** -- the reviewer of this probe's own pull request
  caught that one, in T10's first draft.
* **Twenty-two semantics a program can observe** (§ 2), seventeen fixed and closed by a
  fixture, five closed by measurement, one recorded as a divergence with its number: short circuit and the right
  operand's own pending statements, parameters BY VALUE in the callee's prologue, `finally` on
  a `return`, a pending exception stopping a CONDITION, visibility, hoisting, typed method
  parameters, `?->`, and thirteen one-liners.
* **`ph_cast(TY_U8, <pointer>)` keeps the low byte**, so `if ((u8) p)` is false for every
  address ending in `0x00`. It silently skipped the by-value copy and, since T9,
  `func_num_args`'s counter -- with no diagnostic and no reproducible failure, because it moves
  with the size of the program. `ph_truthy` (`!!x`) replaces both.
* **D8's mc-php half had never run, under any probe** (§ 3, and one the section did not name).
  `run.sh` step 10 piped both halves to `tail -1` with nothing behind them. `require __DIR__ .
  "/x.php"` was refused as a computed path and a top-level `return` returned from the generated
  `main`, printing nothing and exiting with a junk status. Both halves run now: **6 ok / 0
  failed in each**, `main.php` 6.73x, `heavy.php` 1.41x (the committed record). `probes/t10/d8check.py` is the
  enforcement D8 lacked: four regimes, and a `.php` in none of them fails the run.
* **The grid had no bound on its disk** and a full-corpus run filled a 460 GiB boot volume at
  about 20000 of 21395 tests. The caller names the binary with `MCPHP_OUT` and unlinks it the
  moment the subprocess returns; each run sweeps the dead siblings at startup. **Peak 1908 KiB
  over a run of 27728 tests, 2152 KiB over the round-seventeen re-run of the same 27728 and
  1860 KiB over one
  of 6333: bounded by the job count and not the corpus.**

**And the grid itself has a band, which no probe had measured.** Two runs of the SAME BINARY
over the whole corpus give **green 1676 and 1688 (an earlier binary)**, the smaller a strict subset of the larger,
and all twelve of the difference are FILESYSTEM tests (9 under `ext/standard/tests/file`, 3
under `ext/standard/tests/dir`) that `chdir()` and write files in a shared working directory
while six run at once. The three directory numbers do not move -- 104 / 749 / 262 on four separate
runs across three compilers, 263 on the fifth -- so a per-block move smaller than a dozen tests should be
read there.

**The second review round cost T10 its own headline.** `harness.py` handed php a RELATIVE path
while running it with `cwd` set to the test's own directory, so php answered `Could not open
input file` for every test in the sample while the candidate ran anyway. The first version of
this probe reported **143 tests (18.2%) that print exactly what php prints and exit with a
different code** and named them the next block; with php actually running there are **zero** --
of the 812 that compile, **788 really differ**, 22 crash, 2 time out, none agrees. The review
of #9 ran to **seventeen rounds and 59 findings**; the last of them found a spread argument
that throws running the callee's body before unwinding (`g/77-spread-throw.php`), and one
claim -- that macOS `find` has no `-maxdepth` -- refuted by one command. T10 worked
section 1 of the backlog and published a new number of the same kind in the doing, which is the
argument for one more rule: a differential tool has to be checked against a case whose answer is
known.

**The reviewer of T10's own pull request (#9) left twelve findings and every one was real** --
the standing rule of `docs/review-backlog.md` § 3, applied to T10. They are listed with their
fix in § 4 of that file; six needed code, including the `nocompile.py` correction above and a
top-level `return` inside a `try`/`finally` that took the exit and jumped over the finally.

`sh probes/t10/run.sh` (about 90 minutes: 80 fixtures, 6 refusals, four grids, the breakdown
and the five tables). Details: `probes/t10/RESULTS.md`.

## T9 -- func_get_args, the two blocks T8 inverted, and the generator decision

`phpt: green 1637 / wrong 14140 / refused 2309 / skip 2947 / php-fail 362 / total 21033`
over the whole corpus, against T8's `green 1450` on the same harness. Per directory
`tests/lang` **102**, `Zend/tests` **709**, `ext/standard/tests/strings` **262**.
**1626 of the 1637 greens are in T0's "touched by none" set**, and `refused` fell
3024 -> 2309.

The sample this probe worked from is UNIFORM over the whole corpus (every ninth of
`wrong.txt`) and not an alphabetical slice, and it was split: the three GRADED
directories from `ext/dom` (734 wrong), `ext/spl` (713), `ext/date` (570),
`ext/reflection` (467) and their kind, which need whole extensions.

* **The php type words, and this is the biggest block by far.** T5's table refused
  `array`, `mixed`, `iterable`, `callable`, `object`, `never`, `self`, `static`,
  `null`, `?T`, `T|U`, `A&B` and a class name in a parameter or a return -- because
  T5 had no zval. **T6 built one and the table was never re-measured**, and D4 (c)
  and D9 already said every one of them lowers to a zval. `Zend/tests`'s refused
  column fell by 229 on that alone.
* **`#[\Override]` is checked, not ignored**, 0 -> 28 of the 67 Override tests. It
  is not reflection (D6): php checks it while COMPILING the class, the compiler
  names the member, and nothing at run time enumerates anything.
* **Late static binding** (`static::`, `new static`, `get_called_class`), one
  runtime global saved and restored around every call that can change it.
* **`readonly` properties**, **argument unpacking `f(...$args)`**, **`ext/json`
  written in mc** (D2 (a)), the three **by-reference targets** T8 left
  (`$a = &f()`, `$a[k] = &$v`, `$o->p = &$v`), **`sscanf`** and five string-function
  edges that moved `ext/standard/tests/strings` 223 -> 262, the **trigonometric
  family** from libm, and **`set_error_handler` made real** (it was a no-op stub).
* **D8 was met for the first time**: the first `.php` here that is not a `.phpt`
  fixture, its PHPUnit tests **6 ok / 0 failed in BOTH worlds**, and a bench that
  reports two ratios because they measure different things -- mc-php wins the whole
  program (5.85x, 1.45x) on php's ~38 ms of start-up and LOSES the work (8x to 23x
  slower than php's VM).
* **Generators are measured and NOT built**: 252 of the 13623 `wrong` tests use
  `yield` and 145 of those use the manual Generator API. The shape is a state machine
  the compiler makes out of the function body (mc has no goto, D7 forbids a VM and a
  second stack); the cheap `foreach`-into-callback shape is correct but serves at
  most 107 and would make the other 145 a trap.

`sh probes/t9/run.sh`. Details: `probes/t9/RESULTS.md`.

## T8 -- the wall was `(does not compile)`, and it is not any more

**green 1218 -> 1450:**
`phpt: green 1450 / wrong 13607 / refused 3026 / skip 2947 / php-fail 365 / total 21030`
over the whole corpus. Per directory: `tests/lang` **93** (was 82), `Zend/tests` **635**
(was 539), `ext/standard/tests/strings` **223** (was 194). **1441 of the 1450 greens are in
T0's "touched by none" set.** `refused` rose 2917 -> 3026 and `wrong` fell 13968 -> 13607: a
test that now COMPILES gets far enough to hit a design refusal it never reached before. The
`php-fail` column is php's OWN and this run had 365 against the previous run's 346 -- the
machine was loaded; five of the nineteen were green in that run and are green again when
re-run with the same binary, so the tree's number is 1455.

T7 left one number pointing at what to do next: **878 of 1460 sampled `wrong` tests DO NOT
COMPILE**, of which **288 name a php function or constant mc-php does not have**. T8 takes the
first apart, group by group, and works the second in descending frequency.

* **`probes/t8/nocompile.py`** (new) is what made the block workable: `whytable.py` prints its
  head as a flat top-22 with no way back to a file, and this reads the SAME `why.tsv`, masks the
  variable part of each message, groups, and prints the count with **three example files per
  group**.
* **References**, 83 of the sample across four messages, and the biggest single theme. A
  by-reference parameter is FREE once the caller's variable is a zval, and what was missing is
  that nothing made it one: the source scan grew two passes, one that finds every
  `function name(... &$x ...)` and one that puts every `$variable` inside a call to one of them
  into the ref set. With that, `use (&$x)`, a by-reference METHOD parameter and `function &f()`
  were small.
* **The lvalue chain**, 71. `ph_lv_walk` walked `[k]` only, so `$a[0]->p = 1`, `$t->x[0][0]` and
  `$c = &$t->list` had nowhere to go; it walks `[k]` and `->p` in any order and to any depth now,
  and `isset`/`empty` read the same chain QUIETLY.
* **A method's `: void`**, 37 -- `ph_skip_type` tested `T_IDENT` and `void` is one of mc's OWN
  keywords, so the skip consumed nothing.
* **The alternative syntax** (all five), **`list()`/`[$a,$b] =`**, **anonymous classes**,
  **a compound assignment to an array element**, **`@` on a statement**, **`$s[9] = "x"`**,
  **`$f();` as a statement**.
* **The names**: files and streams (39 library rows over a php `resource`, which is a zval of
  type `IS_RESOURCE` indexing one table), `pack`/`unpack` (every code, with its repeater),
  output buffering that NESTS, `get_html_translation_table` with php's own 253 entries,
  `fprintf`/`vfprintf`, `serialize`/`unserialize`, `func_num_args`/`func_get_arg`, and nine more.
* **Four defects the blocks found**, none of them in the block being built: the source scans
  read BYTES and a comment is not code (one line of the runtime's own commentary put `$a` in the
  ref set and silenced a D4 refusal); the unwinding check was missing on `return`, so
  `return f();` inside a `try` left the exception pending; a class member's default that is an
  ARRAY literal captured its local before the literal was built, which segfaulted; and
  `lencheck` did not cover `php_str_new("...", N)`, where three lengths were wrong.

`sh probes/t8/run.sh`. Details: `probes/t8/RESULTS.md`.

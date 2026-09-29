# mc-php -- operating rules

Read `docs/plan.md` first. This repository is a CONSUMER of mc's **1.0 frozen surface**
(`docs/reference/hooks.md` § 8 there): it never edits mc's `src/`; a surface gap is reported to mc
with a reproducer, never patched around here. It is BUILT with whatever 1.x is installed -- the
freeze is additive, so a later minor keeps every name 1.0.0 published -- and each probe records
the version it measured on (T5 onward on **mc 1.1.0**, which is what `mc --version`
answers here).

## What this is for

**A compiler that turns PHP source into a native PHP extension** (`.so`/`.dll`): no C, no
`phpize`, no autotools, no php development headers. The front end is the PHP grammar taught to
mc, in `src/`. The back end emits `get_module()`, a `zend_module_entry`, the
`zend_function_entry` tables and the handlers; it was proven by hand in `probes/t1`..`t3` and in
`reference/`, and **it is written** -- `src/ext.mc` plus `lib/php_ext.mc`, for plain functions
with declared scalar parameters and a declared scalar return. `docs/php-extension.md` is what it
takes and what it refuses by name.

The earlier line -- PHP to a standalone binary -- is closed. Its front end is what survives and
it is what `src/` is.

## The rules

- A `.php` file is PHP: it must run under `php` unchanged. No dialect. mc-php accepts a SUBSET:
  no `eval`/interpreter (D1) and static variable types (D4); a refusal is a named compile error.
- The oracle is php-src's `.phpt` corpus under `php` and under the mc-php build; every claim
  carries its green/total number.
- Comments, messages and docs in English; ASCII identifiers; no emojis.
- Every probe under `probes/` prints one number and exits 0 only when it measured it.
- Every `.php` written here has PHPUnit tests run under `php` AND under `mc-php test` (D8), and a
  row in `bench/` timing `php` against the mc-php binary. No PHP lands without both.
  `tests/d8check.py` enforces it: a `.php` in no regime fails the gate.
- One agent at a time; measurements before design; a decision in `docs/plan.md` § 3 is taken only
  by the probe that decides it.

## A project file, not a command line

Exactly as `mc.toml` is to mc, an extension is described by a FILE and `mc-php build` does the
whole road from it: read the file, read the target php, compile, link, write the artefact. **No
make, no cmake, no long command lines, nothing the user has to remember twice.** The schema is
`docs/mcphp-toml.md`; `docs/php-extension.md` § The project file is the part implemented, which
is `[extension].name`, `[extension].version` and the four `[php]` values -- and that is also the
SWITCH: an `[extension]` table means the extension road and no table means the program road, so
there is no flag and there will not be one.

The repository's own build follows the same rule: `mc build` for the compiler, shell only for the
test grid. There is no makefile here and there should not be one.

The schema stays inside the TOML subset mc's own parser already reads (it comes free inside
`<mc/core_build>`) -- no inline tables, no literal strings, no nesting.

## `src/` is the compiler; `probes/` is the record

```
mc.toml        mc build -> build/mc-php
src/*.mc       the compiler, 23 files and one entry per host, included in ORDER (mc is single pass)
lib/php_rt.mc  the runtime, #embed'ed and pushed into every program
lib/php_ext.mc the EXTENSION runtime, pushed only on that road
tests/         the fixtures, the grid driver and the fast gates
examples/      one directory per extension, each gated; a hand-written one says so first
docs/          the plan, the decisions, the mcphp.toml schema, the Zend ABI
probes/        T0..T10. FROZEN.
reference/     the extension road built BY HAND in mc. A record, not mc-php output.
```

**Nothing under `probes/` is ever edited.** A probe's value is that it still answers the number
it published; a probe that gets fixed has stopped being a record. `src/`, `lib/` and `tests/`
were carved out of `probes/t10/`, which keeps its own copies and still runs. A change goes to
`src/` and never to the probe.

`tests/carve.sh` was that carve's own proof and had a short life by design: it built both and
compared the two binaries byte for byte, and it was to be deleted by the first commit that
changed what the compiler does. The hosts branch is that commit and it is deleted.

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
- The EXTENSION back end done (2026-09-23), on **mc 1.1.0**: **a `.php` source compiled into a
  native PHP extension**, which is what this repository is named for and what `probes/t1`..`t3`
  and `reference/` had only proved by hand. Two files: `src/ext.mc` (303) emits one Zend handler
  per exported function and `get_module`, and `lib/php_ext.mc` (357) is everything it calls --
  the 168-byte `zend_module_entry`, the 48-byte `zend_function_entry` table, the 32-byte
  `zend_internal_arg_info` records, the conversions across the boundary and the two refusals in
  php's own words. The emitter knows no Zend offset; `docs/php-abi.md` is the record and
  `tests/ext/abi.c` the oracle, 55 offsets and constants read out of the installed headers.
  * **The switch is the project file and there is no flag**, which is `docs/mcphp-toml.md`'s own
    rule: an `[extension]` table means the extension road, no table means the program road. The
    single-file CLI sees no project file, so `mc-php --exe x.php -o x` is byte for byte what it
    was. `main` becomes `mc_php_minit`, the module's MINIT, so the top-level statement stream
    (`php_bootstrap`, the class entries, a `declare`, a `require`) runs when php loads it.
  * **Scope is plain functions with declared scalar parameters and a declared scalar return.**
    Seven other signatures are a NAMED refusal at the declaration's own position -- `mixed`, an
    untyped parameter, a default, a variadic, a by-reference return, a non-scalar return, and a
    `namespace` (flattening costs a program nothing since T9, but would make the module publish
    `f` where the source says `aw\f`). The BODY is the whole language.
  * **The engine coerces nothing**, measured against a reference extension built the ordinary C
    way: `arg_info` is declarative, ZPP is what enforces in C, and a `zend_long` parameter handed
    `"41"` arrives as the `zend_string *`. So the handler checks the zval's LOW BYTE itself --
    a string carries `0x106` and an object `0x308`, only `IS_LONG` is exactly 4 -- with php's
    STRICT rule always, plus the one int-to-float widening strict mode allows.
  * **An internal function's messages are not a userland function's**, which is why the error
    fixture is not differential: no `called in FILE on line N` tail, an extra argument is an
    `ArgumentCountError` rather than being ignored, and an arity failure is
    `zend_argument_count_error` and not `zend_type_error`. An object gives its CLASS name
    (`stdClass given`, `Closure given`) and a bool gives `true`/`false`, not `bool`.
  * `tests/ext.sh` is the gate, six steps, every one a comparison against something php produced:
    the layout against the headers (55, self-skipping where there is no `php-config` or `cc` --
    the COMPILER needs neither and that is the claim), the four `[php]` values against the target
    php, the build and the LOAD, the **differential** (`examples/hello/check.php` run twice, with
    the `.so` and with the `.php`, byte for byte on each stream and the same exit), the wrong
    calls against `errors.expect` (re-measured from `tests/ext/refx.c` wherever it can be built),
    and the seven refusals. **Green on macos/arm64, linux/aarch64 and linux/x86_64**, each
    against a php 8.5.10 of that host's own, and inside `tests/run.sh` and `tests/linux.sh`.
    The macOS leg runs all six (the runner has `php-config` and `cc`); the Linux legs run four
    and say which two they skipped and why.
  * `examples/` is no longer empty and `d8check.py` gained the SEVENTH regime, `extension`, with
    teeth: an example `tests/ext.sh` does not build is in no regime. `reference/` is a second
    RECORD beside `probes/` -- the extension road written by hand in mc, its README saying so in
    its first line -- and is excluded from D8 for the reason `probes/` is.
  * **What the back end did not close, with the number**: the generated code. The same two
    functions hand-written in mc beat the interpreter **11.1x** on `fib(30)` where mc-php's own
    output managed **3.3x**, and on a 3-million-iteration loop mc-php was **0.78x -- slower than
    php**. Fixed on the `perf` branch: 6.31x and 4.00x, see the entry at the end of this file. `--dump-asm` names it in one look: two real calls per statement, `php_pos` and
    `php_thrown`, and every local in the frame. On the program road that never showed, because
    php starts 38 ms behind; an extension is called from a process that is already warm.
    `docs/plan.md` § 7 is the ordered list, and item 2 is the one that is not the back end's at
    all -- a php ternary allocates per evaluation, so `return $n < 2 ? $n : f($n-1) + f($n-2);`
    exhausts the arena at `f(30)` on the PROGRAM road too.
  * **One mc gap reported, not worked around** (`docs/plan.md` § 5): the project file is read
    with `toml_get`/`toml_int`, which come free inside `<mc/core_build>` and are **not** in
    `tests/golden/surface.txt`. Nothing is asked for in code -- the names exist and behave --
    only that the family mc's own `docs/reference/toml.md` describes be named in the freeze.
  * **The program road does not move, and it is proved twice.** 96 of the 96 `.php` under
    `tests/g/`, `tests/r/` and `tests/bench/` compile to **byte-identical objects** under a
    `main` compiler and this one (the 97th is `28-compile-fatal.php`, which both refuse with the
    same text). And the three graded directories come out at T10's recorded numbers **to the
    test**: `tests/lang` **104**, `Zend/tests` **756**, `ext/standard/tests/strings` **263**,
    measured against a SNAPSHOT of the compiler (T7's rule). The fast gates are green before and
    after: `test` 90/90 fixtures, 6/6 refusals, `d8check` 103 `.php` in a regime, `lencheck`
    554/0 (it caught a wrong byte count in `php_ext.mc` before the commit did), `aritycheck`,
    D8 (a) 6 ok / 0 failed in both worlds, D8 (b) `main.php` 6.80x and `heavy.php` 1.44x.
  * Cost: **314 lines of `src/ext.mc` (220 of them neither comment nor blank) and 379 of
    `lib/php_ext.mc` (253)**; the front end moved **+22 lines across six files**, every one of
    them guarded by `ph_ext`.
- T10 done (`probes/t10`), on **mc 1.1.0**: the review backlog -- 59 Copilot findings across
  #1..#7 that nothing had acted on (`docs/review-backlog.md`), all three sections, plus one
  the sections did not name and a disk that ran out. **green 1637 -> 1697**:
  `phpt: green 1697 / wrong 14481 / refused 1929 / skip 2947 / php-fail 341 / total 21054`;
  per directory `tests/lang` 104 (was 102), `Zend/tests` 756 (was 709),
  `ext/standard/tests/strings` 263 (was 262). The corpus figure was 1689 with
  `Zend/tests` 749 when the review of #9 opened; the +8 is the argument-type
  checks of round fifty-three, re-measured against the compiler the pull
  request ends with. **1664 of the 1689 greens are in T0's
  "touched by none" set**; `refused` fell **2309 -> 1929**. The green moved only +52 because
  the work is CORRECTNESS -- a `.phpt` that was already green does not become greener for the
  compiler being right about short circuit -- and what the probe is worth is the corrected
  numbers below.
  * **Four tools reported numbers they had never measured**, and they are what chose every
    block since T5. They are one tool now, `probes/t10/harness.py`: stdout byte for byte AND
    the same exit code, which is the pair the grid itself grades on. `why.py` labelled a test
    `(compiled; output differs)` WITHOUT running the binary -- of 781 sampled tests that
    compile, **757 really differ**, 22 crash, 2 time out and none agrees on both (31 more are
    a php COMPILE-TIME fatal: no binary, and the grid grades the pair on the text both sides
    print). The clustering of the 757 is worth the sample: **332 are `var_dump of a value`** and its head
    is `php 'int(N)' / mc ''` -- php printed a value and mc-php printed nothing, a program
    that stopped early rather than a value formatted wrongly.
    `arena.py` divided by `len(files)` while turning every failure into `None`: of the
    1352-test list only **782 RAN**, so the rate understated by 1.7x. `fixtures.sh` merged the
    streams with `2>&1` and compared with `$(...)`, which strips trailing newlines.
    `bench/bench.sh` in t7 and t8 built and timed **t6's** compiler. `<test>.why.php`
    clobbered a sibling of that name. And `nocompile.py`'s skip list named ONE compiled
    outcome of five, so the other four were counted as tests that do not compile: that block
    was published as 737 and is **539** -- the reviewer of this probe's own pull request
    caught it, in T10's first draft. **Sixty-one review rounds in all**, ending with one that
    raised nothing and left nothing open; six of them found a SEMANTIC defect in the compiler
    (a spread argument that throws, a by-reference coercion storing its own failure, a closure
    capture sharing the outer array, an object spread that was fatal instead of catchable, a
    declared argument type that was never checked, and a throwing `return` that jumped over its
    `finally`) and one found the first LIBRARY defect (`array_diff_key` answering by value).
    Round seventeen raised
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
    run now: **6 ok / 0 failed in each**, `main.php` 6.54x, `heavy.php` 1.43x (the committed record).
  * **D8 over the fixtures** (backlog § 3): the plan states the exemption -- the unit D8
    governs is the PROGRAM, and a differential fixture is already a test and a stronger one --
    and `probes/t10/d8check.py` ENFORCES it, putting every `.php` in one of six regimes -- fixture, refusal, helper, instrument,
    library, bench, and `refusal` and `helper` are NOT differential fixtures -- and
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
  Fixtures: **89 of 89** numbered under `g/` byte for byte php's on each stream and the exit code,
  **6 of 6** under `r/` refused by name with exit 3; `lencheck` 514 / 0 wrong, `aritycheck`
  273 / 0 wrong, `d8check` 102 `.php` in a regime and 370 under `probes/` swept for orphans. **No new mc gap**, and no new external
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
- The generated code, two of its three causes (2026-09-23, branch `perf`), on **mc 1.1.0**:
  `docs/plan.md` § 7 item 1, the whole claim of the extension road. `reference/README.md`
  recorded **0.78x on a 3-million-iteration loop -- slower than php** and `--dump-asm` named the
  cause in one look: two real calls per statement, `php_pos` and `php_thrown`, whatever the
  statement contained.
  * **The rule: a statement announces its position only when something in it can raise a
    diagnostic or throw, and is followed by the unwinding check only then.** Everything that can
    raise in this compiler is a runtime call and `ph_call` marks every call it builds, so that
    mark is the test -- conservative in the safe direction, a call that cannot raise still asks
    for both, which costs nothing because the population this removes is the statements with no
    call at all.
  * **The defect underneath was `php_pos` itself.** `ph_posstmt` builds its call with `ph_c2`,
    which goes through `ph_call`, and it runs AFTER the statement body -- so every statement in
    every program came out "can throw" and got the check, and no statement anywhere could ever be
    quiet. `$s = 0;` paid two calls to store a literal. One save/restore around that one call.
  * **A duplicate announcement**, its own defect and its own commit: `for ($i = 0; ...)` lowered
    its init with `ph_stmt()`, which prepends a `php_pos`, and the `for` itself got another at the
    same line from the `ph_stmt()` above it -- the second overwriting the first before anything
    could read it. `ph_is_pos_at` descends through a BLOCK (whose first statement runs whenever
    the block does) and never through a loop or an `if`. Over the 92 fixtures, with a counter that
    requires nothing between the two `bl _php_pos` but the second call's own setup: **1236 emitted
    / 7 duplicates -> 1229 / 0**.
  * **`%` by a literal the compiler can see is positive** is `sdiv`/`msub`, not `php_mod`:
    DivisionByZeroError is the only thing `%` can do besides the remainder, and a positive literal
    rules it out. The same shape as the literal exponent beside it. Positive and not merely
    non-zero, because php answers 0 for `PHP_INT_MIN % -1` and a native divide is where that stops
    being free.
  * **Measured** (`reference/bench-steady.php`, new -- a warm-up and the best of nine, nine
    processes interleaved, because `reference/bench.php` times ONE cold call each and that carries
    a **2.5x code-alignment band** on this host: two builds of the same source differing only in
    the module's NAME gave `sum` 5.9 ms and 1.9 ms):

    | | interpreted | by hand | before | after |
    |---|---|---|---|---|
    | `fib(30)` | 30.4 ms | 2.78 ms (11.0x) | 9.62 ms (3.18x) | **4.82 ms (6.31x)** |
    | `sum(3000000)` | 9.05 ms | 1.65 ms (5.5x) | 10.55 ms (**0.86x**) | **2.26 ms (4.00x)** |

    `--dump-asm` of `mcb_sum` is **call-free**. The statement-count experiment the report rested
    on is re-run and inverted: the same arithmetic in one statement and in four was **6.03 / 15.07
    ms, 2.50x** before and **3.99 / 4.15 ms, 1.04x** after, against php's own 1.43x -- time scales
    with the work now and not with the statement count.
  * **A pre-existing SIGFPE the new fixture found**, on the leg that runs it: linux/x86_64 came
    back 91 / 92 with `93-mod-literal.php (php exit 0, mc-php exit 136)`, and 136 is 128 + 8.
    x86-64's `idiv` raises #DE for `PHP_INT_MIN / -1` because the quotient does not fit;
    AArch64's `sdiv` wraps, so every one of these read correctly on the host this repository is
    developed on and killed the process on the other two. A compiler built from `main` crashes
    identically. Four sites, each given php's own answer rather than a shortcut, because php has
    three: `php_mod` -> 0, `php_zv_div` -> the float, `php_intdiv` -> `ArithmeticError` with php's
    own message, `php_div_i` guarded so its caller's guarantee stays one.
  * **The gate this needed**, `tests/g/92-diag-line.php`, differential like every other fixture so
    php says what the right line is: eight shapes, each a raise whose NEIGHBOURS are now silent --
    after a plain store, inside a loop whose condition and step are native, a throw caught and
    asked for `getLine()`, a raise after a call has already moved the position, two raises on
    consecutive lines, a raise inside a function after silent statements, a throw from a deeper
    frame. **Proved to have teeth**: with the announcement suppressed outright the fixture gate is
    **76 / 91** and this file is one of the failures. `tests/g/93-mod-literal.php` is the `%` one.
  * **The three graded directories do not move, and it is checked test for test and not by the
    count**: `tests/lang` **104**, `Zend/tests` **756**, `ext/standard/tests/strings` **263** --
    and `diff` over the green, wrong, refused, skip and php-fail lists of all three, between a
    snapshot of `main`'s compiler and this one, is **empty in all fifteen**.
  * Gates: `tests/run.sh` green on macos/arm64 (fixtures **93 / 93** on both streams and the exit
    code, refusals 6 / 6 + 8, `lencheck` 556 / 0, `aritycheck` 272 / 0, the extension road, D8 (a)
    6 ok / 0 failed in both worlds, D8 (b) `main.php` 7.06x and `heavy.php` 1.43x); the fixture gate
    green in CI on **linux/aarch64 and linux/x86_64**, 93 / 93 each, against a php of that host's own.
  * **The review, three passes, each finding reproduced before it was fixed.** (1) A throwing `for`
    initializer: did not reproduce (its mark reached the condition's check), but writing the fixture
    found a throwing STEP running the body again -- fixed by checking each part on its own mark
    (`bb54e3c`, `tests/g/94-for-init-throws.php`). (2) A stale fixture header, and behind it a
    pre-existing parse defect: `for ($i = 0;; $i++)` was refused (`expected ; in for`) because the
    empty condition's `;` was consumed as the initializer's (`8ad845a`, three more cases). (3) This
    PR's own regression: a diagnostic from a `for` CONDITION named the previous statement's line,
    since zeroing each part's mark left nothing to make the `for` announce its own; the `for` now
    carries the union of its parts' marks up (`c0b7cc4`, `tests/g/92-diag-line.php` case 8, proved
    to fail with the line reverted). `while`/`if`/`do-while` probed the same way and were right.
    The two new fixtures also dropped `declare(strict_types=1)` (`ff866b6`): mc-php is strict by
    definition, and both stay byte for byte php's without it.
  * **What is left, named with its number**: every local still lives in the frame, which is the
    whole of the remaining 1.4x on `sum` and most of the 1.7x on `fib`; and the unwinding check is
    still emitted after ANY runtime call, not only one that can throw -- narrowing that needs a
    per-callee classification of the 179 library rows, a whitelist whose wrong entry is a silently
    wrong line, so it is named rather than guessed.
- Windows done (2026-09-23, branch `windows`), on **mc 1.3.0** -- CI and release moved from 1.1.0
  to 1.3.0 on every leg, with the macOS gates re-run green on it first. **mc-php built ON
  windows/x86_64 (`windows-latest`) and windows/arm64 (`windows-11-arm`), never cross-built
  across operating systems**, and graded there by `tests/windows.sh`: **94/94 fixtures, 6/6
  refusals, the extension gate green (check.php 24 lines byte for byte, errors.php 14 wrong calls,
  8 refusals)** on both, against the runner's own php 8.5 (8.5.10 x64 and 8.5.11 x64-emulated).
  * **The compiler is the object + `lld-link` road**: `src/mc-php-windows-*.mc` compiled by the
    runner's mc.exe and linked next to `mcrt.obj` (`<sys_windows_host>`), `winstart.obj`
    (`<sys_windows_start>`) and a kernel32 import library, all three written by
    `tests/winsys.sh` (`lld-link -lib -def:src/win/*.def` -- no `llvm-dlltool`). The one-step PE
    is closed by mc: mc 1.3.0 fixed the `duplicate #define` half, and the second half is
    `extern` + a definition of the same name in one unit, `function declared twice`, reduced to
    three lines in `docs/plan.md` § 5 and reported. `src/host_extra_windows.mc` is `realpath` over
    `GetFullPathNameA`, answering '/' because every mc path function cuts on '/'.
  * **The runtime DEFINES its system calls on Windows** (`lib/rt_host_windows.mc`, over kernel32;
    libm and `setlocale` from ucrtbase.dll through `#dylib`), and a program on windows/x86_64 is
    mc's one-step PE (19 kernel32 + 18 ucrtbase imports, nothing else). windows/aarch64 has no
    direct PE in mc, so a program there is an object + `lld-link` (`MCPHP_WINLINK` in
    `tests/mcphp.sh`). `lib/rt_host_windows_start.mc` is the program's `mc_start`, pushed on the
    program road only (an extension has no `main`).
  * **What the first run found (90/93, and the module refused)**, each fixed at its root: a
    drive-letter path is absolute; php PRINTS backslashes, so the compiler keeps '/' and
    `ph_disp` converts at the five places a path is printed; `dirname`/`basename` are ports of
    zend_dirname/php_basename asking the host what separates, how a root is written and whether
    `C:` is a drive (`tests/g/95-paths.php`, 22 paths, 94/94 on all five hosts; the rewrite also
    fixed `dirname("")` and `dirname("a//b")` on POSIX) and `setlocale` applies php's Windows-only `xx_YY`
    refusal (`php_setlocale`, a host answer); `PHP_EOL` is `"\r\n"`; `_emalloc` is `__vectorcall`
    in an MSVC php and exported as `_emalloc@@8` (`_emalloc == _emalloc@@8` in `src/win/php8.def`).
  * **The extension is an x64 `.dll` on both Windows hosts**: php publishes no arm64 Windows build,
    so php on Windows-on-ARM is x64 emulated and loads x64 DLLs; `examples/hello/mcphp.windows.toml`
    says `arch = "x86_64"` and the arm64 mc-php cross-compiles across ARCHITECTURES for it. Link:
    `lld-link -dll -noentry -export:get_module` against `php8.lib`, `kernel32.lib`, `ucrtbase.lib`.
  * Release: `build-windows` builds, grades and packages both Windows archives on their runners
    (five archives now); `publish` needs it. `.gitattributes` is `* -text`.
  * The roadmap the owner set is `docs/plan.md` § 7: Windows (this), examples as the first gates
    (hello, extA/extB, awaitable, then a fixed-point decimal and a large-volume database), ctype,
    bcmath, json, then distribution (Composer/Packagist/PIE) to be designed with the owner.
- Examples (2026-09-23, branch `examples`), roadmap item 2 of `docs/plan.md` § 7, four of five
  parts: `examples/decimal` **compiled from PHP** (exact fixed-point decimals, half-even; the
  differential 60 lines byte for byte, 1219 results against bcmath where php has it, the bench
  row **0.51x** on macos/arm64 -- slower, string work), `examples/two-extensions` and
  `examples/awaitable` as **hand-written mc** labelled so, each beside the PHP source whose
  refusal its gate PINS, and two mc-php extensions measured to coexist in one php. The gate is
  `tests/examples.sh` (inside `tests/run.sh`, `tests/linux.sh`, `tests/windows.sh`; the
  hand-written halves are plain mc, POSIX only, and skip by name on Windows or without an mc;
  the Linux CI legs install mc's static Linux release for them). Two front-end defects the
  examples found are fixed with a fixture each (a static method's arguments, an elseif with a
  string condition); `str_replace` with an array search is recorded, not fixed. The database
  example is the next part, and what it needs is in § 7.
- Batch A (2026-09-24, branch `batch-a`), on **mc 1.1.0** here and 1.3.0 in CI: what an extension
  needs to live inside a real, long-running php, seven items and a C twin, each with a gate that
  fails on `main` and passes here.
  * **The Zend Memory Manager on the extension road (owner's decision; D7 SUPERSEDED there,
    `docs/plan.md` § 3).** One allocation seam, `php_alloc`, two implementations by road: the
    arena (a program, and a module's MINIT) or a 32 KiB Zend chunk an extension call bumps
    through, zeroed again and every extra block `efree`d when the call returns
    (`lib/php_ext.mc` § the call's memory). A string argument is BORROWED (the runtime's string
    is a `zend_string`, immutable here); a result in a block of its own is handed over, a small one
    copied once. A call that writes module state (`static`, `global`, `define()`, a handler, a
    class, a file, a destructor, an open ob level) PINS itself (`php_pin`, fifteen call sites): its
    blocks stay until the request ends, and the new `request_shutdown_func` puts the state back as
    MINIT left it -- statics reset, files closed, the runtime's roots and the MINIT arena (127 KB
    for decimal) restored from a snapshot. Measured: `examples/decimal/soak.php`, **1 000 000
    `dec_add` calls in one request, peak 515 336 -> 515 336 bytes** (before: `arena exhausted`
    between 28 000 and 30 000); `tests/ext.sh` step 10, **20 requests through `php -S`** with a
    static counter, a `global` and 4 MiB kept per request, every response the interpreted
    source's (before: statics leaked across requests, the server died at the twelfth). A pinned
    call costs 32 bytes a call until the request ends (a `static` counter, 100 000 calls).
  * **Module-private functions**: a leading `_` is not published (`tests/ext.sh` step 9; before,
    `function_exists("_dec_valid")` was true), and an unpublished function's signature is free.
  * **A declared scalar RETURN is checked** on both roads through `php_param_coerce` with the
    return-value sentence (`tests/g/99-return-type.php`, `tests/ext.sh` step 8; before, `int(0)`).
  * **A php ternary allocates nothing** when both branches share a native type
    (`tests/g/98-ternary.php`; before, `fib(30)` exhausted the arena).
  * **`str_replace` takes php's whole signature** (`tests/g/100-str-replace-array.php`).
  * **Output goes through `php_output_write`** on the extension road (one sink, `php_out1`), so
    `ob_start()` captures a module's echo (`examples/hello/check.php`, 26 lines).
  * **`declare(strict_types=0)` is refused by design** (D4; `tests/r/d4-strict-types-0.php`), `=1`
    is a no-op, and mc-php sources no longer carry it; php CALLER files keep it.
  * **The C twin**, `examples/decimal/c/decimal.c`: 60 lines byte for byte, bcmath 1219 / 0 wrong,
    and the bench's third column (macos/arm64, one core held by another process throughout):
    interpreted 3.29 ms, the module **6.48 ms (0.51x) before and 6.41 ms (0.51x) after**, the C
    twin **0.238 ms (13.8x)**. The owner's acceptance rule is in `docs/plan.md` § 7: an example is
    done only when compiled from PHP AND faster than interpreted, with its C twin beside it --
    so `decimal` is not done yet; the string path is batch E.
  * **The grid**, three directories against a snapshot of `main` measured the same day:
    `tests/lang` 104 = 104; `Zend/tests` 762 -> 763 (+3 green; the two `strict_types=0` greens
    and three `strict_types=0` wrongs are now refused by design, which is item 7); strings
    265 -> 271 (+6, `str_replace` with arrays). `diff` of the five lists accounts for every move.
  * **One mc gap recorded** (`docs/plan.md` § 5): `&name` of an `extern` is an `adrp`/`add` that
    neither Apple's ld nor ld.lld links into a loadable module; `lib/php_ext.mc` takes the
    address of a local wrapper instead.
  * **The review of #19**, seven rounds, each finding reproduced before it was fixed or refuted
    with a measurement: `phx_zero` could store past a chunk's end; a scalar function that FALLS
    OFF its end is php's `none returned` at the closing brace, and a bare `return;` in a typed
    function is php's compile-time fatal with its `#0 {main}` trace (`tests/g/99`, `101`);
    `php_dt_arm` pinned every `new`, so 200 000 calls making a `stdClass` exhausted php's 128 MiB
    limit (`tests/ext.sh` step 9b, now 32 768 bytes); and a module's `ob_start()` was the
    runtime's private stack, so the script's echo after the call escaped it -- the ob_* functions
    are php's own output layer on this road now (step 10's second and third lines).
- Batch E (2026-09-24, branch `batch-e`, PR #20), on **mc 1.1.0** here and 1.3.0 in CI:
  **`examples/decimal` past php, and DONE by `docs/plan.md` § 7's rule** -- 6.46 -> **1.51 ms,
  0.51x -> 2.19x** interpreted on macos/arm64 (the C twin 0.241 ms, 13.8x), and 1.52x to 2.99x on
  the five CI legs. `decimal.php` is unchanged: every gain is in the compiler and its runtime,
  chosen from a `sample` profile (allocation 19.6%, strspn's per-byte `php_inset` 10.6%, a
  byte-loop `php_memcpy` 10.2%, `php_pos`/`php_thrown` calls 6.5%, `php_strlen` as a call 5.8%,
  zvals built only to call a library row 6.6%). `docs/plan.md` § 7 item 1 has the table of what
  each change bought; the largest single step is **`[project].opt = 1` in the project file of
  every extension built from php** (hello, decimal; mc's `-O`; 2.79 -> 1.64 ms), which a taught compiler cannot set for itself.
  * Compiler: the position and the unwinding check written in place (`ph_dfile`/`ph_dline`
    stores, a `ph_exc` load); `strlen` loaded in place; every literal built once by
    `ph_lit_init` and each use one load; literals, `strlen`, the native strspn/trim forms,
    `str_replace` of three strings and `$s[$i] ?? d` are quiet (`ph_quiet`); `$s[$i] === 'c'`
    compares the byte; `(int) substr(...)` reads the window in place; an int key reads/writes an
    array without a key zval; a fresh zval is not copied again; a zval against a native int
    passes the int unboxed.
  * Runtime: 8-byte `php_memcpy`; 256 shared one-byte strings (`php_str_ch`); byte maps for
    strspn/strcspn/trim masks, a literal's built once per run (`php_bmap_lit`); strpos
    first-byte scan; one-pass and one-byte `str_replace`; zval `+ - *` int-and-int in place.
  * Fixed on the way, with fixtures: `-1 * PHP_INT_MIN` through zvals was `int(PHP_INT_MIN)` on
    arm64 and a SIGFPE on x86-64 (`tests/g/103`); `$s[$i]` out of range was silent on the native
    road (`tests/g/102`); five `printf` tests were FALSE refusals (a literal format spilled into a
    temporary because a later literal "could throw"). Found and not fixed (pre-existing): a
    17-digit shortest float's last digit, and `2 * "abc"`'s operand order in the TypeError.
  * The grid against a snapshot of main: `tests/lang` 104 = 104, `Zend/tests` 763 -> 766,
    strings 271 -> 272, no test out of green. `tests/run.sh` green; D8 (b) `heavy.php` 1.85x.
- Decimal-c (2026-09-24, branch `decimal-c`), on **mc 1.1.0** here: **`examples/decimal` from 6.3x
  the C twin's time to 4.1x** -- the module 1.514 -> **0.98 ms**, interpreted 3.29 ms (3.3x), the
  twin 0.240 ms (13.7x), macos/arm64; on the five CI legs 2.49x to 4.62x interpreted (main after
  batch E: 1.36x to 2.98x), macos-15's module/C 7.3 -> 4.7. `decimal.php` unchanged. Profile first (`sample`, 4262
  samples): batch E's `_dec_umul` cause confirmed (12.9% of the module in array/zval calls) and
  allocation confirmed (13.1%); the "prologue saves registers it does not use" cause CORRECTED --
  805 of 805 functions save exactly what they use; what costs is that mc gives a leaf function
  callee-saved registers and has no immediate operands (`docs/plan.md` § 5, reproducer).
  * **A packed int array** (`src/packed.mc`): a token scan per plain function proves a local array
    holds only ints under keys 0..n-1 and never leaves the function; it becomes `php_pk_*`, a
    native i64 buffer from `php_alloc`. The scan predicts static types and the lowering checks each
    prediction (a disagreement is a compile error). A missing key is php's warning and null; a
    key past the end turns the buffer into php's hash in place. An element read (`PT_INULL`) is an
    int beside a number and the zval php has elsewhere. `tests/g/105` (accepted), `tests/g/106`
    (17 refusals of the proof), and `tests/fixtures.sh` reads the lowering back.
  * Compiler: a cast binds as tightly as unary minus (`(int) "1.9" + 0.5` was int(2),
    `tests/g/107`); byte maps built with the literals; `str_pad((string) $int)` fused; `===`
    between strings is `php_str_eq`; two nested one-byte `str_replace` deletions are one pass
    (`php_str_del2`); `$s[$i] === 'c'` in place; `strpos($s, 'c')` is `php_strpos1`; a
    concatenation chain is one string (`php_str_cat3`/`cat4`, `tests/g/110`).
  * Runtime: word-at-a-time `php_memchr`, one-pass one-byte `str_replace`, a copy's tail one word,
    `php_str_alloc` bumps the chunk itself, `array_fill` with a negative count throws php's
    ValueError (it returned `[]`).
  * The grid: `tests/lang` 104, `Zend/tests` 766, strings 272, every one of the fifteen lists
    identical to main's (`comm`), re-run on the final tree. `tests/run.sh` green. The one deviation, named: `+ - *` on a
    packed element that overflows is an `ArithmeticError` saying php would make a float (never a
    wrapped int), and a store whose value throws is not reached. `**` between ints is php's
    `pow_function_base` (it wrapped on main: `(PHP_INT_MAX - 1) ** 2` was int(4)). Found and NOT
    fixed, on record in § 7: native int arithmetic wraps on overflow (D10 says it promotes), an
    array local assigned on one path only is a SIGSEGV on the other, an assignment from anything
    that throws clobbers its target, and the float printer is not shortest-round-trip.
- Zend-mm (2026-09-24, branch `zend-mm`), on **mc 1.1.0** here: **the full Zend memory model for
  STRINGS on the extension road**, the owner's direction that batch A delivered by half. A string
  a call builds is one `_emalloc` block laid as a `zend_string` (refcount 1, `GC_STRING`), freed
  with `_efree` -- `free(3)` for a persistent one -- when its last reference goes, as php's
  `zend_string_release`; a string RESULT is that same `zend_string` handed to `return_value` (no
  copy); a refcount-1 string grows in place with `_erealloc` on `.=`, `$s = $s . a . b` and
  `$s[$i] = c`; literals, one-byte strings and everything MINIT builds are module memory flagged
  `IS_STR_INTERNED`; nothing is zeroed (the 56 `php_str_alloc` and 29 `php_alloc` sites audited).
  Who holds a reference: a POOL of temporaries drained at every loop top and return (`src/rc.mc`,
  a pass over each finished php function), COUNTED SLOTS for a function that loops (a store takes
  the new reference and releases the old, written in place), BORROWING for one that does not, and
  `php_str_esc` for a string put into a zval, an array key or a class entry -- which stay in the
  call's chunk (why: `docs/php-extension.md` § The memory). `lib/php_prog.mc` is the program
  road's half; the program road keeps its arena and is unchanged unless compiled with
  `MCPHP_RC=check`, which counts arena strings and POISONS one at zero so the grid and the
  fixtures grade the discipline (`tests/mcphp.sh` passes it as `MCPHP__RC`).
  * Gates, each failing on main where it can: `tests/ext.sh` step 11 (`MCPHP_STATS=1`: 100 002
    writes in place, 2 copies; main exhausts php's 128 MiB), step 12 (100 000 iterations in one
    call building 2 KB each move the peak 0 bytes; main exhausts memory_limit), step 13 and
    `tests/g/111` (the ownership shapes, module and fixture, normal and check mode), the soak
    bounded to 1 KiB (usage 517 336 -> 517 336, peak 517 544 -> 517 560), the 20-request
    `php -S`, the ABI gate grading the runtime's string flags too, and `tests/leaks.sh` -- a debug
    php 8.5.10 in docker (Lima VM): no block left in any request, and 27 leaks reported when
    RSHUTDOWN's release is disabled.
  * `examples/decimal`, head to head in one sitting: interpreted 1.70-1.79 ms, main's module
    0.524 ms (3.25x, module/C 4.19), this batch **0.606 ms (2.81x, module/C 4.85)**, the C twin
    0.125 ms. SLOWER, and the profile says why (`docs/plan.md` § 7 item 1): memory 15.0% -> 18.8%
    of the module's time, eleven strings a call each an `_emalloc` and an `_efree`; the first,
    call-per-store version was 0.858 ms and the counting as calls was 42% of the time.
  * On the five CI legs (main run 36056378453 -> run 36078460677), the module's bench:
    macos/arm64 0.774 -> 0.906 ms (C twin 0.159 / 0.172), linux/aarch64 1.169 -> 1.445,
    linux/x86_64 1.399 -> 1.850, windows/aarch64 1.895 -> 2.640, windows/x86_64 1.630 -> 2.007;
    the soak's usage moves 0 bytes on every leg (40 on main), its peak 16. Every leg green.
  * The phpt grid, three directories, main vs this branch vs this branch in check mode: every one
    of the 15 lists holds the same test names (`comm -3` empty), green 104 / 766 / 272 in all
    three, and no check-mode output carries the dead-string message. The check run found one
    compile error -- a valued `return` in a `void` function named a slot void functions never
    declare (`Zend/tests/void_disallowed2.phpt`), fixed; the thirteen other rows whose recorded
    exit code moved are programs php refuses at compile time, for which mc-php prints nothing and
    exits with a register's leftovers, main and this branch alike for the same layout.
- Core-strings (2026-09-25, branch `core-strings`), on **mc 1.1.0** here: **`examples/decimal`
  from 0.608 to 0.434 ms, module/C 4.86 -> 3.47** (interpreted 1.744, the twin 0.125, one sitting,
  nine rounds interleaved; inlining off 0.479, the machine off 0.510), `decimal.php` unchanged -- the owner's reading of zend-mm: the core
  lacked optimisation. Profile first (`sample`, and `xctrace` mapped to instructions), and a count
  the runtime now keeps (`MCPHP_STATS=1` prints `strings built N`): per call `dec_add` 8 -> 5,
  `dec_sub` 10 -> 7, `dec_mul` 13 -> 11, `dec_cmp` 2 -> 1, `dec_div` 34 -> 14, gated by
  `tests/examples.sh`. Four mechanisms, each with a gate that fails without it:
  * **Windows of a concatenation** (`src/opt.mc`, a pass after `src/rc.mc`): a `.` chain with
    `substr()` pieces is `php_str_catwN` over (string, start, length), the substrings never built;
    an empty side answers the other operand (php's concat_function); trim/substr/chr answer the
    shared empty and one-byte strings. `tests/g/112` + a lowering read-back in `tests/fixtures.sh`.
  * **Inlining** (`src/opt.mc`): a plain, loop-free function of at most 450 nodes (counted after its own inlining) is copied, as its
    finished pre-rc tree, into every caller declared after it; returns become stores (an early one
    nested under a continuing `if` goes behind a flag), parameters locals or the caller's own local,
    the copy's literal uses turned into cache loads at `ph_lit_finish` too, the caller's position
    re-announced after a copy that moved it. `MCPHP_INLINE=0` turns it off. `tests/g/113` + read-back.
  * **A peephole machine** (`src/mach.mc`) derived from mc's arm64 and both x86-64 tables (over
    `<float>`'s): immediates, the address add folded into the access, one branch per loop exit, a
    fresh boolean's cast/`!`/branch, a lone constant or global load written into its local, and a
    global's access carrying its page offset (band 500..501). `MCPHP_PEEP=0` turns it off.
    `tests/g/114` + a read-back of both machines' dumps. It reaches mc names that are documented
    but not frozen (the `Ins` buffer, `I_*`/`X_*`), so it is on only for mc 1.1-1.3 (`mc_version()`):
    `docs/plan.md` § 5, reported.
  * **The handler** (`src/ext.mc`) reads and checks an int or string argument in place.
  Measured and dropped: a leaf's locals on `x0..x7` (+1%), range masks for trim/strspn (0%).
  The grid: `tests/lang` 104, `Zend/tests` 766, strings 272, plain and `MCPHP_RC=check`, all 30
  lists identical to main's (`comm -3`). `tests/leaks.sh`: no block left. fib/sum module unchanged.
- Same-algorithm (2026-09-27, branch `decimal-same-algorithm`), on **mc 1.1.0**: `examples/decimal/decimal.php`
  rewritten after `c/decimal.c` function by function (parse once, a digit at a time, results
  written into strings of the right length), so the three columns measure ONE algorithm; `check.php`
  byte for byte, bccheck 1219 / 0 wrong. On main's compiler that was 0.941 ms (module/C 7.41); the
  compiler and runtime took it to 0.398 ms, module/C 3.13 -- **0.417 ms, 3.31, 6.27x the
  interpreter** after the review (a loop whose slow halves can raise a diagnostic keeps its pool
  drain: the text is built in the pool, 8.4 MB for 100 000 out-of-range reads, `tests/ext.sh` step
  12b; str_repeat with a negative count is php's ValueError, `tests/g/116`) (1.725 ms on
  the old source, 2.641 on this one; the twin 0.127), one sitting, nine rounds interleaved, each
  change with its own number in `examples/decimal/README.md`: `ord($s[$i])` and `$s[$i] = chr(c)`
  / `= STRING` read and written in place (`php_str_byte`, `php_str_setb`/`sets`), the runtime's
  small routines copied into the compiled code AFTER `src/rc.mc` (`src/opt.mc` `phr_*`, each a fast
  path plus a `_slow` half), the position and the unwinding check moved into those slow halves and
  a check nothing can have raised before dropped, one unwinding tail per function (the checks
  `break` out of a loop around the body), a `for` step with no flag when there is no `continue`,
  branchless int-literal ternaries, no pool drain in a loop that builds nothing, a packed array's
  length 0 once hashed (one bound test), `intdiv` copied, `strspn` with a literal set a
  three-argument routine, `str_repeat` of nothing the shared string. `phi_is_ann` is exact now (a
  loop body that begins with a flattened announcement was taken for one). Gates: `tests/g/115` +
  a read-back in `tests/fixtures.sh`; the strings gate re-recorded 700 700 800 300 10700 (the twin's
  division by repeated subtraction answers a new remainder per step). What is left, measured: php's
  checks 0.037 ms (c), strings as values (c), mc's ten-register allocation (b, unproven -- copying
  `strspn`'s loop into callers made it 8% slower). The grid: `tests/lang` 104, `Zend/tests` 766,
  strings 272, plain and `MCPHP_RC=check`, all 30 lists identical to main's. `tests/leaks.sh` and
  `tests/linux.sh` (aarch64) green.
- Instruction selection (2026-09-27, branch `decimal-isel`), on **mc 1.1.0**: the (b) codegen items
  of `examples/decimal`'s hot loops, each BOUNDED first by hand-patching the built module (fifteen
  rounds interleaved, best of nine). `_dec_umul`'s inner loop with all four applied: 0.387 ms
  against 0.409-0.416; one taken out at a time: the slow halves out of line 0.016 ms, index
  arithmetic ~0.005, scaled addressing ~0.004, the fused overflow test ~0.001; removing the pool
  test outright made the module SLOWER (0.410 against 0.393), so no cheaper form was built. Built:
  **P10** in `src/mach.mc` on the arm64 and both x86-64 machines -- after the frame fixup, a
  straight-line region the code jumps over whose first call is a `_slow` routine, `php_rc_drain`
  or `php_pk_overflow` moves past the epilogue and the branch over it goes (inverted when the region
  was the fallthrough); a function with `emit()`/`reloc()` is left alone. `MCPHP_LAYOUT=0` turns it
  off alone, and with it every `tests/g` dump on the three machines is byte for byte main's (345 of
  345). Module 0.413 -> **0.393 ms**, module/C 3.30 -> **3.13**, 6.67x the interpreter. Measured
  and not kept: P11 (no copy out of a local's register for a cast to 8 bytes, 0), scaled addressing
  module-wide (0), `a && b` as two branches (0), and -- re-bounded on the P10 module at the owner's
  request -- the loops' frame loads in caller-saved registers (`_dec_umul` <=0.001 ms, `_dec_uadd`
  0.012 ms SLOWER). Gates: the read-back `out of line` in `tests/fixtures.sh` (g/115 on the three
  machines, on and off); fixtures 114/114 plain, `MCPHP_RC=check` and `MCPHP_LAYOUT=0`; the grid's
  30 lists identical to main's; bcmath 1219 / 0, the soak; `tests/leaks.sh` and `tests/linux.sh`
  (aarch64) on mc-k7; `tests/linux.sh x86_64` under Rosetta 114/114 twice, its `requests` step
  failing there on main's compiler too. No new instruction form: the non-pc-relative sweeps are the
  same sets as main's on four object formats, and 15 714 arm64 branches re-assemble byte for byte.
  Review (Copilot, the branch reach): mc's arm64 encoder refuses ANY branch past 0x1ffff words
  (`branch too far`, its `br_off`, `b` included), so a moved region could never assemble wrong, but
  it could turn a function main compiles into one mc refuses -- reproduced with a generated 131 114-
  word function (main's longest branch 131 067, the moved one 131 090). P10 now stands down on arm64
  when the function plus one `b` per region exceeds 0x1ffff words; x86-64's jmp/jcc are rel32.
  Gate `reach` in `tests/fixtures.sh` (fails before, passes after); every other object unchanged.
- C semantics (2026-09-27, branch `decimal-cmode`), on **mc 1.1.0**, the owner's decision: a
  compiled program behaves as C does where C and php part ways, BY DEFAULT (`docs/semantics.md`
  lists every difference). An int that overflows in `+ - *` (and unary `-`) on a packed element
  wraps instead of the overflow test; `$s[$i]`, `ord($s[$i])`, `$s[$i] === 'c'` and `$a[$k]` on
  a packed array read with no bounds check (`php_str_byte_c`, `php_str_off_c`, `php_pk_get_c`,
  copied into the caller like their php twins), so a read outside the range is undefined
  behaviour. A negative offset spelt as a literal (`$s[-1]`), `??` reads, stores, division and
  modulo by zero and `intdiv(PHP_INT_MIN, -1)` stay php's in every mode. Chosen, the first that
  says: `MCPHP_SEMANTICS` in the compiler's environment, `[php] semantics` in the project file,
  a `// mc-php: semantics=...` comment in a php source (`src/program.mc` `ph_sem_*`); values
  `c` (default), `c-debug` (the unchecked reads checked again: outside, `mc-php: out-of-range
  read: offset N, length L (FILE:LINE)` on stderr and exit 134, `php_oob_slow`) and `php`.
  `tests/grid.sh` compiles with `php`. The six `tests/g` fixtures that read out of range on
  purpose carry the `php` comment; `tests/c/*.php` (a new d8 regime, `recording`) are graded
  against their own `NAME.out`/`.err`/`.code`: the wrap, in-range reads, the trap on a string
  and on a packed array; `tests/fixtures.sh`'s packed-overflow case gained a C twin; `tests/ext.sh`
  step 12b is in `php`. Measured (fifteen rounds interleaved, best of nine): reads unchecked
  0.392 -> 0.379 ms, and the wrap 0.358 ms; head to head 0.359 against main's 0.392, **module/C
  2.87** (was 3.14), 7.3x the interpreter; `php` 0.390, `c-debug` 0.389. Measured and NOT built:
  no `ph_pkabs` store (0) and string reuse in place (bound ~0.007 ms: php's allocator is 8% of
  the samples, the avoidable strings are `_dec_fmt`'s 3 of 7; two source rewrites of it were
  slower). Grid with `php`: all 30 lists identical to main's (plain and `MCPHP_RC=check`); with
  `c` three tests go green -> wrong, all three out-of-range string offsets on purpose
  (`Zend/tests/bug39018_2`, `str_offset_001`, `string_offset_int_min_max`). Found on the way,
  not changed: plain (non-packed) int arithmetic ALREADY wrapped in every mode (docs/plan.md § 7).
  Review of #26 (Copilot, six findings, each reproduced first). (1+2) a proven packed array
  still becomes php's hash on a store outside it, and `php_pk_get_c` read the stale dense buffer
  (`$a = array_fill(0, 1, 7); $a[3] = 9;` gave `$a[3]` 7) while `php_pk_get_d` trapped valid keys:
  both test the packed-or-hashed state (`p + 24`) now, a hash's missing key is a quiet null in `c`
  and the trap in `c-debug`; 0.358 -> 0.367 ms, module/C 2.94. P10's `lay_region` moved a whole
  loop body whose first call was the new slow half (0.375 ms): a region holding a branch back to
  before its start is refused now, `php` mode unchanged at 0.392. (3) precedence reordered, the
  source comment first, then the environment, then the project file, so `MCPHP_SEMANTICS=c` no
  longer overrides a fixture's own `php`. (4) the marker counts only as a real line comment,
  strings, heredocs, nowdocs and block comments stepped over (`ph_sem_hop_doc` + `ph_scan_hop`).
  (5) README: no annotations except the semantics selector. (6) d8check: eight regimes, and
  `extension` listed. New `tests/c/05-hashed`, `06-trap-hashed`, `07-marker-in-text`, each failing
  on the pre-fix compiler.
- C only (2026-09-27, branch `c-only`), the owner's correction: compiled mc-php code ALWAYS behaves
  like C. The `php` mode is gone with its only-php code paths: the element overflow test
  (`php_add_ck`/`sub_ck`/`mul_ck`, `php_pk_overflow`, `ph_is_ck`) and php's packed read
  (`php_pk_get`, `php_pk_get_slow`); the source comment `// mc-php: semantics=...`, its scan
  (`ph_sem_scan`, `ph_sem_hop_doc`) and `MCPHP_SEMANTICS` are removed, and `tests/c/07-marker-in-text`
  with them. One project key remains: `[php] checked_reads = true` (default false; not a
  boolean is a compile error at its position, `toml_err_key` -- the one mc name used here that
  mc's surface.txt does not freeze) turns on the trap variant. Kept, and documented as mc-php's
  own rules rather than a mode: a negative LITERAL offset is php's count from the end (and warns
  outside); `$a ** $b` with a non-literal exponent is php's float. Fixtures: the six `tests/g`
  that read out of range lost those reads (105's `pk_absent` and `pk_pow(PHP_INT_MAX - 1)` went,
  102/106/108/113/115 read in range) and stay differential; the packed-overflow block asserts the
  wrap only; `tests/c` trap fixtures carry a `NAME.toml` that `tests/mcphp.sh` builds the project
  road; `tests/ext.sh` step 12b reads at a negative literal offset (php's warning, still built in
  the pool, still drained). The grid always runs compiled as C and is a GATE now: green must be
  `tests/grid/green-*.txt` minus `tests/grid/expected-differences.txt` (exactly
  `Zend/tests/bug39018_2`, `str_offset_001`, `string_offset_int_min_max`, each with a reason).
- decimal-2x (2026-09-27, branch `decimal-2x` stacked on `c-only`): the module from 0.367 ms to
  0.266-0.267 ms against the twin's 0.125 (2.94x -> 2.14x), fifteen rounds interleaved. Built,
  each measured alone: the inliner substitutes an argument read once and a one-`return E` copy
  (`src/opt.mc`); an element read is an int (PT_INULL, `ph_pkabs`, `php_zinull` gone); FIXED
  arrays -- every keyed store `$a[K] = ... $a[K] ...` -- read and write the buffer with no test
  (`src/packed.mc` `pkx_isfixed`, `php_pk_get_f`/`php_pk_set_f`); `php_rc_ret` keeps a returned
  temporary on the pool; FRESH buffers (`str_repeat` + byte writes only) write with the bound as
  the one test (`src/rc.mc` `ph_rc_fb_scan`, `php_str_setb_f`, `php_str_repeat_f`); ropes build
  an appended string once (`ph_rope_fn`, `php_str_rope`); `phx_enter`/`phx_leave` fast paths
  copied into handlers; `&&`/`||` temporaries folded after the runtime copies (`ph_sc_fn`);
  P11 in `src/mach.mc` (a leaf, tail calls allowed, keeps locals in caller-saved registers;
  `MCPHP_LEAF=0`); `php_str_catrep`; `php_memcpy` without overlapping stores; `php_spn_r` for a
  literal set that is one byte run. Not built (measured): in-place appends via `_erealloc`
  (slower), overlapping small-copy stores (10% slower: store forwarding), byte loops, a static
  buffer pointer and one address per RMW (instructions -7% in `dec_mul`, cycles 0), unrolling
  (slower). Per call vs the twin in cycles: add 2.04, sub 2.00, mul 2.51, cmp 1.70; the floor is
  `_dec_umul` (NEON in the twin, and two `sdiv` per carry step where the twin multiplies high).
  `tests/g/116-lowered-forms.php` + its read-back in `tests/fixtures.sh`; the strings gate in
  `tests/examples.sh` re-recorded 500 500 600 200 10300.
  Second round (2026-09-28, the three causes, each bounded first): `_dec_udivmod` keeps the
  twin's one remainder buffer (`decimal.php`; dec_div 7217 -> 3130 cycles, strings gate 10300 ->
  1300); P12 in `src/mach.mc` (a signed `/`/`%` by a constant 2..65535 is `smulh` by the magic
  number, Hacker's Delight 10-1; `intdiv()` by a positive literal is mc's `/`; `MCPHP_DIVK=0`);
  P13 (a constant shift is the immediate form, `x + (y << k)` one shifted add;
  `MCPHP_SHIFT=0`); `ph_addm64` (`src/lvalue.mc`: a FIXED `$a[K] = $a[K] + E` computes the
  element address once; `MCPHP_ADDM=0`) and `ph_ac_walk` (`src/opt.mc`: an address's integer
  terms summed into the load offset; `MCPHP_AC=0`). New forms in the band 502..506 (`smulh`,
  `lsl`/`asr`/`lsr` immediate, shifted `add`), swept by llvm-mc. No NEON: clang vectorises only
  the digit loads, and a 15-instruction scalar loop beats the twin's. Bench 0.267 -> 0.250 ms
  against 0.125 (2.00x, 1.97-2.02 over the sitting): under 2x is not reached; the floor is
  diffuse (calls, spills in the big inlined functions, allocation). `tests/g/117`, `118` + the
  "second round" read-back in `tests/fixtures.sh`.
- decimal-under-2x (2026-09-28, branch `decimal-under-2x` from main e097215): module / twin per
  round (15 rounds interleaved, best of nine each) 2.008 (1.961-2.048) -> **1.794 (1.756-1.848)**,
  never above 2x; `bench.php` 0.254 -> 0.225 ms against 0.126. Built: P15 in `src/mach.mc` (a
  branch on `&&`/`||` branches on its terms instead of on mc's value form; `MCPHP_LOGIC=0`;
  `tests/g/119` + the "branch terms" read-back), a handler copies in the small loop-free php
  function it wraps (`src/ext.mc`), and `_dec_fmt` carries the index of its first kept digit as
  the twin moves its pointer (`decimal.php`; strings gate 400 400 500 200 1200). Measured and
  reverted: throw blocks out of line, loop-head alignment (16/32/64, nops or jumped over), byte
  writes for `_dec_fmt`, store-forwarded locals (P16), loop rotation (P17), silent full-width
  casts, `madd`, bigger inlining, big handler copies, libc `memcpy`. The floor is per-call
  overhead in short scans, copies and allocation, and the inner and carry loops of `_dec_umul`
  (examples/decimal/README.md, "Under 2x").
- two-extensions (2026-09-28, branch `two-extensions` from main 652401b): `examples/two-extensions`
  compiled from PHP. On the extension road a call to a function the source does not declare is
  looked up in php's function table when it runs (`zend_fetch_function_str`, cached per call site
  and request in words the compiler emits beside it -- the name, the calling function and the
  packed argument kinds live there too) and made with `zend_call_known_function` on engine zvals
  laid out on the stack (`lib/php_ext.mc` `phx_fcall`/`phx_fcall_l`/`phx_fcall_l2`,
  `src/builtin.mc` `ph_ftable_call`); an int, a string and a bool cross as themselves, null and
  float through a runtime zval, an array/object is refused while compiling and an array/object/
  resource answer where it arrives; an exception the callee throws is mirrored for the module's
  own catch and handed back to php as the engine's object when uncaught; undefined is php's own
  Error. The PROGRAM road still refuses such a call. Handlers: the BARE road -- a published
  function whose copied body calls nothing (or only a lazy int-answer table call) runs with no
  call context, its slow road a second function it tail-calls, so a pure handler is a leaf;
  `RETURN_LONG` is two stores; the inliner substitutes a pure load (and a handler's own argument
  always) and copies `return E` whose dead tail follows it. P11 fix: it dropped every frame
  access of a moved register, now only its save and restore. Bench (through B, 15 rounds
  interleaved): module / C twins 1.083 (1.038-1.174), module / interpreted 0.882 (0.830-0.987);
  per call b_use 131 -> 67 cycles against the twins' 64. `tests/ext.sh` step 14; the example's
  gate in `tests/examples.sh` (both load orders, B alone, the twins, the bench row). The leftover
  `tests/g/104-callable-value.php` and `tests/r/d6-callable-string.php` (callable values, $f()
  of a string) are untracked and not part of this.
- awaitable, step 1 (2026-09-28, branch `awaitable` from main 3f62f05): **namespaces**, php's
  rules, on both roads (`src/ns.mc`). The lexer hands a qualified name (`\A`, `A\B`,
  `namespace\B`) over as ONE identifier (`src/lex.mc` `ph_next`, `ph_qpend`); declarations are
  `ns\name` (functions, classes, `const`, and the forward-declaration scan in
  `src/program.mc`); a use site resolves per file with its `use` imports (class, namespace,
  function, constant; aliased and grouped) -- a class name has no fallback, a function or a
  constant falls back to the global one, and on the extension road an undeclared name goes to
  php's function table as `ns\f` then `f` (bit 48 of the call site's packed word).
  `__NAMESPACE__`, `X::class` and `get_class()` answer qualified names; an mc name carries `$`
  for the backslash (`ph_mangle`); the runtime keys a class by its qualified name
  (`php_clskey`). Both forms, `namespace X;` and braced. `tests/g/120-namespaces.php`,
  `121-namespace-blocks.php`, `tests/ext.sh` step 15. `examples/awaitable` gained its C twin
  (`c/awaitable.c`, graded against `check.expect`), and its pinned refusal moved to line 13
  (`#[Extern]`). The grid against a snapshot of main: `tests/lang` 104 = 104, `Zend/tests`
  766 -> **828** (+62: `namespaces/*`, `use_function/*`, `use_const/*`, `group_use/*`,
  `class_alias/*` and the rest a qualified name was blocking), `ext/standard/tests/strings`
  273 = 273, no loss.
  Review of #32, six findings, all fixed: a method's mc name maps the backslash too
  (`ph_mangle(cname, "m_")`); `namespace` and `use` are read by `src/program.mc`'s top-level
  loop only and refused in a function body or a block (`src/lvalue.mc`), a namespace inside a
  braced one of the SAME file is refused before the namespace changes (the open blocks are a stack of the
  files that opened them, so a file required inside a braced block declares its own namespace --
  `tests/g/inc-ns.inc`, and `use_const/shadow_global`, `use_function/shadow_global` stay green); the forward-declaration scan resets to
  the global namespace on `namespace {` (a function called before its declaration in the
  global block, `tests/g/121`); the C twin frees a sync object's handle with the object
  (`free_obj`, no clone) and its arg info says `parallel` needs 2 and `http_get_many` 1.
  `tests/fixtures.sh` asserts the four scope refusals.
- awaitable, step 2 (2026-09-28, branch `awaitable-extern` from main d5ea921): **`#[Extern]`, a
  C function declared in php** (`src/extern.mc`), on both roads. `#[Extern('lib', variadic: N)]
  function f(int $a, Ptr $p, string $s, mixed $v): int {}` -- the declaration is the ABI: `int`
  is C's int (a returned one sign-extended from bit 31), `Ptr` a pointer-sized integer, a `string`
  parameter the string's NUL-terminated bytes and a `string` return a C string copied, a `bool`
  parameter 0/1, a `mixed` parameter decided per call by the value (`php_zv_cword`; anything but
  int/string/bool/null is php's TypeError and C is not called), `void`. `variadic: N` pads the
  fixed arguments to eight on Apple arm64 only, where C variadics travel on the stack. The php
  function `f_NAME` stands for it (its body converts and calls the C symbol, the name without
  its namespace; declared `extern` unless the runtime already declares it), and it is never
  published (`ph_fext`). Extension road: the symbol comes from php's process; program road: the
  C library, so `c` or `pthread`; Windows refused by name (the link names no library for it) --
  `tests/c/08-extern.php` (its Windows answer in `08-extern.win.*`, a new rule of the `c/` loop),
  `tests/ext.sh` step 16, and the refusals in `tests/fixtures.sh`. `awaitable.src.php` lost its
  two `#[Extern(host: true, kind: 'data')]` lines (the engine's globals are the crossing's, not
  the source's), and its pinned refusal moved to line 36 (`await`'s variadic). The two callable
  drafts are committed on the pushed branch `awaitable-callables`.
  Review of #33: the attribute is the list item whose NAME is `Extern` (`ph_attr_item`; strings
  and parentheses skipped, so `#[Doc("Extern")]` is inert -- `tests/g/122-attribute-names.php`);
  it must be followed by `function`, else it is refused at its own line in the lexer (a body
  statement, a namespace, a use, a closure, a class member) and can never reach a later
  declaration; a C name the runtime DEFINES is refused (only an `extern` is reused). Windows's
  pin is its own refusal, line 13. The owner's addition: `name: 'sym'` names the C symbol (a C
  identifier, checked at the attribute), aliases of one symbol share ONE C declaration (a
  table of the ones emitted, `ph_xsym_*`, then the runtime's `extern`s), fewer argument words
  than the declaration padded with zeros, more refused; `;` as a body is read too.
- awaitable, step 3 (2026-09-28, branch `awaitable-classes`, stacked on #33): **signatures beyond
  the scalars, and php's arrays and objects inside the module**. An exported function takes any
  parameter but a reference -- `array`/`?array`, `mixed`/untyped/unions, `callable`, `object`, a
  class, a default, `T ...$rest` -- and returns `array`/`mixed`/an object too, each argument
  checked with php's own parameter-parsing words (`phx_chk2`, `phx_chk_rest`, `phx_arity2`;
  `must be a valid callback, function "nope" not found...`, `expects at least 1 argument`), the
  declared types recorded per row (`ph_fdpt`/`ph_fbk`/`ph_fbn`/`ph_fbnul`, set from
  `ph_type_word`'s new `ph_lt_*`) and in the argument records. A php array crosses as a copy
  (`phx_e2r_arr`/`phx_r2e_arr`, through the engine's hash iterator), a php object as a PROXY: a
  runtime object of one class (flag 32) holding the `zend_object`, whose property read/write,
  method call, class name, instanceof and `===` go to the engine (`lib/php_rt.mc`'s `ph_eng`
  table, 0 on the program road); every engine array or object held is a reference on the `ph_esc`
  list, tagged by bit 0 and given back with the call's memory. The pending exception is read from
  `executor_globals` (`php_dlsym` in each host layer). The same crossing serves php's function
  table, so the compile-time refusal of an array argument is gone. Found on the way and fixed on
  both roads: a zval stored into an array bucket with a whole-word type store cut the bucket's
  collision chain into a loop, and `return <zval>` in a `: array` function stored the zval as the
  array (now php's return rule, then the array). A class an extension would publish is REFUSED
  while compiling (the back end registers none yet) -- the pin moves to line 26
  (`awaitable\Intent`), Windows's stays at 13. `tests/ext.sh` step 17 (`tests/ext/values`),
  step 14 (arrays through the function table), `tests/leaks.sh` (the values module, 300 rounds,
  nothing left).
- awaitable, step 4 (2026-09-28, branch `awaitable-published`, stacked on the step-3 PR):
  **published classes**. A class an extension publishes (name without `_`) is registered with the
  engine at MINIT as an internal class (`phx_cls_begin`/`phx_meth`/`phx_marg`/`phx_cls_end`):
  its declared properties with defaults and visibility (`zend_declare_property`), its methods
  as internal methods whose handler (`phx_mh`) makes `$this` a proxy and runs the compiled
  body, `final`/`abstract`. The runtime class stays and carries CE_ENG (CE_SIZE 104 -> 112) and
  flag 64; `new` of it in the module is the engine's object (`php_new_ce` -> `phx_pnew`),
  `php_ctor` on a proxy is the engine's `__construct`, and a proxy read/write inside a method
  uses the class as the engine scope (`phx_escope`), so private is the method's. Refused by
  name: an interface/trait/enum, `extends`/`implements`, static members, abstract methods, a
  non-scalar property default, a class inside a function. `awaitable.src.php`'s `await` got its
  body (`new Intent`, `$fn(...$args)`, the Throwable kept); the build succeeds, so the example's
  pin became a PROGRESS count on non-Windows hosts: check.php through the compiled module agrees
  with check.expect for 6 of 37 lines (`AW_PROGRESS` in `tests/examples.sh`; it stops at a
  callable string). Windows's pin moves to line 14: the source's header grew a line. `tests/ext.sh` step 18 (`tests/ext/classes`), four refusals, `tests/leaks.sh`.
  On Windows the three names a published class calls (`object_init_ex`, `zend_declare_property`,
  `zend_register_internal_class_ex`) are listed in `src/win/php8.def` and `php8ts.def`, and
  `tests/ext.sh` step 1b grades every php name `lib/php_ext.mc` imports against both files on
  every host -- #34's windows/x86_64 failure (two kernel32 names below the runtime's
  `#dylib "ucrtbase.dll"`, exit 127 before `main`) was the same class of miss, found only on a
  Windows runner.
- awaitable, step 5 (2026-09-28, branch `awaitable-call`, stacked on the step-4 PR): **php's
  callables called, throwables both ways**. On the extension road `$fn(...)` on a value that is
  not the runtime's own closure -- a name, `"C::m"`, an array callable, an engine `Closure`, an
  `__invoke` object -- goes to php (`ph_eng` slot 6, `phx_vcall` over `_call_user_function_impl`),
  a spread's trailing "not passed" slots dropped so php counts the real arguments; what it throws
  is the module's to catch (`phx_zcatch`), and a non-callable is php's own `Error` wording for a
  name, an object and a scalar. A runtime throwable crossing into php -- stored, returned, or
  thrown out of a handler -- is the engine's object of its class with message and code
  (`phx_exc_obj`, which `phx_throw` now uses too). Found on the way and fixed: `phx_zmirror`
  outlived the call whose memory held it, so a later call's runtime exception at the same
  address was taken for the mirror and php got the OLD engine exception rethrown; the mirror
  is now dropped at the end of the outermost call. On the program road an object is called
  through `__invoke` (`$g("x")` on a `new Greeter`), and a callable STRING is refused by design
  (D6, `tests/r/d6-callable-string.php`) where an extension calls it through php;
  `tests/g/104-callable-value.php` is green, and the grid gains three `__invoke` tests
  (`bug70179`, `dereference_004`, `bug46409`).
  `AW_PROGRESS` 6 -> 9 (`reset()` is next: the bodies). `tests/ext.sh` step 19
  (`tests/ext/callables`), `tests/leaks.sh` (the callables module, 300 rounds). windows/x86_64
  CI then found `EG(exception)` at the wrong place: `executor_globals` carries an
  `OSVERSIONINFOEX` before it on Windows, so the headers' 960 is not Windows's offset. It is now
  MEASURED in a request's first call (`phx_egx_find`: an exception thrown with nothing pending,
  found among the globals, cleared), with 960 as the fallback -- a fallback of 8 still passed
  step 19 on macOS, so the probe is what answers.
  Review (reviewer agent, Copilot out of quota): `phx_exc_obj`'s fallback lookup of `Exception`
  leaked its temporary `zend_string` on every throwable of a class the engine does not know.
  Reproduced first -- `tests/leaks.sh` now throws a module-private `_Oops` 300 times: 600 blocks
  left under a debug php -- and fixed with one lookup helper both lookups use (`phx_lookup`).
  Same review: `phx_mh`'s `$this` proxy was suspected of delaying `__destruct`.
  Measured: an object php holds is destroyed where php destroys it (a loop of method calls, then
  `unset`, prints in php's order). What the review led to is a CRASH: an object the module makes
  and drops is released at the module call's end, and its `__destruct` -- a module method -- ran
  as a call nested in `phx_leave_slow` after the call's allocator was torn down; a destructor
  that allocated left the next call with `zend_mm_heap corrupted` (exit 134). The holds are now
  released with the call still open (`phx_esc_open`: at depth 1, round by round, keeping what a
  pinning destructor holds). `tests/ext/classes` gained that shape (it aborts without the fix).
  Written down, not fixed: such a destructor runs at the call's end rather than at php's moment,
  and a published method called from a loop inside the module keeps ~500 bytes a call until the
  call returns (a million calls exhaust 128 MB).
- awaitable, step 6 (2026-09-28, branch `awaitable-parallel`, stacked on the step-5 PR):
  **`parallel` and the counters, in the source**. No compiler change: `awaitable.src.php` declares
  `fork`, `pipe`, `waitpid`, `_exit` and `read`/`write`/`close` (as `c_read`/`c_write`/`c_close`,
  `name:`) with `#[Extern('c')]` and writes the C twin's algorithm in php -- one child per
  argument, the child calls `$fn` through php, `serialize()`s the answer (or the message of what
  it threw) down a pipe and `_exit`s; the parent reads each pipe in order, `waitpid()`s and
  `unserialize()`s, counting a thrown child in `errors()`. A buffer C writes into is a php string
  the module made of that length (`str_repeat("\0", 8)`), read back with `unpack()` -- written
  down in `docs/php-extension.md` as the rule until native memory has a surface. `reset`, `peak`,
  `completed` and `errors` are module globals. `AW_PROGRESS` 9 -> 31 on macOS and Linux; it stops
  at `http_get_many` (threads: the owner's decision on a `#[Native]` function is pending).
  Measured, `parallel('heavy', ...6 args)` at 2 000 000 iterations each, best of 5 on 10 cores:
  17.0 ms against 46.0 ms sequential in php (2.71x), and the C twin 17.1 ms.
  Review (reviewer agent): a read or `waitpid` interrupted by a signal (EINTR, a handler with no
  `SA_RESTART`) lost the child's answer and left it a zombie -- in the C twin too. Reproduced with
  `examples/awaitable/signals.php` (a SIGCHLD handler through `pcntl_signal(..., false)`, a slow
  first child): both printed an empty first answer and `a child left unreaped: true`. Fixed in
  both the same way: retried on `errno == EINTR` and on nothing else. The source reads errno
  through `#[Extern('c')] function errno(): int {}` -- a macro in C, so `src/extern.mc` maps it to
  the host layer's `php_c_errno` (`__error()` on macOS, `__errno_location()` on Linux; a
  misdeclared one is refused, `tests/c/08-extern` prints `close(-1)`'s 9). A first version asked
  `kill(pid, 0)` instead; the second review pass showed a child reaped by someone else (a SIGCHLD
  handler calling `pcntl_waitpid(-1, ..., WNOHANG)`, php's manual's idiom) makes waitpid answer
  ECHILD for ever, and kill succeeds again once the pid is reused -- a spin. `signals.php` gained
  that handler and `SIG_IGN`; both versions pass them here (the handler cannot run inside the
  module's call, and pid reuse cannot be forced), so the gate for the change is errno's fixture
  and the EINTR case. `tests/examples.sh` runs `signals.php`, bounded by `tests/lim.sh`, against
  the twin and the compiled module when php has pcntl. The counters were checked against
  the twin and `awaitable.mc`: they count threads, so `parallel` leaves `completed()`/`peak()` at
  0 -- now a `check.php` line (38 lines; `AW_PROGRESS` 32).
- threads, step 1 (2026-09-29, branch `threads-runtime`, from main bac2dcf): **the runtime's
  state per thread** (`docs/threads.md`). The inventory covers 122 mutable globals in `lib/`.
  94 of them move into a per-thread block (`lib/php_tls.mc`, 12320 bytes, scalars first). Every
  function that touches the block opens with `phT = ph_tcur; if (!phT) phT = ph_tslow();`. While
  only the booting thread runs, that is one load and a branch. While other threads run, it asks
  `pthread_getspecific`/`TlsGetValue`. `src/tls.mc` lowers the 7 names that generated code uses.
  The rest stays shared, with a reason for each:
  - written at bootstrap: the shared lazy values are now built eagerly;
  - read-only after MINIT;
  - refused from another thread with an Error: globals, statics, `define()`, `class_alias()`, and
    every entry into php's engine. Both guards are **interim until step 3**: module globals
    become shared, one copy, as in C.
  No atomics: only literals and class entries cross threads, and neither is ever counted.
  - Each other thread gets its own mapped arena and no Zend allocator. Its arena and block are
    always unmapped at join, because a thread never pins. The review found that a first version
    kept a 256 MiB arena for any thread that called one of six builtins: a set/restore of the
    error or exception handler, `strtok`, or `fopen`. `tests/c/10-threads-vm` measures the
    process's virtual size (`mcphp_vm()`: `task_info`, `/proc/self/statm`,
    `K32GetProcessMemoryInfo`). It grew 8192 MiB before the fix and stays under 256 MiB after.
  - Only the booting thread flips `ph_tcur`: to 0 before the first thread is created, and back
    after the last join. A thread may start threads of its own. Every thread checks the flip at
    its start and at its end.
  - The host's thread-local key is created once. The first version created one per run, which
    leaks keys.
  - `mcphp_threads('f', $n, $arg)` is a test-only gate.
  - Tests: `tests/c/09-threads` (8 threads x 5 rounds; nested 4 x 3; 1500 runs in a row; module
    state refused), `tests/ext.sh` step 20, and a threads block in `tests/leaks.sh`.
  - Cost on decimal, 15 rounds interleaved: main 0.225 ms (1.78x C), this 0.231 (1.83x), +2.7%.
    `sample` shows equal totals for the module and the difference in `f__dec_umul`, whose inner
    loop is instruction-identical, so the difference is alignment. two-extensions: 1.14x against
    1.17x. An always-TLS variant measured 0.265 ms (+18%).
- threads, step 2 (2026-09-29, branch `threads-zts`, from main 24aed04): **ZTS extensions and
  `[php].thread_safety = "nts" | "zts" | "both"`**. The default is `nts`, and the output depends
  only on the file.
  - An unknown value is refused at its `file:line:col`. The old booleans are refused with the
    word that replaces each.
  - The build id's `,NTS`/`,TS` word is made the output's own (`ph_ts_bid`).
  - A ZTS output pushes `lib/php_zts.mc`, and `get_module` ends with `phx_ts_module`:
    - `EG` is read as `tsrm_get_ls_cache() + executor_globals_offset`, both found by dlsym.
      `EG(exception)` is 960 on both builds, and the layout gate is 85/85 against the ZTS
      headers.
    - (superseded by the review round below) An RINIT/RSHUTDOWN pair refused a request on any
      php thread other than the loading one.
    - On Windows, `php_dlsym` asks `php8ts.dll`. The host source is swapped only for ZTS.
  - `"both"`: mc-php's entries now include mc's seven parts plus `src/build.mc`'s own main,
    which re-registers `build`. It builds the NTS output in process, then the ZTS output in a
    child from a hidden copy of the file (out gets `-zts`, `thread_safety = "zts"`, and
    `php8.lib` becomes `php8ts.lib`).
  - NTS inertness: every NTS module the repo builds (hello, decimal, extA, extB, awaitable and
    the four tests/ext modules) is `cmp`-identical, before and after, on macOS and on Linux
    aarch64 and x86_64. Windows is identical by construction: nothing NTS-side changed.
  - Tests:
    - `tests/ts.sh`: a ZTS php grades hidden zts copies of the files;
    - `ZTS=1 tests/linux.sh`: php:8.5-zts-alpine, with the C twins built against its headers;
    - `tests/both.sh`: each output is loaded in its own php, and the other php refuses it;
    - `ext.sh` 2b (three refusals) and 2c ("both" on every leg).
  - CI adds a macOS ZTS job (setup-php `phpts: ts`), ZTS Windows legs (x86_64 and aarch64), and
    the ZTS and both steps on the Linux legs.
  - Review round (PR #39), six findings:
    1. Real multi-thread ZTS (`docs/threads.md` § ZTS). TSRM module globals: php gives every
       php thread a runtime block (`globals_size/id_ptr/ctor/dtor`), set up at the thread's
       first request, released by `globals_dtor`. EG is read per thread. Per php thread, and
       copied from MINIT's at each request (`phz_privatize`): globals, constants, the class
       registry, statics, static properties, the call-site caches (`phst_`/`phf_` moved into a
       per-thread area by `src/tls.mc`). MINIT's memory is read-only under
       `MCPHP_ZTS_READONLY=1`. Gate `tests/frankenphp.sh` (FrankenPHP 8.5.11 ZTS, 8 php
       threads, 400 warm-up + 4000 requests 32 at a time): every answer right, 5 threads,
       RSS +2..3 MiB, on aarch64 (3 runs) and x86_64 under emulation (2000/16); CI on both
       Linux legs. Cost on decimal's bench: 0.228 ms NTS vs 0.269 ms ZTS (+18%); interpreted
       php itself +5%. Found on the way, NOT a ZTS defect and not fixed here: an arrow function
       captures every enclosing variable, so a `$e` a catch never assigned is an unset slot --
       SIGSEGV exit 139 on main's own compiler, program road, NTS.
    2. A php without `tsrm_get_ls_cache`/`executor_globals_offset` gets an `E_CORE_ERROR` from
       `get_module` naming the symbol; `ext.sh` 2c and `both.sh` check it (NTS php loading the
       ZTS output).
    3. The unfrozen mc names: `tests/mcnames.mc` (217: 64 functions, 5 globals, 145 defines, 3
       C functions) and `docs/mc-internals.md`, pinned to mc 1.3.0; `tests/mcnames.sh --strict`
       in CI names a missing name or a changed arity and the mc version.
    4. The ZTS copy is `.mcphp-zts-<pid>-<file>`, removed on every path; `.gitignore` has
       `.mcphp-zts-*` and `.mcphp-test-*`; a SIGKILL leaving it is documented.
    5. `php8.lib` -> `php8ts.lib` only for a Windows target and only as a whole word.
    6. `ph_swap` refuses a text that occurs twice or never.
    - CI found one more (5158ea0): RINIT's call left a home chunk, so `phx_enter`'s fast path
      never reached the one-time EG(exception) measurement; on Windows the measured offset
      is not 960 and `callables` failed on both ZTS legs. A ZTS-only swap makes the fast path
      wait for the measurement; a module with the offset forced wrong reproduced it on
      linux/aarch64 (exit 255 before, php's bytes after). CI 36553774441 all 8 jobs green;
      FrankenPHP linux/x86_64 native 3/3 green (5, 6 and 8 php threads). The run before the
      fix HUNG at FrankenPHP's first request on linux/x86_64 native (cancelled after 10 min);
      that cause is not established.
    - Re-check finding (MEDIUM-HIGH): `phx_ts_rinit` saved and restored the process-wide
      `phx_egx_done`, which another php thread could write back as 1 before any thread
      measured. `phx_egx` and `phx_egx_done` are now per-thread words (src/tls.mc, ZTS only,
      PHT 12424/12432, block 12440); RINIT sets the flag in its own block; each php thread
      measures once in its own engine. Gate: `MCPHP_ZTS_EGX_WRONG=1` starts every thread from
      offset 456 (EG(function_table)); frankenphp.sh's readiness probe calls nothing in the
      module and the warm-up's 400 first requests must be right, with a throwing callable and
      a variable-called php function. A build that never measures fails all 400; the old
      shared-flag race did NOT reproduce in 8 runs (5 with the non-calling probe); the fix
      stands by construction. NTS cmp 27/27 identical.
- Arrow-function capture (2026-09-29, branch `arrow-capture`, from main 56ffa46): `fn() => ...`
  captured EVERY enclosing variable, so a variable the body never names -- a catch's `$e` on a
  path where nothing assigned it -- was copied out of an unset stack slot: SIGSEGV exit 139 on
  the program road (NTS, main's own compiler). Now php's rule: by value, at creation, only the
  names the body uses (`ph_names` walks the parsed body; the creation site `ph_cap_site` is
  built after it, nested arrows capture transitively). Fixture `tests/g/123-arrow-capture.php`
  (exit 139 before, php's bytes after); the same cases in `tests/ext/callables` for the
  extension road (it did not crash there before: the slot held a readable value). The
  FrankenPHP test's arrow fn is back after its try.
- Closure parameter shadowing (2026-09-29, branch `closure-shadow`, from main e8d3b64): an arrow
  function captured the enclosing variable a parameter of its own names, and the capture was
  read into the parameter's slot after the parameter: `$x = 100; fn($x) => fn() => $x * 2` gave
  200 for `(5)()` (php 10), `fn() => fn($x) => $x + 1` gave 1000 (php 2), a nested arrow got the
  function's `$x` instead of its outer arrow's parameter. Now a closure never captures a name
  its parameter uses; `function ($x) use ($x)` is php's compile-time Fatal error, in php's
  words, exit 255 (`ph_phpfatal_x`, stack trace). Also found and fixed in the same capture
  list: an arrow function captured only the first 16 enclosing variables, so a 17th read as
  undefined (warning, wrong value); the lists are now sized by the scope. Fixtures
  `tests/g/124-closure-shadow.php` (all wrong on main), `125-closure-lexical-param.php` (main
  printed 7); the same cases in `tests/ext/callables` (main: `200 1000 6 16`), and ext.sh checks
  the Fatal on the extension road.
  - Review addition: `use ($a, $a)` is php's `Cannot use variable $a twice` compile-time Fatal
    (stack trace, exit 255), checked in the use loop itself; main accepted it and printed 1,
    and past `ph_nvar + 16` repeats died with the wrong reason. Fixture
    `tests/g/126-closure-use-twice.php`; ext.sh asserts both Fatal errors on stdout AND stderr.
- threads, step 3a (2026-09-29, branch `threads-api`, from main 4fd70b6): **the thread API**
  (`docs/threads.md` § Step 3). Five builtins on both roads -- `mcphp_thread_start(callable,
  ...args)` (at most 5 arguments), `mcphp_thread_join`, `mcphp_thread_detach`,
  `mcphp_thread_running`, `mcphp_hardware_concurrency` -- the primitive layer an object `Thread`
  can sit on later. Test hooks `mcphp_shared_mode()`, `mcphp_str_mine($s)`.
  - Frozen publication (the approved design) was WITHDRAWN: a store into module state is not one
    place, and copy-on-write of a shared array is O(n) per write. The replacement, approved: a
    worker's arena is KEPT after its join (on the root's `ph_tret` list; freed at the request's
    end on the extension road, never on the program road); shared mode (`ph_shared`, set by the
    first start, copied into every worker, sticky until the request ends) stops strings being
    freed or written in place, and on the extension road defers a counted Zend string's free to
    RSHUTDOWN (`php_str_defer`/`php_str_undefer`, deduplicated); globals, statics and `define()`
    are written in place and shared, as in C; arguments, results and exceptions are deep-copied
    (`php_tc_*`, one identity map per copy, counted keys copied, strings shared). A runtime lock
    (pthread mutex / `SRWLOCK`) guards the handle table, the deferred list and the kept list.
    `class_alias()` and `register_shutdown_function()` still refuse another thread. A php
    callable is refused: NTS with an Error naming `thread_safety = "zts"`, ZTS naming step 3b.
  - A thread's arena grows by chunks (64 KiB, doubling to 64 MiB), replacing step 1's single
    256 MiB map. Retention measured (macOS, N short threads each building 1 KB): 100 / 1000 /
    10000 threads keep 3.6 / 19.6 / 180 MB resident and reserve 6 / 62 / 625 MiB -- ~18 KB and
    64 KiB per thread, bounded by use; a `ponytail:` note names the upgrade.
  - Unjoined threads are waited for at the program's or request's end; the first one's
    exception is the program's uncaught one (exe) or a warning (extension). Detached threads are
    waited for too (the design said they would die with the process on exe).
  - Tests: `tests/c/11-thread-api` (a joined and a detached thread's stored string/array/object
    read after them, shared mode sticky after the last join, nested threads, rethrow),
    `tests/c/12-thread-unjoined`, `tests/ext/threads/api.php` (ext.sh § 20b), leaks.sh's API
    block, FrankenPHP's request starting an API thread, `examples/threads` (primes) with a C
    twin. Teeth: releasing a joined thread's arena at the join (result copied first) SIGSEGVs
    both `11-thread-api` and `api.php`.
  - Gates: run.sh green (fixtures 126/126 plain and check, C behaviour 12/12, ext, examples);
    grid plain and check = recording minus the 3 expected differences; leaks 0 on aarch64;
    linux.sh aarch64 green, ZTS=1 green, x86_64 all but the known `requests` failure under
    emulation; both.sh; FrankenPHP aarch64 and x86_64; mcnames 217 against mc 1.1.0 and 1.3.0
    (strict); llvm-mc sweep 2614 arm64 / 2361 x86-64 distinct instructions (only the two known
    `setp`/`setnp` REX-prefix differences), branches 0 bad, mnemonic sets identical to main's.
  - NTS bytes: every module changes (the runtime carries the API; mc links no dead code):
    `__text` +7428 bytes in `callables.so`; files hello 364856 -> 366504, decimal 418968 ->
    420616, extA/extB +1648, awaitable +1680, values +1680, callables +18176, classes +18192
    (a page boundary), threads +1328.
  - Cost, best of 21 processes interleaved (each the bench's best of 9): decimal module 0.428 ->
    0.434 ms (+1.4%), two-extensions b_use 3.752 -> 3.784 (+0.9%), a_add 1.493 -> 1.500
    (+0.5%); program road (`benchprog.php`, best of 25) 56.38 -> 56.17..56.48 ms, noise.
  - Found, pre-existing, not fixed: a closure whose body throws inside a `try` fails to compile
    with `break out of range`; a top-level variable created only by `global` in a function is
    undefined at top level. New gap, documented: a copy made for another thread is not armed for
    `__destruct` (an object a thread returns never runs its destructor).

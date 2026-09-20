# mc-php -- operating rules

Read `docs/plan.md` first. This repository is a CONSUMER of mc 1.0.0 (frozen surface): it never
edits mc's `src/`; a surface gap is reported to mc with a reproducer, never patched around here.

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

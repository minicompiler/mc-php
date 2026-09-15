# mc-php -- operating rules

Read `docs/plan.md` first. This repository is a CONSUMER of mc 1.0.0 (frozen surface): it never
edits mc's `src/`; a surface gap is reported to mc with a reproducer, never patched around here.

- A `.php` file is PHP: it must run under `php` unchanged. No dialect. mc-php accepts a SUBSET:
  no `eval`/interpreter (D1) and static variable types (D4); a refusal is a named compile error.
- The oracle is php-src's `.phpt` corpus under `php` and under the mc-php build; every claim
  carries its green/total number.
- Comments, messages and docs in English; ASCII identifiers; no emojis.
- Every probe under `probes/` prints one number and exits 0 only when it measured it.
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

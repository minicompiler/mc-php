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

__T0_SUMMARY__

`sh probes/t0/run.sh` (`T0_CROSSCHECK=1` also re-runs php-src's own runner, ~8 minutes). Details:
`probes/t0/RESULTS.md`.

## Not run yet

T5 (`docs/plan.md` § 4).

# decimal -- a fixed-point DECIMAL extension, written in PHP

`decimal.php` is ordinary PHP, and `mc-php build` compiles it into `decimal.so` (`decimal.dll`
on Windows). No C anywhere, and no float anywhere in the arithmetic.

```sh
mc-php build examples/decimal --config examples/decimal/mcphp.toml
php -d extension=examples/decimal/build/decimal.so -r 'echo dec_div("1", "3", 20), "\n";'
# 0.33333333333333333333
```

| function | |
|---|---|
| `dec_add(string $a, string $b, int $scale): string` | `$a + $b` |
| `dec_sub(string $a, string $b, int $scale): string` | `$a - $b` |
| `dec_mul(string $a, string $b, int $scale): string` | `$a * $b` |
| `dec_div(string $a, string $b, int $scale): string` | `$a / $b`; `DivisionByZeroError` on a zero divisor |
| `dec_cmp(string $a, string $b): int` | -1, 0 or 1 |
| `dec_round(string $a, int $scale): string` | `$a` at `$scale` digits |

A number is a string, `[+-]?[0-9]+(\.[0-9]+)?`; anything else is a `ValueError` naming the
argument, and so is a negative `$scale`. A result always has exactly `$scale` digits after the
point, and a zero is never negative -- bcmath's shape.

**Rounding is HALF-EVEN (banker's), in every function**: when the exact result has more digits
than `$scale` it goes to the nearest representable value, and an exact tie goes to the even last
digit -- `dec_round("0.125", 2)` is `0.12`, `dec_round("0.135", 2)` is `0.14`,
`dec_div("-1", "8", 2)` is `-0.12`, `dec_round("-2.5", 0)` is `-2`. bcmath truncates instead.

## How it is checked -- `tests/examples.sh`, on all five hosts

| step | |
|---|---|
| the differential | `check.php` runs twice -- with `decimal.so` loaded, and with `decimal.php` required -- and the two must print the same bytes on both streams and exit the same: 60 lines, every tie in both signs, the four operations at three scales, a ledger, and the seven wrong VALUES |
| bcmath | `bccheck.php`, where the host php has bcmath: 1219 results of the module against bcmath's exact result rounded by `bcround(..., RoundingMode::HalfEven)` -- add, sub and mul exact at the sum of the scales, a quotient taken to 80 digits first. It ran, 0 wrong, on macos/arm64, windows/x86_64 and windows/arm64 in CI; the `php:8.5-alpine` image the Linux legs use has no bcmath, and the gate says `SKIPPED` there |
| what is published | `get_extension_funcs("decimal")` is the six `dec_*` names: the `_dec_*` helpers are module-private (a leading underscore, `docs/php-extension.md` § What is published) |
| the soak | `soak.php`: **1 000 000** `dec_add` calls in ONE request, and `memory_get_peak_usage()` must not move (the answer must be `12500000.00`) |
| the C twin | `c/decimal.c` -- the same six functions written as an ordinary C extension, built with `php-config` and `cc` where the host has both, and graded by the same `check.php` (and, by hand, `bccheck.php`: 1219, 0 wrong). Where there is no `php-config` or no `cc` -- the Linux containers, the Windows runners -- the gate says `SKIPPED` and the bench has two columns |
| the bench row | `bench.php`: three ten-year loan schedules, ~1500 calls a run, a warm-up and the best of nine per process, the interpreted, compiled and C-twin processes interleaved three times. The answers must be equal; the ratios are printed and not gated |

Measured on 2026-09-23 by `tests/examples.sh`, each host against its own php 8.5 (the CI rows are the pull request's first run):

| host | interpreted | compiled | ratio |
|---|---|---|---|
| macos/arm64, this repository's own Mac | 1.72 ms | 3.41 ms | **0.51x** |
| macos/arm64, CI (`macos-15`) | 2.03 ms | 4.10 ms | 0.50x |
| linux/aarch64, CI (`ubuntu-24.04-arm`, container) | 3.08 ms | 6.71 ms | 0.46x |
| linux/x86_64, CI (`ubuntu-24.04`, container) | 3.76 ms | 7.33 ms | 0.51x |
| windows/x86_64, CI (`windows-latest`) | 4.19 ms | 7.24 ms | 0.58x |
| windows/arm64, CI (`windows-11-arm`, x64 php emulated) | 8.68 ms | 10.70 ms | 0.81x |

**On 2026-09-23 the compiled module was SLOWER than the interpreter on this workload.** A decimal
is string work, and php's string functions -- `substr`, `str_pad`, `ltrim`, `strspn` -- are C
inside the interpreter, where mc-php's were mc calling mc one byte at a time, and every string one
of them built was a new allocation. Batch E (below) is what changed that.

**Three columns, batch A** (2026-09-24, macos/arm64, php 8.5.10, all on one host in one sitting;
another process held one core throughout, which is why every absolute number here is higher than
the table above -- the ratios are what compare):

| | interpreted | the module | the C twin |
|---|---|---|---|
| before batch A | 3.29 ms | 6.48 ms (0.51x) | 0.238 ms (13.8x) |
| after batch A | 3.29 ms | 6.41 ms (0.51x) | 0.238 ms (13.8x) |
| after batch A, CI (`macos-15`, a quiet runner) | 2.10 ms | 4.25 ms (0.49x) | 0.172 ms (12.2x) |

The other four CI legs have no C column (no `php-config` or no `cc`) and measured the module at
0.50x (linux/aarch64), 0.51x (linux/x86_64), 0.93x (windows/aarch64, an x64 php emulated) and
0.88x (windows/x86_64) on the pull request's run.

The C twin is what a competent C extension does -- digit strings, schoolbook multiplication, long
division by repeated subtraction, `emalloc` for every buffer -- and after batch A it was **27x
faster than the module**. Batch A did not aim at that number; it moved what the arena cost into
Zend's allocator (the column did not move: the arena was a bump allocator too) and made a million
calls possible.

**Three columns, batch E** (2026-09-24, macos/arm64, php 8.5.10, one host, one sitting,
`tests/examples.sh`'s own bench row). The same `decimal.php`, byte for byte: every gain is in the
compiler and its runtime, and `docs/plan.md` § 7 item 1 has the profile it was chosen from and
what each change bought:

| | interpreted | the module | the C twin |
|---|---|---|---|
| before batch E | 3.29 ms | 6.46 ms (0.51x) | 0.240 ms (13.7x) |
| after batch E | 3.31 ms | **1.51 ms (2.19x)** | 0.241 ms (13.8x) |
| after batch E, CI (`macos-15`) | 2.08 ms | 1.22 ms (1.70x) | 0.171 ms (12.2x) |

and on the other four CI legs of the pull request's run, which have no C column:

| host | interpreted | the module | ratio |
|---|---|---|---|
| linux/aarch64 (`ubuntu-24.04-arm`, container) | 3.08 ms | 1.77 ms | **1.74x** (was 0.50x) |
| linux/x86_64 (`ubuntu-24.04`, container) | 2.10 ms | 1.39 ms | **1.52x** (was 0.51x) |
| windows/x86_64 (`windows-latest`) | 4.23 ms | 1.84 ms | **2.29x** (was 0.88x) |
| windows/arm64 (`windows-11-arm`, x64 php emulated) | 8.82 ms | 2.95 ms | **2.99x** (was 0.93x) |

**By `docs/plan.md` § 7's acceptance rule `decimal` is DONE**: compiled from its PHP source,
faster than php interpreting the same source on every leg that runs it, with its C twin beside it.

The module is **4.3x faster than it was and 2.2x faster than php interpreting the same source**;
the C twin is still 6.3x faster than the module, and the rest of that gap is named in
`docs/plan.md` § 7. The project files now build with mc's optimizer (`[project].opt = 1`), which
accounts for 1.7x of the 4.3x.

**Three columns, the decimal-c batch** (2026-09-24, macos/arm64, php 8.5.10, one host, one
sitting, five rounds interleaved; `decimal.php` byte for byte what it was, every gain in the
compiler and its runtime -- `docs/plan.md` § 7 item 1 has the profile, the table of what each
change bought, and what is left):

| | interpreted | the module | the C twin | module / C |
|---|---|---|---|---|
| before (main) | 3.29 ms | 1.514 ms (2.17x) | 0.239 ms (13.77x) | 6.33 |
| after | 3.29 ms | **0.990 ms (3.32x)** | 0.240 ms (13.71x) | **4.12** |

`tests/examples.sh`'s own bench row on the final tree: 3.299 / 0.998 (3.31x) / 0.237 ms (13.92x).

and on every CI leg, main's run after batch E (the merge of #20) against this pull request's final
run, 36045318703 (runners differ between runs by up to ~40% in absolute time, so the ratio is what compares;
only `macos-15` has `php-config` and `cc` for the C column):

| host | main: interpreted / module | ratio | decimal-c: interpreted / module | ratio |
|---|---|---|---|---|
| macos/arm64 (`macos-15`) | 2.099 / 1.248 ms, twin 0.172 | 1.68x, module/C 7.3 | 1.919 / 0.747 ms, twin 0.159 | **2.57x**, module/C **4.7** |
| linux/aarch64 (`ubuntu-24.04-arm`, container) | 3.091 / 1.775 ms | 1.74x | 3.090 / 1.170 ms | **2.64x** |
| linux/x86_64 (`ubuntu-24.04`, container) | 2.980 / 2.194 ms | 1.36x | 3.703 / 1.498 ms | **2.47x** |
| windows/aarch64 (`windows-11-arm`, x64 php emulated) | 8.778 / 2.942 ms | 2.98x | 8.788 / 1.903 ms | **4.62x** |
| windows/x86_64 (`windows-latest`) | 6.510 / 2.349 ms | 2.77x | 7.023 / 1.613 ms | **4.35x** |
The largest single steps: `_dec_umul`'s arrays are native int buffers now (the compiler proves they
hold only ints and never leave the function, `src/packed.mc`), `_dec_coef`'s two one-byte
`str_replace` deletions are one pass, and a cast no longer swallows the `- $borrow` after it.

What still separates the module from the twin is mostly the ALGORITHM both php and the module run:
a number is a string, so every operation re-validates and re-parses its operands and makes new
strings for its intermediate values, where the twin parses each operand once into digits and
writes into one buffer; the rest is named in `docs/plan.md` § 7 (mc's code for a leaf function,
§ 5; the call's memory zeroed on return; the result copied out to Zend).

## What it cannot do yet

* **A wrong TYPE** is an internal function's message in the module and a userland one
  interpreted (`docs/php-extension.md` § What a wrong call says), so `check.php` does not make
  one. The wrong VALUES it makes are the same in both runs, because the source throws them.

Writing this example found two defects in the compiler's front end, both fixed with a fixture
(`tests/g/96-static-args.php`, `tests/g/97-elseif-string.php`), and one it works around:
`str_replace` with an ARRAY search is a wrong answer (`Array to string conversion`) rather than a
refusal, so `_dec_coef` calls it twice with strings (`docs/plan.md` § 7).

| file | |
|---|---|
| `decimal.php` | the extension |
| `mcphp.toml`, `mcphp.linux.toml`, `mcphp.windows.toml` | one per host, as `examples/hello` |
| `check.php` | the differential |
| `soak.php` | the memory gate: a million calls in one request |
| `c/decimal.c` | the C twin |
| `bccheck.php` | the bcmath cross-check |
| `bench.php` | the bench row |

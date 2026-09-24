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
| the bench row | `bench.php`: three ten-year loan schedules, ~1500 calls a run, a warm-up and the best of nine per process, the interpreted and compiled processes interleaved three times. The two answers must be equal; the ratio is printed and not gated |

Measured on 2026-09-23 by `tests/examples.sh`, each host against its own php 8.5 (the CI rows are the pull request's first run):

| host | interpreted | compiled | ratio |
|---|---|---|---|
| macos/arm64, this repository's own Mac | 1.72 ms | 3.41 ms | **0.51x** |
| macos/arm64, CI (`macos-15`) | 2.03 ms | 4.10 ms | 0.50x |
| linux/aarch64, CI (`ubuntu-24.04-arm`, container) | 3.08 ms | 6.71 ms | 0.46x |
| linux/x86_64, CI (`ubuntu-24.04`, container) | 3.76 ms | 7.33 ms | 0.51x |
| windows/x86_64, CI (`windows-latest`) | 4.19 ms | 7.24 ms | 0.58x |
| windows/arm64, CI (`windows-11-arm`, x64 php emulated) | 8.68 ms | 10.70 ms | 0.81x |

**The compiled module is SLOWER than the interpreter on this workload**, and that is the honest
number. A decimal is string work, and php's string functions -- `substr`, `str_pad`, `ltrim`,
`strspn` -- are C inside the interpreter, where mc-php's are mc, and every string one of them
builds is a new allocation in D7's arena. Built with mc's optimizer (`[project].opt = 1`,
measured once and not adopted here) the compiled column is 2.4 ms, 0.74x. `docs/plan.md` § 7
item 1 is the road to the rest.

## What it cannot do yet

* **The arena.** D7 is one 48 MiB arena per PROCESS, never freed (`docs/php-extension.md` § The
  memory), and a module outlives every request. Measured: about **31 000** `dec_add("12.5",
  "7.25", 2)` calls, **13 000** `dec_mul` or `dec_div` at ordinary sizes, and **fewer than 1 000**
  divisions of a 30-digit number by a 21-digit one exhaust it, and the process ends with
  `mc-php: arena exhausted`. The gates are sized to fit; a server that calls it for ever is not.
  A request lifecycle (`RINIT`/`RSHUTDOWN`) is what answers it.
* **Private helpers.** Every top-level function of an extension source is published, so the
  `_dec_*` helpers are callable from php too, and each takes only scalars because an exported
  signature must. A class would keep them private -- a class the source declares is not
  published -- but its methods are dispatched by name through the runtime's class table, which
  is slower, and their parameters and returns are `mixed`, which D4 then refuses to assign to a
  typed local.
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
| `bccheck.php` | the bcmath cross-check |
| `bench.php` | the bench row |

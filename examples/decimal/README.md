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

**The algorithm is `c/decimal.c`'s.** The C twin is the specification and `decimal.php` says the
same thing function by function: each operand parsed once into its digits, base-10 arithmetic one
digit at a time (schoolbook multiplication, long division by repeated subtraction), each result
digit written into a string of the right length. What PHP cannot say the way C does is written
down in the source: three locals for C's `dnum` (a function returns one value), an index where C
moves a pointer past zeros, and a new string where C writes into its caller's buffer.

## How it is checked -- `tests/examples.sh`, on all five hosts

| step | |
|---|---|
| the differential | `check.php` runs twice -- with `decimal.so` loaded, and with `decimal.php` required -- and the two must print the same bytes on both streams and exit the same: 60 lines, every tie in both signs, the four operations at three scales, a ledger, and the seven wrong VALUES |
| bcmath | `bccheck.php`, where the host php has bcmath: 1219 results of the module against bcmath's exact result rounded by `bcround(..., RoundingMode::HalfEven)` -- add, sub and mul exact at the sum of the scales, a quotient taken to 80 digits first. It ran, 0 wrong, on macos/arm64, windows/x86_64 and windows/arm64 in CI; the `php:8.5-alpine` image the Linux legs use has no bcmath, and the gate says `SKIPPED` there |
| what is published | `get_extension_funcs("decimal")` is the six `dec_*` names: the `_dec_*` helpers are module-private (a leading underscore, `docs/php-extension.md` § What is published) |
| the soak | `soak.php`: **1 000 000** `dec_add` calls in ONE request after a thousand warm-up calls, and `memory_get_usage()` and `memory_get_peak_usage()` must each move less than a kilobyte (the answer must be `12500000.00`) |
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
run, 36052255981 (runners differ between runs by up to ~40% in absolute time, so the ratio is what compares;
only `macos-15` has `php-config` and `cc` for the C column):

| host | main: interpreted / module | ratio | decimal-c: interpreted / module | ratio |
|---|---|---|---|---|
| macos/arm64 (`macos-15`) | 2.099 / 1.248 ms, twin 0.172 | 1.68x, module/C 7.3 | 2.060 / 0.803 ms, twin 0.171 | **2.57x**, module/C **4.7** |
| linux/aarch64 (`ubuntu-24.04-arm`, container) | 3.091 / 1.775 ms | 1.74x | 3.088 / 1.167 ms | **2.65x** |
| linux/x86_64 (`ubuntu-24.04`, container) | 2.980 / 2.194 ms | 1.36x | 3.693 / 1.482 ms | **2.49x** |
| windows/aarch64 (`windows-11-arm`, x64 php emulated) | 8.778 / 2.942 ms | 2.98x | 8.759 / 1.897 ms | **4.62x** |
| windows/x86_64 (`windows-latest`) | 6.510 / 2.349 ms | 2.77x | 5.541 / 1.530 ms | **3.62x** |
The largest single steps: `_dec_umul`'s arrays are native int buffers now (the compiler proves they
hold only ints and never leave the function, `src/packed.mc`), `_dec_coef`'s two one-byte
`str_replace` deletions are one pass, and a cast no longer swallows the `- $borrow` after it.

What still separates the module from the twin is mostly the ALGORITHM both php and the module run:
a number is a string, so every operation re-validates and re-parses its operands and makes new
strings for its intermediate values, where the twin parses each operand once into digits and
writes into one buffer; the rest is named in `docs/plan.md` § 7 (mc's code for a leaf function,
§ 5).

**Three columns, the zend-mm batch** (2026-09-24, macos/arm64, php 8.5.10, one host, one sitting,
five rounds interleaved, main's module and this batch's side by side; `decimal.php` byte for byte
what it was). Every string a call builds is now php's own `zend_string` -- `_emalloc`ed,
refcounted, `_efree`d when its last reference goes -- and a result goes back to php as that same
string, where main bumped strings through a chunk it zeroed on every return and copied the result
out (`docs/php-extension.md` § The memory):

| | interpreted | the module | the C twin | module / C |
|---|---|---|---|---|
| main (decimal-c) | 1.70-1.79 ms | 0.524 ms (3.25x) | 0.125 ms (13.6x) | 4.19 |
| zend-mm | 1.70-1.79 ms | **0.606 ms (2.81x)** | 0.125 ms | **4.85** |

It is SLOWER on this workload, and `docs/plan.md` § 7 item 1 has the profile: memory is 18.8% of
the module's time against main's 15.0%, because each of the eleven or so strings a `dec_add`
builds costs an `_emalloc` and an `_efree` -- php's own price for a string, which the twin avoids
by allocating two or three times a call. What it buys: no chunk zeroed on return, no result
copied, a loop inside one call that keeps a bounded peak, `.=` in place, and a leak check that
names nothing (`tests/leaks.sh`, a debug php). The soak, 1 000 000 calls in one request: usage
517 336 -> 517 336 bytes, peak 517 544 -> 517 560 -- the 16 bytes are the call's temporaries
growing with the accumulator's three extra digits (`soak.php` says why).

On every CI leg (`tests/ext.sh`'s bench line, best of nine, three rounds interleaved; main is run
36056378453, this batch run 36078460677; the Linux and Windows runners have no `php-config` with a
`cc`, so there is no C column there):

| leg | interpreted | main's module | zend-mm's module | C twin (main / zend-mm) |
|---|---|---|---|---|
| macos/arm64 | 1.991 / 2.106 ms | 0.774 ms (2.57x) | 0.906 ms (2.32x) | 0.159 / 0.172 ms |
| linux/aarch64 | 3.086 / 3.090 ms | 1.169 ms (2.64x) | 1.445 ms (2.14x) | -- |
| linux/x86_64 | 3.567 / 3.828 ms | 1.399 ms (2.55x) | 1.850 ms (2.07x) | -- |
| windows/aarch64 | 8.754 / 8.771 ms | 1.895 ms (4.62x) | 2.640 ms (3.32x) | -- |
| windows/x86_64 | 6.949 / 6.881 ms | 1.630 ms (4.26x) | 2.007 ms (3.43x) | -- |

The soak on the same runs, a million calls in one request: usage moved 40 bytes on every leg on
main and moves 0 now; peak moved 0 on main and 16 bytes now (e.g. linux/x86_64 usage 501 816 ->
501 816, peak 502 024 -> 502 040).

**Three columns, the core-strings batch** (2026-09-25, macos/arm64, php 8.5.10, one host, one
sitting, nine rounds interleaved; `decimal.php` byte for byte what it was). Every gain is in the
compiler and its runtime -- `docs/plan.md` § 7 item 1 has the profile and what each step bought:

| | interpreted | the module | the C twin | module / C |
|---|---|---|---|---|
| zend-mm (main) | 1.744 ms | 0.608 ms (2.87x) | 0.125 ms (13.95x) | 4.86 |
| core-strings | 1.744 ms | **0.434 ms (4.02x)** | 0.125 ms | **3.47** |

Fewer strings built per call (`dec_add` 8 -> 5, `dec_div` 34 -> 14; `tests/examples.sh` gates the
counts), the small `_dec_*` helpers copied into their callers, a peephole machine derived from
mc's (immediates, folded offsets, one branch per loop exit), and a handler that reads and checks
its arguments in place.

**Three columns, the same-algorithm batch** (2026-09-27, macos/arm64, php 8.5.10, one host, one
sitting, every column below interleaved nine rounds; `bench.php` unchanged). Until now
`decimal.php` re-validated and re-parsed its operands on every call, worked nine digits at a time
and built a new string per step, while the twin parses once and works digit by digit in buffers
-- two algorithms, so the columns did not measure one thing. Now `decimal.php` is the twin's
algorithm (above), and the batch took the module as close to the twin as the compiler could go:

| | interpreted | the module | the C twin | module / C |
|---|---|---|---|---|
| main, the old `decimal.php` | 1.725 ms | 0.440 ms (3.92x) | 0.127 ms (13.58x) | 3.46 |
| the twin's algorithm, main's compiler | 2.641 ms | 0.941 ms (2.81x) | 0.127 ms (20.80x) | 7.41 |
| the twin's algorithm, this batch | 2.641 ms | 0.398 ms (6.64x) | 0.127 ms | 3.13 |
| the same, after the review's drain fix (a second sitting, nine rounds) | 2.616 ms | **0.417 ms (6.27x)** | 0.126 ms | **3.31** |

The interpreter is slower on the twin's algorithm (a byte at a time is dear in php) and so was the
module on main's compiler: every `$s[$i]` read built a one-byte string, every `$s[$i] = ...`
built a zval, every packed element was a call. Each change below is in the compiler or its
runtime, measured in the same sitting (`tests/examples.sh`'s own row on the final tree: 2.637 /
0.408 / 0.126 ms, 6.46x and 20.93x):

| change | the module | module / C |
|---|---|---|
| the rewrite, main's compiler | 0.941 ms | 7.41 |
| `$s[$i] = STRING` writes the string, no zval; `str_repeat` of one byte a word at a time | 0.841 ms | 6.62 |
| `ord($s[$i])` is the byte, read in place (`php_str_byte`) | 0.689 ms | 5.43 |
| `$s[$i] = chr($c)` is the byte, written in place (`php_str_setb`) | 0.625 ms | 4.92 |
| the runtime's small routines copied into the compiled code after the counting pass (`src/opt.mc` `phr_*`): the byte read and write, the packed element read and write, the overflow-checked `+ - *` | 0.576 ms | 4.54 |
| a `for` with no `continue`: the step follows the body, no first-iteration flag | 0.550 ms | 4.33 |
| those copies take an argument of the same width and signedness as it is, and return into the local they are assigned to | 0.534 ms | 4.20 |
| each routine a fast path with no call and a `_slow` half; the position and the unwinding check move into the slow halves, and a check nothing can have raised before is dropped | 0.501 ms | 3.94 |
| a packed array's one bound test (its length is 0 once it is a hash); one unwinding tail per function | 0.469 ms | 3.69 |
| `intdiv` copied; a two-window concatenation without `php_win` | 0.449 ms | 3.54 |
| `strspn` with a literal set, a three-argument routine | 0.448 ms (0.440 against 0.448 head to head, fifteen rounds) | 3.53 |
| `c ? 1 : 0` and any two int literals: arithmetic, not a branch (the carry was a random branch) | 0.426 ms | 3.35 |
| no pool drain at the top of a loop that builds nothing | 0.408 ms | 3.21 |
| `str_repeat` of nothing, or of one byte once: the shared strings | 0.398 ms | 3.13 |
| the review: a loop whose slow halves can raise a diagnostic keeps its drain (the text is built in the pool: 100 000 out-of-range reads grew php's peak 8.4 MB, `tests/ext.sh` step 12b) | **0.417 ms** (0.399 against 0.417 head to head) | **3.31** |

What separates the two now, measured on the tree before the review's drain fix (the gap was
0.271 ms; `xctrace`, and builds with one cause taken out; the fix adds 0.018 ms of the pool test
back to the loops whose slow halves can raise a diagnostic):

| cause | share | class | what removing it takes |
|---|---|---|---|
| php's checks on the hot path: a string offset's bounds, a packed key's bounds and the null flag of the element read, the integer overflow that php would turn into a float | 0.037 ms (a build without them: 0.361 ms) | (c) php semantics | nothing the compiler may do: each is php's defined behaviour |
| the position announced and the exception checked per statement | 0.003 ms (a build without them: 0.401 ms) | (a), done here | -- (measured the same way halfway through this batch, before the move: 9% and 6% of the module) |
| building strings: `strspn` scans, copies, window concatenations, allocation, `str_repeat` -- 31% of the module's samples | about 0.12 ms, against 0.043 ms (34% of the twin's samples) in the twin's `_emalloc`/`_efree`/`memmove`/`memset` | mostly (c): a php string is a value, so a helper answers a new string where the twin writes into its caller's buffer (`dec_div` builds 107 strings a call); partly (a), the call per small routine | measured and not taken: copying `strspn`'s loop into its callers made the module 8% SLOWER and copying the window concatenation's two `memcpy`s 5% slower -- mc's registers, below |
| the compiled functions' own code: 46% of the module's samples | about 0.18 ms, against 0.066 ms (52% of the twin's) | (b), unproven | mc's allocator gives at most ten callee-saved registers to a whole function, so `_dec_umul`'s inner loop reads `$i`, `$x` and `$nb` from the frame every iteration; an index is scaled by `mul`; `a && b` is made a value and then tested. A derived machine could lend the allocator caller-saved registers spilled around calls; not built (the core-strings batch measured leaf `x0..x7` at +1%) |
| the extension boundary: the handler's entry, exit and argument checks | 2.5% of the module's samples, about 0.010 ms | (a), small | -- |
| Zend's VM running `bench.php` and the calls themselves | 0.021 ms, in both columns (a null twin: the six functions read their arguments and answer a constant) | common | -- |

So the module is 3.31x the twin, 6.27x php interpreting the same source, and what is left is
php's own checks (0.037 ms), php's strings being values, and mc's register allocation -- the last
unproven. The soak on the final tree: a million `dec_add` calls, usage 517 656 -> 517 656 bytes,
peak 517 928 -> 517 960.

**Three columns, the instruction-selection batch** (2026-09-27, macos/arm64, php 8.5.10, one host,
one sitting, fifteen rounds interleaved, best of nine each; `decimal.php` and `bench.php`
unchanged). The (b) row above, taken item by item: each candidate was first BOUNDED by
hand-patching the built module and timing it, and only what the bound showed was built.

The bounds, `_dec_umul`'s inner loop (59 instructions an iteration, the C twin's is 8) rewritten
by hand with every candidate applied and then with one taken out at a time, three sittings (a
rebuilt copy of the loop with nothing changed is the control, 0.409-0.416 ms):

| candidate | the loop | all four applied | without it | its share |
|---|---|---|---|---|
| scaled addressing (`ldr x, [base, idx, lsl #3]` for `mov #8; mul; add; ldr`) | -8 insns | 0.386-0.389 ms | 0.390-0.393 ms | ~0.004 ms |
| overflow fused (`adds; b.vs` for `add; eor; eor; and; cmp; b.ge`) | -3 insns | | 0.388-0.390 ms | ~0.001 ms, noise |
| **slow halves out of line** (the fast path falls through every guard; six taken branches an iteration become one, the back edge) | -4 insns | | 0.402-0.403 ms | **0.016 ms** |
| index arithmetic (`$i + $j` once, no `mov x9, xN` copies) | -6 insns | | 0.392 ms | ~0.005 ms |
| the pool test | -- | removing it outright, an upper bound for any cheaper form: 0.409-0.411 ms against 0.393 ms WITH it, three sittings -- slower, not faster, so no cheaper form was built | | none |

Built, and re-bounded on the module that has it:

| change | the module | module / C |
|---|---|---|
| main | 0.413-0.414 ms | 3.29-3.30 |
| **P10, the slow halves out of line** (`src/mach.mc`, both machines; `MCPHP_LAYOUT=0` turns it off alone): once a function is finished, a straight-line region the code jumps over whose first call is a `_slow` routine, `php_rc_drain` or `php_pk_overflow` moves past the epilogue, and the branch over it goes (or, when it was the fallthrough, is inverted) | **0.393 ms (6.66-6.68x the interpreter)** | **3.12-3.14** |
| then P11, no copy out of a local's register for a cast to 8 bytes (the `mov x9, x21` of every bounds check) | 0.393 ms against 0.391-0.393 | reverted: no gain |
| then scaled addressing at all 29 sites in the module (hand-patched) | 0.391-0.393 ms against 0.392-0.393 | not built: no gain |
| then `a && b` as two branches instead of a value tested (`_dec_uadd`/`_dec_usub`'s in-place byte write, hand-patched) | 0.391-0.393 ms against 0.391-0.393 | not built: no gain |
| then the loops' frame loads in caller-saved registers (the 1.4% of the registers measurement, re-bounded on this module): `_dec_umul` | 0.390-0.392 ms against 0.391-0.393 | not built: at the noise |
| the same, `_dec_uadd` / `_dec_usub` / all three | 0.404-0.405 / 0.391-0.394 / 0.401-0.403 ms | not built: slower or nothing |

`tests/examples.sh`'s own bench row on the final tree (a busy host, the ratios are what compare):
3.373 / 0.547 (6.17x) / 0.160 ms. Head to head, main's module and this one interleaved with the
interpreter and the twin, fifteen rounds, two sittings: interpreted 2.616-2.625 ms, main 0.413-0.414
ms (6.33x, module/C 3.29-3.30), **this batch 0.393 ms (6.66-6.68x, module/C 3.12-3.14)**, the twin
0.125-0.126 ms.

So of the four instruction-selection items only the layout moved the time: the loop is bound by
its taken branches, not by its instruction count, and removing 17 more instructions from it
bought 0.004 ms. What is left of the (b) row is below the noise on this host.

**C only** (the `c-only` branch, after #26). The owner's correction: a compiled program ALWAYS
behaves like C. The `php` mode below, its source comment and `MCPHP_SEMANTICS` are gone, and
`c-debug` is now the one project key `[php] checked_reads = true`. The measurements below are
kept as they were taken; the modes they name are history.

**Three columns, C semantics** (2026-09-27, macos/arm64, php 8.5.10, one host, one sitting,
fifteen rounds interleaved, best of nine each; `decimal.php` and `bench.php` unchanged). The
owner's decision: a compiled mc-php program behaves as C does where C and php part ways, BY
DEFAULT -- an int that overflows wraps, and a string offset or a packed array element read in
range is the read and nothing else ([`docs/semantics.md`](../../docs/semantics.md) lists every
difference, and how to get php's rules back). A read outside the range is undefined behaviour
under these rules. The decimal never makes one, and `semantics = "c-debug"` proves it on this
workload: that build checks every such read as a trap, and it answers `check.php` and bcmath
exactly.

The bounds, each a build of the module with one rule changed (a direct measurement: the change is
small enough that building it IS the bound):

| rule | the module | its share |
|---|---|---|
| main (c63cedd), php's rules | 0.392 ms | -- |
| reads unchecked (`$s[$i]`, `ord($s[$i])`, `$s[$i] === 'c'`, `$a[$k]`), overflow still checked | 0.378-0.380 ms | 0.013 ms |
| and `+ - *` on an element wrapping instead of the overflow test | **0.358 ms** | 0.021 ms more |
| and no `ph_pkabs = 0` store in the read (an element is never php's null under C's rules) | 0.359 ms | none: reverted |
| string reuse in place (item 4 of the request): the bound, below | at most ~0.007 ms | not built |

**The review of #26 found that the bounds above measured an UNSAFE read.** A proven packed array
still becomes php's hash when a store falls outside it (`$a = array_fill(0, 1, 7); $a[3] = 9;`),
and the unchecked read went on reading the stale dense buffer: `$a[3]` answered 7 where php says
9, and `c-debug` trapped a valid key. The read now tests the packed-or-hashed state first
(`lib/php_rt.mc` `php_pk_get_c`) and takes the hash's own lookup after a transition. That test is
the price of a correct C read, measured:

| rule | the module | module / C |
|---|---|---|
| C's rules as first built (reads the stale buffer after a transition: wrong) | 0.358 ms | 2.87 |
| **with the packed-state test** | **0.366-0.367 ms** | **2.94** |

The fix had one more cost, and it is not there any more. The new slow call sits at the TOP of
`_dec_umul`'s inner loop, and the out-of-line pass (`src/mach.mc` P10, #25) moved that whole
loop body past the epilogue as though it were a slow half. That made the build 0.375 ms. P10 now
refuses a region that holds a branch back to before its start, a loop's back edge. `php` mode is
the same 0.392 ms it was, and the gates that read P10 back are unchanged.

The same compiler, the three semantics of the same source, interleaved (measured before the
review; `c` is 0.367 ms with the fix):

| | the module | module / C |
|---|---|---|
| `php` (the grid's) | 0.390-0.391 ms | 3.12 |
| `c-debug` (the reads checked again, as a trap) | 0.388-0.391 ms | 3.11 |
| **`c`, the default** | **0.358-0.359 ms** | **2.87** |

Head to head, main's module and this one interleaved with the interpreter and the twin, fifteen
rounds, two sittings, after the review's fix: interpreted 2.614-2.620 ms, main 0.392-0.394 ms
(6.63-6.68x, module/C 3.14-3.15), **C semantics 0.367 ms (7.12-7.14x, module/C 2.94)**, the
twin 0.125 ms (before the fix: 0.359 ms, 2.87)
(`tests/examples.sh`'s own row: 2.629 / 0.360 / 0.126 ms, 7.30x and 20.87x).

**The string item, measured and not built.** In `php` mode as in `c`, the bench's `work()` builds
12 447 strings (`MCPHP_STATS=1`), and php's own `_emalloc`/`_efree` are 8% of the samples, the
module's `php_str_alloc` 5% and the pool drain 4% -- about 0.06 ms for all of them, 5 ns a string.
The strings a reuse could avoid are `_dec_fmt`'s: `$c = substr($c, ...)` and the three `.=` that
build `$o` (a straight-line function does not count its strings, so its locals borrow from the
pool, and an in-place write there needs to know no other local holds the same string). That is 3
of the 7 strings of a `dec_add`, 1 440 of the 12 447 -- about 0.007 ms at 5 ns. Two rewrites of
`_dec_fmt` in the source, which is what the compiler would reach at best, both came out SLOWER:
the answer built in one expression (7 strings a call to 6) 0.363 ms, and the answer written byte
by byte into one `str_repeat` of its final length (2 888 strings fewer a `work()`) 0.367-0.368 ms,
against 0.358-0.360 ms.

**Toward 2x: decimal-2x** (2026-09-27, macos/arm64, php 8.5.10, one host, one sitting, fifteen
rounds interleaved, best of nine each; `decimal.php` and `bench.php` unchanged in this round). Each change was
built alone and measured against the build before it -- time with `bench.php`, and instructions
and cycles per call with `/usr/bin/time -l` over a million calls of each function -- and one
that did not gain was reverted.

| change | where | the module |
|---|---|---|
| c-only (the start) | | 0.367 ms |
| an argument read once is the expression, and a copy that is one `return E` is E (the inliner's locals were spilled in the loops it was copied into) | `src/opt.mc` | 0.348 ms |
| an element read is an int, never php's null: no null flag, no `ph_pkabs` store | `src/packed.mc`, `src/expr.mc` | 0.346 ms |
| a FIXED array -- every keyed store is `$a[K] = ... $a[K] ...` -- is never a hash: C's read and store, no packed-state test, no bound; `_dec_umul`'s inner loop has no call left, so it has no drain either | `src/packed.mc` | 0.328 ms |
| the answer of `return f(...)` stays on the caller's side of the pool: no take, no push (`php_rc_ret`) | `src/rc.mc` | 0.324 ms |
| a FRESH buffer -- made by `str_repeat` and written only byte by byte -- is written with the bound as the one test: no refcount, flags, counter or hash reset, and its slow half leaves the pool as it was, so the loop has no drain | `src/rc.mc` | 0.315 ms |
| a string built by appends is ONE string of the final length (a rope of windows, `php_str_rope`), with the window test in place | `src/opt.mc` | 0.301 ms |
| `phx_enter`/`phx_leave`'s fast paths copied into the handler | `lib/php_ext.mc`, `src/ext.mc` | 0.295 ms |
| `&&`/`||` folded back from their u8 temporaries into mc's own, and `if (a && b) X` into nested ifs | `src/opt.mc` | 0.289 ms |
| P11, a leaf keeps its locals in caller-saved registers; then a tail call allowed in one | `src/mach.mc` | 0.287, 0.283 ms |
| the fold moved after the runtime copies, so a byte read on a right side is a copy and not a call | `src/opt.mc` | 0.277 ms |
| `$d . str_repeat('0', n)` in one string (`php_str_catrep`) | `src/opt.mc`, `lib/php_rt.mc` | 0.276 ms |
| `php_memcpy` without overlapping stores: 8 bytes a step, then 4, 2 and 1 | `lib/php_rt.mc` | 0.271 ms |
| `strspn` over a set that is one run of bytes compares a range (`php_spn_r`) | `src/builtin.mc` | **0.266-0.267 ms** |

Measured and NOT built (no gain in time, or slower):

| change | measured |
|---|---|
| appends in place with `_erealloc` for a local only its own `.=` reads | 0.333 ms against 0.328: SLOWER. A bin change is an allocation, a copy and a free, and the frees no longer go in one pass of the pool |
| small copies as two OVERLAPPING word or halfword stores in `php_str_rope`/`php_memcpy` | 0.325 against 0.294: SLOWER by 10%. The bytes just written are read back at once, and a load that spans two stores is not forwarded |
| small copies as a byte loop | 0.312 and 0.298 against 0.309 and 0.295: slower (a taken branch a byte) |
| a static array's buffer address in a local, and an element's address computed once for its read and its store (`_dec_umul`'s inner loop 26 -> 18 instructions, `dec_mul` 8641 -> 8035 instructions a call) | 1099 against 1094 cycles a `dec_mul`: no gain. The loop is not bound by its instruction count |
| `strspn`'s loop two bytes a turn; `_dec_umul`'s inner loop unrolled by two in the source | 0.268 against 0.266 and 0.274 against 0.266: slower |
| `$s === 'c'` as the length and the byte in place | 0.267 against 0.267 |

Per call against the twin, a million calls each (instructions / cycles, `/usr/bin/time -l`, the
loop's own cost taken out):

| | c-only | this branch | the C twin | cycles, branch / C |
|---|---|---|---|---|
| `dec_add` | 5151 / 653 | 3937 / 493 | 1658 / 242 | 2.04 |
| `dec_sub` | 5419 / 702 | 4161 / 512 | 1662 / 256 | 2.00 |
| `dec_mul` | 12308 / 1575 | 8470 / 1079 | 2737 / 430 | 2.51 |
| `dec_cmp` | 2390 / 302 | 1712 / 206 | 830 / 121 | 1.70 |
| `dec_div` | 65885 / 8216 | 56004 / 7221 | 6191 / 1220 | 5.92 |

**The three causes, attacked** (2026-09-28, the same host and method; the owner's rule that mc
already lets a module teach whatever instruction it needs). Each was bounded before it was built:

| cause | bound (measured first) | built | measured |
|---|---|---|---|
| `dec_div` builds a remainder string per step of its long division | representation, not a floor: the twin keeps one buffer | `_dec_udivmod` keeps the twin's one remainder buffer of nb + 2 digits, compared and subtracted where it lies (`decimal.php`; the answers are the same, 20000 random divisions byte for byte) | `dec_div` 7217 -> 3130 cycles a call, 10300 -> 1300 strings for 100 calls; bench 0.266 -> 0.259 ms |
| the carry loop's two `sdiv` against the twin's multiply-high | division made free (a shift in its place, wrong answers, timing only): -75 cycles a `dec_mul` | P12 (`src/mach.mc`): a signed `/` or `%` by a constant is `smulh` by the magic number, an immediate shift, the sign added back (Hacker's Delight 10-1, what clang writes); `intdiv()` by a positive literal is mc's own `/`. `smulh` and the immediate shifts are new forms in the machine's band | `dec_mul` -13 to -33 cycles; the bench within its noise. The loop is bound by its spills and the chain through the carry, not by the division any more |
| the twin's inner loop is NEON | clang vectorises only the digit loads (`rev64`): a 64-bit multiply has no NEON form, so the multiplies stay scalar. Removing the loop costs the twin 195 cycles a `dec_mul`; our loop, hand-written into the `.so` as 8 scalar instructions, costs less than that. So no SIMD: the bound is a short scalar loop | the element address once (`ph_addm64`, `src/lvalue.mc`), an address's constants summed into the load's offset (`src/opt.mc`), and `x + (y << 3)` as one add (P13): the loop from 26 instructions to 15. Measured with the loop patched by hand first: 16 and 17 instructions gained nothing, 15 did, and each of the three changes alone gains nothing | `dec_mul` 1055 -> 946 cycles; bench 0.259 -> 0.250 ms |

Measured and not built: a leaf's frame dropped when nothing uses it (no gain); `48 + x` with the
constant on the left as an immediate (slower); `php_spn_r` copied with its loop into its callers
(+75 cycles a `dec_add`: the callers spill); `php_memcpy` inline in the rope (-7 cycles, noise);
the fresh buffer's bound test removed in the digit loops (-1%, a range proof not worth its code).

| | this branch before | now | the C twin | cycles, now / C |
|---|---|---|---|---|
| `dec_add` | 3937 / 493 | 3936 / 487 | 1658 / 241 | 2.02 |
| `dec_sub` | 4161 / 512 | 4153 / 510 | 1662 / 244 | 2.09 |
| `dec_mul` | 8470 / 1079 | 7700 / 945 | 2737 / 427 | 2.21 |
| `dec_cmp` | 1712 / 206 | 1692 / 200 | 829 / 116 | 1.72 |
| `dec_div` | 56004 / 7221 | 24077 / 3153 | 6191 / 1190 | 2.65 |

**The floor, now.** `bench.php` is 0.250 ms against the twin's 0.125 (2.00x; 1.97x to 2.02x over
the runs of this sitting). None of the three named causes is the floor any more: what is left is
spread thin. The largest single items of a run are `_dec_umul` (10%), `php_memcpy` and
`php_spn_r` (8% each), `_dec_addsub`, the rope, the allocator and `_dec_fmt` (5-8% each), and
their cost is per call and per spill rather than per loop: `_dec_addsub`, with the helpers it
copies in, is 10722 instructions long with an 832-byte frame; the carry loop keeps `$t` and the
carry in the frame because ten callee-saved registers go to the inner loop's variables (mc's
allocator gives a local one register for the whole function), and making the carried values
registers by hand (`$t` in `$j`, the carry in `$x`) moved 9 cycles.

**Under 2x: decimal-under-2x** (2026-09-28, the same host and method; every ratio below is the
module's best of nine over the twin's in the SAME round, and the range is over 15 rounds).
Each lead was bounded first; what gained was built, and the rest was measured and reverted.

| change | where | module / twin per round (median, min-max) |
|---|---|---|
| the start (#29) | | 2.008 (1.961-2.048) |
| P15: a branch on `&&`/`\|\|` branches on its terms -- mc's walker made every `&&` a value, a cset, a jump and a move per term before the one test (the handlers' enter/leave fast paths, the runtime's range tests) | `src/mach.mc` | 1.992 (1.953-2.024) |
| a handler copies in the php function it wraps when that one is small and loop-free (`dec_add`, `dec_sub` forward to `_dec_addsub`) | `src/ext.mc` | 1.945 (1.929-1.984) |
| `_dec_fmt` carries the index of its first kept digit, as the twin moves its pointer, where it built `substr($c, skip0)`: add, sub and a scale-up read the magnitude where it lies and build only the answer (40000 random pairs through all six functions: one md5 from the old file, the new one, the module and the twin) | `decimal.php` | **1.794 (1.756-1.848)** |

`bench.php`: 0.225 ms median (0.222-0.230) against the twin's 0.126 (0.125-0.128), from 0.254.
Per call (instructions / cycles): `dec_add` 3397 / 427 against 1658 / 236 (1.81), `dec_sub`
3614 / 448 against 1662 / 243 (1.84), `dec_mul` 7037 / 854 against 2737 / 428 (2.00), `dec_cmp`
1651 / 198 against 829 / 109 (1.82), `dec_div` 22693 / 2905 against 6191 / 1181 (2.46).

Where the gap was, stage by stage (each operation cut short after one stage, both sides, cycles a
`dec_add` at the start of the round): entry 47 against 15, parse 43 and the digits 107 against
the twin's parse-and-copy 52, the addition 96 against 40, and `_dec_fmt` 177 against 77 -- of
which 30 were the call and 102 the rope. The index is what closed most of `_dec_fmt`'s share.

Measured and not built (each against the build before it; no gain, or slower):

| change | measured |
|---|---|
| a throw's block moved out of line with the slow halves (P10) | 0.250 against 0.251: no gain; `_dec_addsub`'s cost is its stack traffic, not its cold code |
| loop heads aligned to 16, 32 or 64 bytes (nop padding, functions padded, `__text` aligned), and the same with the padding jumped over | 0.250-0.253 against 0.250: no gain, and the executed nops cost more than they align |
| `_dec_fmt`'s answer written byte by byte into a `str_repeat` buffer instead of the rope | +5 cycles a `dec_add`: the byte loops cost what the rope does |
| the kept digits of a rounding `_dec_fmt` read where they lie too | no gain: the bench's rounding goes up, which builds them anyway |
| a local read right after it was written taken from the register (P16) | 0.254 against 0.246: slower |
| a loop tested at its bottom, clang's rotation (P17) | median 2.016 against 1.961: slower (the jump in on every entry of a short loop) |
| a full-width cast emitting nothing | `dec_mul` +60 cycles |
| `madd` for the multiply loop's `+=` | 849 against 843 cycles a `dec_mul` |
| raising the inliner's size limit (`_dec_fmt` copied in) | +200 instructions, no gain |
| the big public functions (`dec_mul`, `dec_cmp`) copied into their handlers too | `dec_mul` +127, `dec_cmp` +106 cycles |
| libc's `memcpy` for `php_memcpy` | +26 cycles a `dec_add` |

**The floor, now.** 1.79x (1.76-1.85 over the rounds), never above 2x. What remains is spread
over per-call overheads, and none of it moved when attacked directly:

* `_dec_umul` (12% of a run): the inner loop is 15 instructions and runs at about 1.7 cycles a
  step; `madd` and rotating it (measured by hand in the `.so`) move it by 0-2%. The carry loop
  divides twice by 10 where clang divides once: doing it once in the source made the function
  28% slower, because the new local took a register from the inner loop's (mc's allocator gives a
  local one register for the whole function).
* `php_spn_r` and `php_memcpy` (8% each), the rope, the allocator and the pool's drain (4-6%
  each): short scans and short copies, a few per operation, whose cost is the call itself.
  Copying `php_spn_r` into its callers made them spill (+75 cycles a `dec_add`); a byte loop,
  overlapping stores and libc's `memcpy` were all slower than `php_memcpy`.
* The code's layout: an unrelated change moves a hot loop and the result by 2-7%, which is also
  why several changes that remove instructions measured slower.

**Per function, under 2x every one** (2026-10-08, the bcmath port's batch; macOS/arm64, each
row the best of five rounds, each round `bench.php`'s own best of nine with `MCPHP_EACH=1`,
module and twin interleaved):

| function | module (ms) | C twin (ms) | module/C |
|---|---|---|---|
| `dec_add`   |  3.940 |  2.661 | **1.48x** |
| `dec_sub`   |  4.080 |  2.600 | **1.57x** |
| `dec_mul`   |  5.888 |  3.357 | **1.75x** |
| `dec_div`   | 15.892 | 11.516 | **1.38x** |
| `dec_cmp`   |  2.975 |  1.635 | **1.82x** |
| `dec_round` |  2.711 |  1.496 | **1.81x** |

The loan workload (`tests/examples.sh`): compiled 0.373 ms against the twin's 0.240 (1.55x).
`decimal.php` is unchanged; the gains are the compiler's and the runtime's, made for
`examples/bcmath` and general: views for a `substr()` local and windows counted along paths
(`src/opt.mc`), fresh buffers written in place (`src/rc.mc`), string blocks kept per size class
and the drain's push inline (`lib/php_ext.mc`), integer literals substituted into a copied
routine, a store keeping its folded offset (`src/mach.mc`), a rope piece of up to sixteen bytes
copied with no call, and -- what the carry loop above was waiting for -- int locals that are never
live at once sharing one local (`lc_fn`, `src/opt.mc`), so a later loop's counters get the
registers an earlier loop's dead ones held. `docs/plan.md` § item 4 has each change with what it
bought.

## What it cannot do yet

* **A wrong TYPE** is an internal function's message in the module and a userland one
  interpreted (`docs/php-extension.md` § What a wrong call says), so `check.php` does not make
  one. The wrong VALUES it makes are the same in both runs, because the source throws them.

Writing this example found two defects in the compiler's front end, both fixed with a fixture
(`tests/g/96-static-args.php`, `tests/g/97-elseif-string.php`), and one it worked around until
batch A fixed it: `str_replace` with an ARRAY search was a wrong answer (`Array to string
conversion`) rather than a refusal (`docs/plan.md` § 7).

| file | |
|---|---|
| `decimal.php` | the extension |
| `mcphp.toml`, `mcphp.linux.toml`, `mcphp.windows.toml` | one per host, as `examples/hello` |
| `check.php` | the differential |
| `soak.php` | the memory gate: a million calls in one request |
| `c/decimal.c` | the C twin |
| `bccheck.php` | the bcmath cross-check |
| `bench.php` | the bench row |

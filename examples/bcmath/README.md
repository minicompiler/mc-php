# bcmath -- php-src's ext/bcmath, ported to PHP and compiled by mc-php

`bcmath.php` is a faithful port of php's arbitrary-precision decimal library
(php-src `ext/bcmath`, libbcmath) written entirely in PHP and compiled by
mc-php into a native Zend extension, `build/bcmath_port.so`. No C is in the
port itself; the whole thing is ordinary PHP you can `require`.

    mc-php build examples/bcmath --config examples/bcmath/mcphp.toml
    php -d extension=examples/bcmath/build/bcmath_port.so -r 'echo bc_add("0.1","0.2",2);'   # 0.30

## The functions

The thirteen `bc_*` functions: `bc_add`, `bc_sub`, `bc_mul`, `bc_div`,
`bc_mod`, `bc_pow`, `bc_powmod`, `bc_sqrt`, `bc_comp`, `bc_scale`, `bc_floor`,
`bc_ceil`, `bc_round`. They are `bc_*` and not `bc*` because php's own bcmath
is loaded in the same process and php refuses to redeclare an internal
function (exactly as `examples/ctype` publishes `cty_*` and `examples/decimal`
`dec_*`). `check.php` and `bccheck.php` compare each `bc_X` against the
built-in `bcX`.

## Exact bcmath semantics

A number is a string, `[+-]?[0-9]*(\.[0-9]*)?`, parsed exactly as libbcmath's
`bc_str2num` parses it: both the integer part and the fraction may be empty, so
`""`, `"."`, `"+"`, `"5."` and `".5"` are all valid (0, 0, 0, 5, 0.5). No float
appears anywhere; the arithmetic is base-10 digit strings.

bcmath **TRUNCATES** at the scale -- it does not round. (`examples/decimal` is
the half-even example; this is a *different* rule, deliberately.) The
per-function scale and sign rules reproduce libbcmath's exactly, each confirmed
against the host php 8.5:

- **add / sub**: the exact sum/difference, truncated to `scale`.
- **mul**: the exact product truncated to `min(scale, scale_a + scale_b)`,
  padded to `scale` (`bc_mul('1.5','1.5',0)` is `2`, not `2.2`).
- **div**: the quotient truncated toward zero to `scale` fraction digits; a
  zero divisor is `DivisionByZeroError("Division by zero")`.
- **mod**: `num1 - trunc(num1/num2)*num2`, truncated to `scale`; the sign
  follows the dividend (`bc_mod('-10','3',0)` is `-1`); a zero divisor is
  `DivisionByZeroError("Modulo by zero")`.
- **pow**: an integer exponent only (`'2.0'` is the integer 2; `'2.5'` is a
  `ValueError`); for `e >= 0` the exact power truncated to `min(scale,
  scale_base*e)`; for `e < 0`, `1/base^|e|` truncated to `scale`; `x^0` is `1`;
  a negative power of zero is `DivisionByZeroError("Negative power of zero")`.
- **powmod**: modular exponentiation, integers only, exponent `>= 0`.
- **sqrt**: `floor(sqrt(num))` at `scale` fraction digits (an integer square
  root of `num` scaled by `10^(2*scale)`); a negative `num` is a `ValueError`.
- **comp**: each fraction truncated to the compare scale first, so
  `bc_comp('1.00001','1',2)` is `0` and `bc_comp('-0.1','0',0)` is `0` (a value
  that truncates to zero is not negative); returns -1 / 0 / 1.
- **floor / ceil**: integer result (scale 0), toward -inf / +inf.
- **round**: libbcmath's generic round at the default mode,
  `RoundingMode::HalfAwayFromZero` (the first dropped digit decides; `>= 5`
  rounds away from zero), with negative precision (`bc_round('1241757',-3)` is
  `1242000`). The non-default `RoundingMode` enum argument is not taken -- the
  default is the function's primary contract and is what this port implements.
- **scale**: `bc_scale()` reads, `bc_scale($n)` sets, the request default scale
  (per request, as bcmath's; starts at 0). A function called without a scale
  uses it.

A zero is never negative; a malformed number is `ValueError("bc_X(): Argument
#N ($name) is not well-formed")`; a negative scale is `ValueError("... must be
between 0 and 2147483647")` -- the same class and message text as the built-in
(with the port's own function name).

## The files

- `bcmath.php` -- the port (the `_bc_*` helpers are module-private: a leading
  underscore is not published).
- `c/bcmath.c` -- the C twin: the same functions written the ordinary way a C
  extension is written, bcmath.php's algorithm function by function, so the
  three bench columns measure one algorithm three ways.
- `check.php` -- the byte-for-byte differential: the same script run with the
  module loaded and with `bcmath.php` required must print identical bytes.
- `bccheck.php` -- the second oracle: every `bc_X` against the built-in `bcX`
  over a large random corpus plus the quirk edge cases, **10511 results, 0
  wrong**.
- `leakmatrix.php` -- the leak gate: every function over every argument and
  error shape for 120 rounds, leak-free under the debug allocator.
- `bench.php` -- the bench (see below).
- `mcphp.toml`, `mcphp.linux.toml`, `mcphp.windows.toml` -- the build configs.

## Correctness

- `check.php` differential: **130 lines, byte for byte** (module vs
  interpreted), and the C twin graded the same way.
- `bccheck.php` against php's own bcmath: **10511 results, 0 wrong** -- the
  module, the interpreted source, and the C twin all agree with the built-in.
- `leakmatrix.php` under the ZTS debug allocator (`tests/leaks.sh`): every
  function, every argument shape, every error path, **no block left at the end
  of the request**.

## The bench

`bench.php` times a mixed workload (loan schedules plus a batch of powers,
roots and moduli) and, with `MCPHP_EACH=1`, each function on its own
(steady-state, best of nine, interleaved). DONE is module / C-twin < 2.0, for
EVERY function -- not an average.

**DONE (2026-10-08).** Measured on this host (macOS/arm64), each row the best
of five rounds, each round `bench.php`'s own best of nine, module and C twin
interleaved:

| function | module (ms) | C twin (ms) | module/C |
|---|---|---|---|
| add    |   4.135 |   2.586 | **1.60x** |
| sub    |   4.172 |   2.616 | **1.59x** |
| mul    |   6.180 |   3.388 | **1.82x** |
| div    |  14.570 |  11.136 | **1.31x** |
| mod    |  12.093 |  10.414 | **1.16x** |
| pow    |  16.707 |   8.560 | **1.95x** |
| powmod | 165.687 | 116.843 | **1.42x** |
| sqrt   | 153.833 | 146.436 | **1.05x** |
| comp   |   2.781 |   1.708 | **1.63x** |
| floor  |   2.393 |   1.477 | **1.62x** |
| ceil   |   3.054 |   1.840 | **1.66x** |
| round  |   4.738 |   2.554 | **1.86x** |

Mixed workload (`tests/examples.sh`): interpreted 10.38 ms, compiled 0.77 ms
(13.5x faster than interpreted), C twin 0.54 ms -- module/C **1.42x**.

The closest are `pow` (1.95x) and `round` (1.86x). `pow`'s time is `_bc_umul`'s
inner loop (43% of a call): the twin's is the same algorithm, and clang
vectorises its digit loads while mc's loop is thirteen scalar instructions an
element (`examples/decimal/README.md` has the same loop measured). Hoisting the
array's buffer pointer out of it was tried and is 4% SLOWER (the new local takes
a register the outer loops held), so it was not kept.

### What got it there

All of it is in mc-php's own compiler (`src/*.mc`) and runtime
(`lib/php_rt.mc`, `lib/php_ext.mc`), general, and gated like everything else;
`mini_compiler` is untouched. `docs/plan.md` § item 4 lists each change with
what it bought. In short: the nullable `?int $scale = null` is carried as a
native value (it was a heap zval per call); a function called before its
declaration keeps its declared scalar parameters (so the define-before-use
order this file still has is no longer needed); intermediate strings shrank --
views for `substr()` locals, ropes built in place, fresh buffers written in
place, `$s[$i] = $t[$j]` as a byte write; string blocks are kept per size
class; a small pure argument and an integer literal are substituted into a
copied routine; and the register pressure of a long function fell (locals that
are never live at once share one; constant offsets fold into the load).

## Not for this port

The `BcMath\Number` class, `bcdivmod`, and the non-default `RoundingMode` enum
argument to `bcround` are outside the function set this port targets.

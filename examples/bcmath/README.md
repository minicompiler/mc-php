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

## The bench, and why it is over 2.0

`bench.php` times a mixed workload (loan schedules plus a batch of powers,
roots and moduli) and, with `MCPHP_EACH=1`, each function on its own
(steady-state, best of nine, interleaved). DONE is module / C-twin < 2.0.

Measured on this host (macOS/arm64, best of nine):

| function | module (ms) | C twin (ms) | module/C |
|---|---|---|---|
| add    |   5.97 |  1.38 | 4.34x |
| sub    |   8.54 |  1.38 | 6.18x |
| mul    |   7.11 |  1.79 | 3.97x |
| div    |  19.66 |  5.71 | 3.45x |
| mod    |  16.63 |  5.41 | 3.08x |
| comp   |   4.54 |  0.93 | 4.88x |
| pow    |  17.95 |  4.50 | 3.99x |
| powmod | 282.30 | 61.64 | 4.58x |
| sqrt   | 194.43 | 77.68 | 2.50x |
| floor  |   3.09 |  0.79 | 3.93x |
| ceil   |   3.57 |  0.96 | 3.71x |
| round  |   8.10 |  1.34 | 6.06x |

Mixed workload: interpreted 5.52 ms, compiled 1.03 ms (**5.37x faster than
interpreted**), C twin 0.28 ms -- module/C **3.64x**.

**This is over the 2.0 DONE bar, and the cause is a single, general mc-php
limitation, not this port's algorithm.** Every `bc_*` function takes the
optional, nullable scale as `?int $scale = null` -- which is bcmath's exact
signature, and the one thing the faithful port cannot drop (`bc_add('1','2')`
with the scale omitted must use the default, and `bc_add('1','2',null)` must
behave the same). mc-php lowers *any* optional or nullable parameter to a
zval (`src/decl.mc`: a parameter with a default is forced to `PT_MIXED` so
"not passed" is expressible), and the extension handler then marshals it with
a per-call heap allocation (`phx_zarg`), coerces it (`php_param_coerce`), runs
the generic type check (`phx_chk2`) and the arity check as a call
(`phx_arity2`) -- where a required scalar parameter is read in place with a
single load and a one-byte tag test.

The size of this is exact: `examples/decimal`, whose functions take a
**required** `int $scale`, is module/C **1.80x** on the identical loan
workload with the current compiler; `bcmath`, whose only difference is the
optional nullable `?int $scale = null`, is **4.9x** on the same workload. The
whole gap is the optional-parameter path. A minimal reproducer -- a function
`f(string $a, string $b, ?int $s = null)` against `f(string $a, string $b, int
$s)`, same body -- measures the nullable/optional parameter at **2.5x** the
required one, with the argument passed. The arithmetic core (the digit
helpers, shared with `examples/decimal`) is already fast; a nullable-scalar
parameter represented as a raw value rather than a heap zval would bring every
function under the bar, and is a mc-php compiler change of its own (it touches
the parameter-lowering path shared with the program road). It is `mini_compiler`
(the mc compiler) that is untouched here -- this residual is in mc-php's own
`src/`, not in mc.

## Not for this port

The `BcMath\Number` class, `bcdivmod`, and the non-default `RoundingMode` enum
argument to `bcround` are outside the function set this port targets.

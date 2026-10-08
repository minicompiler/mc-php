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

Measured on this host (macOS/arm64, best of nine, three rounds interleaved):

| function | module (ms) | C twin (ms) | module/C |
|---|---|---|---|
| add    |   5.93 |  1.42 | 4.18x |
| sub    |   7.31 |  1.44 | 5.09x |
| mul    |   7.03 |  1.79 | 3.92x |
| div    |  18.35 |  5.77 | 3.18x |
| mod    |  15.41 |  5.50 | 2.80x |
| comp   |   4.50 |  0.91 | 4.95x |
| pow    |  16.69 |  4.51 | 3.70x |
| powmod | 257.34 | 61.30 | 4.20x |
| sqrt   | 193.72 | 77.10 | 2.51x |
| floor  |   3.07 |  0.77 | 3.97x |
| ceil   |   3.53 |  0.95 | 3.71x |
| round  |   8.10 |  1.32 | 6.12x |

Mixed workload: interpreted 5.47 ms, compiled 1.00 ms (**5.47x faster than
interpreted**), C twin 0.28 ms -- module/C **3.54x**.

**This is over the 2.0 DONE bar, and the cause is optimization work, not this
port's algorithm.** The arithmetic core -- the base-10 digit helpers (`uadd`,
`usub`, `umul`, `udivmod`, the magnitude compare) -- is `examples/decimal`'s
own, and `examples/decimal` is module/C **1.80x** on the identical loan
workload with the current compiler. So the compiler reaches < 2x for this
exact shape; the digits are not the problem. `div`, the compute-heavy function
where the digit loops dominate, is the closest here (3.18x) for the same
reason.

The gap is two measured things, neither an algorithm change:

1. **bcmath.php is a first cut; decimal.php was hand-tuned.** For the identical
   loan workload, the bcmath module runs ~2.6x the decimal module (0.49 ms vs
   0.23 ms) and builds ~1.5x the strings per call (add 600 vs 400, mul 700 vs
   500, counted with `MCPHP_STATS=1`). decimal.php was rewritten function by
   function against the compiler's optimizer -- its "same-algorithm 2x batch"
   (docs/plan.md § 7), which drove its string counts and frame down to where
   the generated code is as lean as the C twin's glue. bcmath.php has not had
   that pass. This is pure source work (and the owner's first lever), safe and
   in this repository.

2. **The optional, nullable scale costs the rest.** bcmath's exact signature is
   `?int $scale = null` -- the one thing a faithful port cannot drop
   (`bc_add('1','2')` with the scale omitted must use the request default, and
   `bc_add('1','2',null)` must behave the same). mc-php lowers *any* optional or
   nullable parameter to a zval (`src/decl.mc`: a defaulted parameter is forced
   to `PT_MIXED` so "not passed" is expressible), and the extension handler
   marshals it per call (`phx_zarg` heap allocation + `php_param_coerce` +
   `phx_chk2` + `phx_arity2`) where a required scalar is read in place. Measured
   on the loan workload: the required-`int $scale` variant is ~4.1x and the
   `?int $scale = null` one is ~4.9x -- so the optional-parameter path is the
   smaller ~0.8x of the gap, and item 1 (the per-call tuning) is the larger
   part. A minimal reproducer: `f(string, string, ?int $s = null)` is ~2.5x
   `f(string, string, int $s)`, same body, argument passed. There is no source
   workaround for this half (the optional nullable scale is bcmath's contract);
   it is a mc-php change of its own -- a nullable/optional scalar carried as a
   raw value rather than a heap zval -- touching the parameter-lowering path
   shared with the program road.

Both are in mc-php's own `src/`/source, not in the port's math; `mini_compiler`
(the mc compiler) is untouched. decimal at 1.80x on the identical workload is
the proof the bar is reachable for this shape.

## Not for this port

The `BcMath\Number` class, `bcdivmod`, and the non-default `RoundingMode` enum
argument to `bcround` are outside the function set this port targets.

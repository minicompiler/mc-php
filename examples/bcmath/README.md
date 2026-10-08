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
(steady-state, best of nine, interleaved). DONE is module / C-twin < 2.0.

Measured on this host (macOS/arm64, best of nine, three rounds interleaved),
after the define-before-use source fix below:

| function | module (ms) | C twin (ms) | module/C |      |
|---|---|---|---|---|
| floor  |   1.36 |  0.77 | **1.76x** | under 2.0 |
| ceil   |   1.77 |  0.97 | **1.82x** | under 2.0 |
| mod    |  12.49 |  5.53 | 2.26x | |
| sqrt   | 173.48 | 76.37 | 2.27x | |
| add    |   3.54 |  1.38 | 2.57x | |
| sub    |   3.63 |  1.40 | 2.60x | |
| pow    |  12.03 |  4.50 | 2.67x | |
| mul    |   4.88 |  1.81 | 2.70x | |
| div    |  16.06 |  5.89 | 2.73x | |
| comp   |   2.56 |  0.93 | 2.75x | |
| powmod | 208.15 | 61.39 | 3.39x | |
| round  |   5.95 |  1.36 | 4.38x | |

Mixed workload: interpreted 5.41 ms, compiled 0.70 ms (**7.8x faster than
interpreted**), C twin 0.28 ms -- module/C **2.45x** (was 3.54x before the fix
below).

**floor and ceil are under the 2.0 bar; the other ten are not.** The whole
table fell ~1.5x from a single source change (below). What remains over 2.0 is
two things -- one a pure-source lever (add/sub/comp), one a compiler floor the
hand-tuned `examples/decimal` hits too (the rest).

### The one source fix already applied: define-before-use

mc-php is single-pass. A call to a function **declared later in the file** (PHP
hoists declarations, so this is legal and common) is lowered against a forward
*stub* whose parameters are `PT_MIXED` -- and when the real declaration is seen,
`src/decl.mc` forces its parameters to `PT_MIXED` to match the stub
(`if (fwd && !variadic) pt = PT_MIXED;`). That **poisons the function for every
caller**, not just the forward one, and -- because the poisoned helper is then
inlined into other functions -- it cascades.

In the first cut `_bc_intonly` (defined before `_bc_skip0`) called `_bc_skip0`,
so `_bc_skip0`'s declared `string $d` was forced to a zval. `_bc_skip0` is
inlined into `_bc_fmt` and `_bc_ucmp`, which are inlined into `_bc_addsub` and
every arithmetic function, so **the whole module did its digit work on zvals**:
`f__bc_addsub` was 2064 instructions with ~20 `php_zv_*` calls where the same
source in isolation is 1759 instructions with none. Reordering so every helper
is defined before its first use removed it: `bc_add` 4.14 -> 2.20 ms, the mixed
workload 3.54x -> 2.45x, floor/ceil under 2.0. Pure source, `bccheck.php` still
10511/0, `leakmatrix.php` still leak-free. (The general fix is in mc-php, not
this file: a forward-referenced function with declared scalar parameters should
keep them -- a two-pass signature collection, or re-typing the stub when the
definition is seen. Reported for the compiler; it would help every taught
module, teko included, and remove the ordering constraint on source.)

### What is left, measured

1. **The optional, nullable scale (add, sub, comp).** bcmath's exact signature
   is `?int $scale = null` -- the one thing a faithful port cannot drop. mc-php
   lowers *any* optional or nullable parameter to a zval (`src/decl.mc` forces
   `PT_MIXED` so "not passed" is expressible), and the handler marshals it per
   call (`phx_zarg` heap allocation + `php_param_coerce` + `phx_chk2` +
   `phx_arity2`) where a required scalar is read in place. Measured here, same
   source, scale required `int` instead of `?int`: **add 2.50x -> 1.80x,
   sub 2.59x -> 1.84x, comp 2.55x -> 1.54x** -- all under 2.0. A minimal
   reproducer: a trivial `f(string, string, ?int $s = null)` body is ~4.9x the
   same body with `int $s` (8.5 ms vs 1.7 ms over 200k calls). There is no
   source workaround (the nullable scale is bcmath's contract); it is a mc-php
   change -- a nullable/optional declared-scalar parameter carried as a native
   value, not a heap zval, in the parameter-lowering path shared with the
   program road. With it, add/sub/comp go under 2.0.

2. **The compiler floor (mul, div, mod, sqrt, pow, powmod, round).** These do
   not reach 2.0 even with the scale required, because every intermediate digit
   string is a heap-allocated, reference-counted `zend_string` where the C twin
   uses a stack buffer. `examples/decimal` -- the same digit core, hand-tuned,
   required-`int` scale, no forward references -- is itself **over 2.0 per
   function on the current compiler**: dec_mul 2.09x, dec_div 2.60x, dec_cmp
   2.04x, dec_round 2.21x (dec_add 1.71x, dec_sub 1.76x are under). So the
   bignum-string shape is bounded above 2.0 for these operations with the
   current back end; `examples/decimal`'s widely-cited **1.80x** is the *mixed
   workload* average, not a per-function figure. Closing this needs a general
   compiler optimization -- non-escaping intermediate strings on a stack/arena
   with no refcount (escape analysis) -- reported for mc-php, not reachable by
   tuning this file. `round` (4.35x) is additionally the most string-heavy
   function (str_pad, several str_repeat/concat) and carries a defaulted
   `int $precision = 0` (a zval like the scale).

`mini_compiler` (the mc compiler) is untouched; every change and every
limitation above is in mc-php and this file.

## Not for this port

The `BcMath\Number` class, `bcdivmod`, and the non-default `RoundingMode` enum
argument to `bcround` are outside the function set this port targets.

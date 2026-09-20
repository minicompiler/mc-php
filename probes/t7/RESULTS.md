# T7 -- php's diagnostics, and the tests that compile and print the wrong thing

Question (`docs/plan.md` § 4): T6 answered **1073 of 21051** and left two
numbers pointing at what to do next. **21.8% of the corpus asserts a php
DIAGNOSTIC line** (4657 of the 21386 tests with an expect section: `Warning:`
1882, `Deprecated:` 849, `Notice:` 196, `Fatal error:` 1990) and T6 produced
only the uncaught-throwable form of the last; and **536 of 1417 sampled
`wrong` tests compiled, ran, and printed the wrong thing** -- the largest
single reason and the least structured. T7 builds the first and takes the
second apart.

Run: `sh probes/t7/run.sh`. Host: macOS 26 / arm64, **mc 1.1.0**, PHP 8.5.10
(Homebrew, NTS), php-src at `php-8.5.10`.

`probes/t6/` is left exactly as it was and still reproduces its own number:
`probes/t7/out/base/`, measured here against a snapshot of T6's binary, is
`tests/lang` **74**, `Zend/tests` **452**, `ext/standard/tests/strings`
**180** -- T6's three numbers to the test.

## Answer: green 1073 -> 1218

| grid | green | wrong | refused | skip | php-fail | total | T6's green |
|---|---|---|---|---|---|---|---|
| `tests/lang` | **82** | 157 | 42 | 12 | 1 | 293 | 74 |
| `Zend/tests` | **539** | 3765 | 890 | 112 | 6 | 5306 | 452 |
| `ext/standard/tests/strings` | **194** | 403 | 83 | 54 | 0 | 734 | 180 |
| **the whole corpus** | **1218** | 13968 | 2917 | 2947 | 345 | 21050 | 1073 |

T6's line, same corpus and same harness:
`green 1073 / wrong 13374 / refused 3657 / skip 2947 / php-fail 344 / total 21051`.
T5's: `green 80`. T0's, before any compiler existed: `green 0`.

**1211 of the 1218 greens are in T0's "touched by none" set** -- the same
seven as T6 are outside it.

`refused` fell 3657 -> 2917 and `wrong` rose 13374 -> 13968, which is the
retirement of two named refusals showing up honestly in the third column: an
undefined variable (D4) and `@` (D1) are no longer refused, so those tests
now compile and run, and what they print is the next thing to fix.

### The two blocks this probe was set, each measured on its own population

| block | tests | T6 green | T7 green |
|---|---|---|---|
| assert a `Warning:`/`Deprecated:`/`Notice:`/`Fatal error:` line | 4657 | **5** | **71** |
| mention `__destruct` | 333 | **8** | **11** |

The first is a factor of 14 and is still 1.5% of its population, which is the
honest shape of it: a test that asserts a diagnostic almost always asserts
something else as well, and the diagnostic was only the first thing wrong.
The measurement is the point -- the block is no longer structurally out of
reach, and what is left in it is ordinary missing behaviour.

## What it is

| file | lines (code) | what |
|---|---|---|
| `php.mc` | 5807 (5192) | the compiler: one mc Tier 3 module |
| `php_rt.txt` | 5930 (5149) | the runtime, pushed into every program it compiles |
| `run.sh` | 152 | the probe |
| `diffgroup.py` | 116 | **new**: the `(compiled; output differs)` block, clustered |
| `arena.py` | 39 | **new**: how often D7's arena is the answer |
| `why.py` + `whytable.py` | 96 | the wrong-reason table, re-measured on every run |
| `lencheck.py` + `aritycheck.py` | 88 | the two invariants the sources carry |
| `grid.sh` | 29 | **new**: a grid run against a SNAPSHOT of the compiler |
| `mcphp.sh` | 56 | executor B for `probes/t0/phpt-run.py` |

`grid.sh` exists because of a mistake worth recording: the first baseline run
here measured a binary that was being REBUILT underneath it, and came back
`Zend/tests` 299 where T6 had 452. A measurement takes a copy of the compiler
now, so an edit during a 10-minute grid cannot corrupt it.

**Nothing in mc was touched**, and nothing was worked around. `php.mc` calls
**53** names from outside itself: **48** are in `tests/golden/surface.txt`,
three are `<float>`'s (`float_init`, `machine_arm64_float_init`,
`machine_x86_64_float_init`, which the freeze covers as a bundle name), and
two are new in T7 -- `write` and `exit`, which the compiler needs to print a
php COMPILE-TIME `Fatal error:` on stdout and exit 255 where php does.

## 1. The diagnostic channel

A compiled binary has to say `Warning: Undefined variable $x in /path/to.php
on line 12`, with the file php resolved and the line the statement is on.

**The position is two runtime globals the compiler stores into once per
statement** (`php_pos`), not a file and a line threaded through all 179
library rows. `ph_stmt` became a wrapper that prefixes one call; a
declaration and an empty statement lower to nothing and get none. The file is
absolutised the way php resolves it (`host_getcwd` + `path_join` +
`path_norm`, cached per distinct file), so `in %s on line %d` matches byte for
byte.

The inexactness is written down rather than hidden: **a diagnostic raised
after a user function RETURNED, inside the same statement, reports the line
that callee last set.** A statement whose warning comes before any user call
-- nearly all of them -- is exact.

The streams are php's: with `log_errors=On` (a plain `php file.php`) the
`PHP Warning:  ` form goes to stderr FIRST, then `\nWarning: ...` to stdout;
`probes/t0/phpt-run.py` sets `log_errors=0` and grades stdout alone. The
order is what `probes/t7/g/25-diagnostics.php` compares, on both streams.

### The messages

Each one is php-src's own text, checked against php 8.5.10 on this host:

* `Warning: Undefined variable $x`
* `Warning: Undefined array key "k"` and `... key 7`
* `Warning: Array to string conversion`
* `Warning: A non-numeric value encountered`
* `Warning: Trying to access array offset on <type>` (`true`/`false` spelled out)
* `Warning: Uninitialized string offset N`
* `Warning: Undefined property: C::$p`
* `Warning: Attempt to read property "p" on <type>`
* `Warning: foreach() argument must be of type array\|object, <type> given`
* `Warning: strtok(): Both arguments must be provided when starting tokenization`
* `Warning: addcslashes(): Invalid '..'-range, '..'-range needs to be incrementing`
* `Deprecated: Implicit conversion from float 3.5 to int loses precision`
* `Deprecated: Implicit conversion from float-string "3.5" to int loses precision`
* `Deprecated: Using null as an array offset is deprecated, use an empty string instead`
* `Deprecated: Increment on non-numeric string is deprecated, use str_increment() instead`
* `Deprecated: Decrement on non-numeric string has no effect and is deprecated`
* the four duplicate-modifier COMPILE-TIME fatals (below)

and `error_reporting()` and `trigger_error()` are real -- the first answers
the old mask and sets the new one, the second raises at the level it is given
and exits 255 for `E_USER_ERROR`.

### What the warning retired

**An undefined variable is the one place T6 said D4 had no answer.** php
warns and yields null; null is a value of `mixed`, which D4 (c) already lowers
to a zval -- so the read is expressible without the variable ever gaining a
type, and a later `$x = 5` still declares `$x` an int. The refusal is gone,
and with it the `34 of 200` T5 measured. `@` went with it: the runtime has a
suppression depth now, so `@EXPR` is a pending statement on each side of a
temporary and the D1 refusal is retired.

### What must NOT warn

`isset`, `empty` and `??` read without warning in php, and the thing that
tells `$a['k'] ?? 'd'` apart from any other element read is the token after
the closing bracket -- which `ph_index` is standing on. The same question is
asked after a bare `$x` and after `$o->p`. Getting this wrong is not a missing
warning but a SPURIOUS one, and it showed up as the single biggest pair in the
diff table (`php 'int(3)'` against `mc ''`, a leading blank line) until all
three reads asked it.

## 2. `(compiled; output differs)`, taken apart

`probes/t7/diffgroup.py` runs php and the mc-php binary on the same
`--FILE--`, finds the FIRST differing line and groups by its shape. On the
1487 `wrong` tests of the three directories, with block 1 in:

```
  945  (does not compile)
  254  var_dump of a value
  115  a php diagnostic
   83  a blank line
   51  other text
   13  a float
    9  an integer
    9  (agrees on this harness)
    5  print_r of a container
    2  (timed out)
    1  print_r of an element
```

and, per group, the five commonest (php line, mc line) pairs. That table is
what chose every block, and here is what each group turned out to be.

**`php 'int(3)'` against `mc ''` -- the biggest single pair -- was a SPURIOUS
warning.** A leading blank line is what `\nWarning: ...` looks like when php
raised nothing, and it came from `??` reading through the warning getter on a
bare `$x` and on `$o->p`. Fixed by asking the same question all three reads
now ask.

**`var_dump of a value`, the largest group.** Taken apart: a zval's unary
minus converted to INT first and threw a fraction away (`-"1.2"` was
`int(-1)`); `& | ^` between two STRINGS are bytewise in php and were numeric
here; `<< >>` on a non-numeric string is a TypeError and was `int(0)`;
`var_dump`/`print_r` did not mark a non-public property and `var_export` of
an object printed `NULL`; `var_dump` of a statically typed object was not
implemented at all.

**`a float`.** `1.7E-300` printed `3.720368547758E-299` and every |x| below
about 1e-293 printed the digits of 2^63 -- two independent bugs, one in each
direction: `ph_pow10` built 10^-301 by dividing 1e-22 by ten 279 times (into
the subnormals and never back) and `ph_digits` scaled by a single 10^316,
which is infinity. `1e-290` printed `0.9999999999999999E-290` because
`ph_e10` leans on an inexact power of ten past 1e22. `-0.0` printed `0`
because unary minus on a float was `0.0 - x`.

**`other text`, the `NULL` rows.** `var_dump("65" / "0")` printed NULL and
THEN caught the DivisionByZeroError: T6's own rule -- the unwinding check
goes between computing a value and using it -- was implemented for `echo` and
not for a CALL's arguments.

**`(does not compile)`, 945 of 1487, the biggest block of all.** `why.py`
names it: 288 of the final 1460 are a php function or constant that is not
there, and the rest is the grammar's remaining corners. Two of those corners
were worked here because `why.py` put numbers on them: an assignment in
EXPRESSION position (`if (!($fp = fopen(...)))`, 22 under
ext/standard/tests/strings alone) and the arities `explode`/`implode`/
`substr_count` were short of (30).

### The table, re-measured after all of it

```
  1460 `wrong` tests, by what mc-php said about each
    582  (compiled; output differs)
    288  a php function or constant mc-php does not have
     37  mc-php
     35  expected ; after a php expression
     33  expected { in php
     31  PHP Fatal error
     30  expected ; after a php property
     29  expected ) in a php call
     28  a php variable used as a statement
     25  a by-reference parameter in a typed function
     25  an anonymous class
     24  the wrong number of arguments for
     22  expected ; after a php assignment
     22  a by-reference use in a closure
     21  a php parameter
     20  an assignment by reference
     18  the storage keyword
     16  a function returning by reference
     16  unknown name
     13  argument unpacking ...$args
     13  expected = after a php array index
     10  a php file that does not open with <?php (leading inline html)

  the most wanted names mc-php does not have:
  fopen(40), pack(20), crypt(14), spl_autoload_register(13),
  get_html_translation_table(12), unpack(10), file_put_contents(10),
  sscanf(8), list(8), debug_print_backtrace(7), highlight_string(7),
  func_get_arg(6), parse_str(6), php_strip_whitespace(5), serialize(5),
  mb_internal_encoding(5), set_exception_handler(4), metaphone(4),
  parse_ini_string(4), quoted_printable_encode(4), get_called_class(4),
  __HALT_COMPILER(4), highlight_file(3), convert_uuencode(3),
  str_getcsv(3), show_source(3), str_decrement(3), array_multisort(3),
  array_splice(3) ...
```

and the 582 that compile, by what differs:

```
      272  var_dump of a value
      135  a php diagnostic
       83  a blank line
       57  other text
       14  a float
       10  an integer
        5  print_r of a container
        3  (timed out)
        1  print_r of an element
        1  var_export of an element
        1  (agrees on this harness)
```

Two things to read out of the second table. `a php diagnostic` is 135 and its
commonest rows are now php diagnostics mc-php does NOT have for a feature it
does not have at all (`Allowed memory size exhausted`, readonly properties,
attribute targets, `Deprecated`/`NoDiscard` as classes) -- the channel is
built and what is left is the features behind the messages. And the sixteen
`php '' / mc 'Done'` rows are php COMPILE-TIME fatals for constructs the
parser accepts, of which the duplicate-modifier family is now done and the
rest (`Cannot redeclare`, the parse errors) is the same road.

## 3. What T6 left open

### `__destruct`: 8 -> 11 of 333, and the decision behind it

D7 has no refcount and no free, so php's "when the last reference goes away"
does not exist here. What does exist is the END OF THE PROGRAM, and php runs
every surviving destructor there too -- in REVERSE creation order, measured
on 8.5.10: three globals created 1, 2, 6 come out d6, d2, d1. Every object
whose class has a `__destruct` joins a list newest-first, so walking it IS
that order; `php_shutdown` runs it before the final flush and on every
`exit()`/`die()`, after the `register_shutdown_function` callbacks, which is
php's own order too.

**The first draft of that was a NET LOSS and the corpus said so**: 8 -> 6,
five tests lost and three won. The five say one thing, and php-src's own
tests are what say it -- php does not destruct an object whose CONSTRUCTOR
threw (`Zend/tests/try/catch_002` expects `Caught` and nothing else), and it
never creates one at all when an ARGUMENT to `new` threw first
(`Zend/tests/exceptions/bug47771`). So an object is armed when it is fully
CREATED -- after its constructor returns normally, or when it has none, or
when it is a `clone` -- and not when it is allocated. 8 -> **11**.

**What is NOT implemented, and is a documented difference with its number**:
the destructor of an object that dies EARLY -- a function local at scope end,
an `unset`, a reassignment, a temporary. php runs those at the moment the
last reference goes; this runs them at the end of the program, in the right
order among themselves. 322 of the 333 are still not green, and the reason is
mostly not the destructor at all: most of them use features that are missing
for other reasons.

### The array copy: measured, and copy-on-write NOT built

T6 measured the eager array copy exhausting the 48 MiB arena between 500 and
1000 copies of a 2000-element array, and left copy-on-write open -- which D7
allows without a refcount, because "is the writer the only one that can
observe the difference" is a compile-time escape question.

`probes/t7/arena.py` asks whether it bites, by compiling and RUNNING the
whole `wrong` sample and counting the ones whose stderr says the arena ran
out. **9 of 1460 (0.62%), and not one of them is an array copy.** They are:

  * four tests that build a very large STRING (`chunk_split_variation3`,
    `explode_bug`, `sprintf_star`, `concat/bug44069`),
  * four that allocate without bound ON PURPOSE and expect php's own
    `Fatal error: Allowed memory size of %d bytes exhausted`
    (`wordwrap_memory_limit`, `Zend/tests/bug40770`, `bug70258`, `bug76846`),
  * one (`htmlentities-utf-3`) that is wrong for another reason as well.

So the block copy-on-write would remove does not exist in this corpus, and
the pressure that does exist is string BUILDING -- the shape D7 predicted --
plus a missing `memory_limit`, which is a feature and not a memory strategy.
**Copy-on-write is not built**, and the number is why. A 4x arena was
measured too, as the cheap alternative: 192 MiB turns one of those five
strings tests green and leaves the other four, so it buys one test for a 4x
virtual reservation and a weaker failure signal, and it is not taken either.

## 4. The mc gaps

### Nothing new

T7 is the fourth probe to grow `probes/t*/php.mc` and it found **no new mc
gap**. The one T5 reported is unchanged and T7 hits it exactly as often:
**38 of the 21219 `.phpt` with a `--FILE--` section** open with inline HTML,
which the core lexes as stray identifiers before `syntax("<?php")` can fire,
and `ph_on_source` refuses such a file by name rather than mis-lexing it. Ten
of those 38 are in the 1460-test sample, which is the same rate.

The smallest additive fix is the one T5 named: let `on_source` return a byte
offset at which lexing should begin (0 = the whole buffer), or give
`p_push_source` an offset argument.

### Two things T7 used that were already there

Worth naming, because they are what a Tier 3 module reaches for once it has
to produce a HOST-SHAPED diagnostic:

* **`host_getcwd()`**, to absolutise a file the way php resolves it, so that
  `in %s on line %d` is byte for byte what php prints.
* **`write` and `exit`, declared `extern` by the module itself.** A php
  COMPILE-TIME `Fatal error:` is php's output, not a compiler failure: it
  goes to stdout with exit 255 from inside the compiler, where php produces
  it. Nothing in mc had to change for that -- a module may declare a libc
  name -- but it is the first time `probes/t*/php.mc` writes to a file
  descriptor at all.

`php.mc` calls **53** names from outside itself: **48** in
`tests/golden/surface.txt`, three `<float>`'s (`float_init`,
`machine_arm64_float_init`, `machine_x86_64_float_init`, which the freeze
covers as a bundle name) and those two.

### Notes, not gaps

* **A loop CONDITION may need statements of its own.** `while (($n = f()) <
  4)` and any condition with a call that can throw: they have to run on every
  iteration, after the step and before the test. mc's `loop { }` takes that
  shape naturally (`loop { <step>; <cond stmts>; if (!c) break; <body> }`) --
  the mistake worth recording is that T6 emitted them ONCE, before the loop,
  and refused a `while` that had any.
* **A measurement takes a SNAPSHOT of the compiler.** The first baseline run
  here measured a binary that was being rebuilt underneath it and came back
  `Zend/tests` 299 where T6 had 452. `probes/t7/grid.sh` copies the binary
  first; `probes/t7/out/base/` is T6's three numbers reproduced to the test.

## Fixtures

**30 of 30** fixtures under `g/` produce byte for byte what `php` produces
(stdout, stderr AND exit code -- the stream order matters now that
diagnostics exist, and `25-diagnostics.php` is what checks it) and **5 of 5**
under `r/` are refused by name with exit 3. Six are new:

| fixture | what it pins |
|---|---|
| `25-diagnostics.php` | seventeen messages, both streams, in php's order; `@`; `??` reading nothing |
| `26-floats-dumps.php` | the float tail, and the visibility marks var_dump/print_r/var_export owe a class |
| `27-destruct.php` | the end-of-program destructor, in php's reverse creation order |
| `28-compile-fatal.php` | a php COMPILE-TIME `Fatal error:` on stdout, exit 255 |
| `29-library.php` | class_alias, register_shutdown_function, strtok, strnatcmp, addcslashes |
| `30-assign-expr.php` | assignment as an expression, including in a `while` and a `for` condition |

The two invariants the sources carry are checked on every run: `lencheck` 97
literal lengths, 0 wrong; `aritycheck` 179 library rows, 0 wrong -- and it
earned its keep again, catching a duplicate `php_f_substr_count` the arity
work introduced.

## D8

`docs/plan.md` D8 asks that every `.php` written in this repository carry a
PHPUnit test that runs in both worlds and a `bench/` row. Everything under
`g/` and `r/` is a FIXTURE -- the probe's own input, compared against `php`
on every run, which is the same gate a test would be -- and nothing here is a
part of the runtime or the standard library written in PHP. T6's
`bench/unwind.php` is unchanged and still compared in both worlds by
`bench/bench.sh`. `mc-php test`, D8 (a)'s compile-time discovery of `test*`
methods, still does not exist: it belongs to the compiler and not to a probe.

## What T8 should do

In the order the numbers argue for, and they are all in the two tables above.

1. **`(does not compile)` is now the block, 878 of 1460** (582 compile).
   288 of them name a php function or constant that is not there --
   `fopen` and the file family (40), `pack`/`unpack` (30), `crypt` (14),
   `spl_autoload_register` (13), `get_html_translation_table` (12),
   `file_put_contents` (10) lead it -- and the rest is the grammar's
   remaining corners, each with its own count: an anonymous class (25),
   a by-reference parameter and its three relatives (25 + 22 + 20 + 16),
   `list()`/`[$a, $b] =` destructuring (8 + 13), `...$args` at a call
   site (13), the storage keywords (18).
2. **`var_dump of a value`, 272 of the 582 that compile.** No longer one
   theme: the pairs are ordinary missing behaviour, an object comparison,
   `foreach` over an object, and the last digit of a 17-significant-digit
   float, which is the one thing here that needs an exact decimal-to-binary
   conversion and not a bug fix.
3. **Integer overflow on a TYPED int.** `PHP_INT_MAX + 1` is `float` in php
   and wraps here; the zval road already promotes correctly, so this is only
   the D4-typed path, and the honest fix is that the static type of `+` over
   two ints is `int|float`, which D4 (c) sends to a zval -- and which would
   make every loop counter a zval. It is left as a named divergence with its
   number (13 of the 582 first differ on it) rather than paid for that way.
4. **php's `memory_limit`.** Four of the nine arena exhaustions are tests
   that EXPECT php to run out; a limit and its `Fatal error:` would make them
   right, and it is the diagnostic channel plus a counter.
5. **The rest of the compile-time fatals.** The road exists (stdout, exit
   255); `Cannot redeclare`, the parse errors and the interface conflicts are
   each one check at their own site.

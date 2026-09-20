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

## Answer

TBD-TABLE

## What it is

| file | lines (code) | what |
|---|---|---|
| `php.mc` | TBD | the compiler: one mc Tier 3 module |
| `php_rt.txt` | TBD | the runtime, pushed into every program it compiles |
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
what chose every block below; the groups it named and what came of each:

TBD-GROUPS

## 3. What T6 left open

TBD-OPEN

## 4. The mc gaps

TBD-GAPS

## Fixtures

TBD-FIXTURES

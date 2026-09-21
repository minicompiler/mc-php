# T9 -- func_get_args, the two blocks T8 inverted, and the generator decision

Question (`docs/plan.md` § 4): T8 answered **1450 of 21044** and INVERTED its
own failure table -- **758 of 1396** sampled `wrong` tests compiled and printed
the wrong thing against **638** that did not compile. T9 works both, in that
order, re-measuring between blocks, and takes D6's correction
(`func_get_args`) first.

Run: `sh probes/t9/run.sh`. Host: macOS 26 / arm64, **mc 1.1.0**, PHP 8.5.10
(Homebrew, NTS), php-src at `php-8.5.10`.

`probes/t8/` is left exactly as it was. `probes/t9/out/base/`, measured here
against a snapshot of T8's compiler plus block 1, is `tests/lang` **93**,
`Zend/tests` **635**, `ext/standard/tests/strings` **223** -- T8's three
numbers to the test.

Every measurement here was taken against a SNAPSHOT of the compiler
(`probes/t9/grid.sh`, `probes/t9/fixtures.sh`), which is T7's own note: the
first baseline there measured a binary that was being rebuilt underneath it.

## Answer: green 1450 -> 1637

| grid | green | wrong | refused | skip | php-fail | total | T8's green |
|---|---|---|---|---|---|---|---|
| `tests/lang` | **102** | 142 | 37 | 12 | 1 | 293 | 93 |
| `Zend/tests` | **709** | 3761 | 724 | 112 | 6 | 5306 | 635 |
| `ext/standard/tests/strings` | **262** | 311 | 107 | 54 | 0 | 734 | 223 |
| **the whole corpus** | **1637** | 14140 | 2309 | 2947 | 362 | 21033 | 1450 |

`Zend/tests`'s **refused** column fell 953 -> 724, and that is one block:
the php type words in a parameter or a return were refusals and are not any
more (§ 9 below). `wrong` rose with it, because a test that now COMPILES gets
far enough to print something that can disagree.

**1626 of the 1637 greens are in T0's "touched by none" set** -- the 84.2% of
the corpus none of § 3's decisions touches -- against T8's 1441 of 1450. The
eleven outside it are the first greens a decision has an opinion about.

T8's line on the same corpus and harness:
`green 1450 / wrong 13623 / refused 3024 / skip 2947 / php-fail 351 / total 21044`.
T7's: `green 1218`. T6's: `green 1073`. T5's: `green 80`. T0's, before any
compiler existed: `green 0`.

## What was measured before anything was built

`probes/t9/out/base/all/wrong.txt` is 13623 tests. Every ninth of them --
**1514**, a uniform sample across the whole corpus and not an alphabetical
slice -- went through `why.py`, and the 703 that live in the three GRADED
directories were separated from the rest, because `ext/dom` (734 wrong),
`ext/spl` (713), `ext/date` (570), `ext/reflection` (467), `ext/mbstring`
(392) and `ext/intl` (392) need whole extensions and are not what T9 is
about.

Of those 703: **379 did not compile, 324 compiled and differed.**

The corpus-wide `\` group is the clearest thing the split shows. It is **62
of the 71** `expected ; after a php assignment` failures and 70 across three
messages -- and nearly all of it is `Dom\HTMLDocument`, `Random\Engine` and
their kind: namespaced class names from extensions this compiler does not
have. Implementing namespaces would have moved them from "does not compile"
to "class not found" and bought nothing, so namespaces were flattened only
where a program actually needs them (§ 9).

## The tables, re-measured on the final compiler

The same uniform sample shape, re-drawn from the new `wrong.txt`: every ninth
of 14140, which is **1572**, of which **718** are in the three graded
directories -- **391 that do not compile and 327 that compile and differ**.
The block that does not compile, by the compiler's own message:

```
    33  expected ; after a php expression
    28  mc-php: <a named limit>
    25  expected ; after a php property        (property hooks, and
    20  expected ) in a php call                asymmetric visibility)
    10  expected ; after a php assignment
     9  a reference &$x                        ([&$v] in an array literal)
     8  a php function mc-php does not have: opendir
     6  ... spl_autoload_register
     5  expected ) after while
     5  PHP Fatal error
     4  ... next        4  ... escapeshellarg
```

and the 327 that compile, by the shape of the first differing line:

```
   107  var_dump of a value
    95  a php diagnostic
    70  a blank line
    42  other text
     5  an integer        3  a float        3  (timed out)
     2  print_r of a container
```

**The head is flat now.** T8 could point at one group worth 28 tests
(`php '' / mc 'Done'`) and one worth 19 (`#[\Override]`); the largest single
first-difference PAIR left in this sample is worth 6. What is left in the
graded directories is either a bounded feature with a name -- property hooks
(25), asymmetric visibility, generators (§ below) -- or a long tail of one
function each, which is the shape § 10 of this file worked and is what T10
inherits.

## The blocks, in the order they were worked

Each is one commit, each was measured before the next was chosen.

### 1. `func_get_args` (D6's correction)

D6 was corrected by T8's measurement and the correction is landed in the
plan; this builds it. The mechanism is T8's own -- the prologue counter that
counts the arguments that were PASSED, plus the callee's own parameters --
with `php_args_all` collecting them into an array instead of choosing one.
It needs no run-time type table, which is why listing it under D6 was a
classification mistake and not a choice.

It moved **none** of the three directory numbers on its own: 46 tests in the
corpus name it and every one of them needs something else as well.

### 2. The three by-reference targets (38 of the first 644 sampled)

`$a = &$b`, `$a = &$o->p` and `$a = &$a[k]` were T8's. What was missing was
the other three shapes, which the sample put at 23 + 9 + 6:

* `$a = &f()`. A `mixed` value IS a zval cell here, so binding the name to it
  is the alias php gives when the callee returns by reference. When it does
  not, php keeps the value and says so -- `Notice: Only variables should be
  assigned by reference` -- and a new column on the function table
  (`ph_frr`) is what tells the two apart.
* `$a[k] = &$v` and `$o->p = &$v`. The variable is rebound to the
  container's own cell after the cell receives its value, which is the alias
  php gives and the same approximation `$r = &$a[k]` has made since T8: an
  array that is later COPIED (a php array is a value, D7 has no refcount)
  separates them.

`probes/t9/g/48-byref-targets.php` is php's output byte for byte for all
four shapes.

### 3. `#[\Override]` is checked, not ignored (0 -> 28 of 67)

The biggest single pair in the sample's `diffgroup` was `php '' / mc 'Done'`,
28 of 69 blank lines, and **19 of those 28 are the `#[\Override]` fatal**.
D6 says attributes are inert because only reflection read them; this one is
the exception and it does not contradict D6 -- php checks it while COMPILING
the class, the compiler names the member, and nothing at run time enumerates
anything a program can see.

The compiler marks the member that follows `#[...Override...]` (the scan
that already skips the attribute reads the word), and emits one
`php_ce_ovr(ce, "C::m()", name, kind, file, line)` per marked member into a
list that runs after every class entry is FILLED -- a class may extend one
declared later in the file.

Three rules measured against php 8.5.10 rather than assumed:

* a PROPERTY's fatal carries the CLASS's line and a method's its own;
* a PRIVATE parent member is not a match (`override/010`);
* an abstract or interface method IS one, which is why `php_ce_absm` records
  the name of a member that has no body.

**28 of the 67 Override tests agree with php**, from 0. The 39 left are
property hooks (a parse feature), a trait's `#[\Override]` (php reports it
against the USING class) and delayed target validation.

### 4. The trigonometric family, from libm (19 rows)

`sin`, `cos`, `tan`, the inverses, the hyperbolics, `atan2`, `hypot`,
`deg2rad`, `rad2deg`, `expm1`, `log1p` and `fdiv` were all missing. php
prints 14 significant digits and a hand-rolled series does not survive that
comparison, so these are libm's, which libSystem and every libc mc writes
for carry. `log2` is NOT a php function and was dropped after the
measurement said so.

### 5. Argument unpacking `f(...$args)`, and `max`/`min` over N values

The callee's arity is fixed at compile time and the array's length is not, so
a spread becomes one slot per parameter the callee could take and
`php_unpack_at` answers "the k-th element, or NOT PASSED" -- 0, which is what
every zval parameter already reads that way, so a default value and
`ArgumentCountError` both keep working. A variadic callee's rest array
collects only the slots that were passed.

`max`/`min` came with it: they took exactly two arguments and php takes one
array or two-or-more values, compared with php's OWN comparison
(`max("10", "9a")` is `"9a"`, not `"10"`). The two-number shape stays native.

### 6. Late static binding

`static` in an expression was read as the storage keyword and only
`static function` got past it. The module has no token lookahead, so
`ph_dcolon_next` reads the cursor -- the road `ph_number` already takes for a
literal's tail.

The binding itself is one runtime global saved and restored around every call
that can change it: an instance call binds the object's class, a static call
binds the named one unless it FORWARDS (`parent::` from inside an instance
method carries `$this`, which php keeps the caller's binding for).
`new static()` needed a `php_new_ce_at` that takes the class ENTRY rather
than a literal name, and `get_called_class()` is the same binding as a name.

### 7. `readonly` properties

The keyword was parsed and thrown away; **94 tests in the graded directories
name one**, 45 in the corpus expect `Cannot modify readonly property`. The
DECLARING class entry is recorded against the name (php names the declarer
even when the object is a subclass), and a write is refused from outside that
scope, or inside it once the property has been written.

D7 has no per-object initialised bitmap, so "has been written" is the VALUE:
a readonly property still null has not been. A readonly property deliberately
initialised to null and written again is the one case this lets through, and
it is written down. Out of scope and measured as such: `Typed property C::$y
must not be accessed before initialization` needs an UNINITIALISED state this
runtime does not have.

### 8. `ext/json`, written in mc

D2(a): `ext/json` cannot even be built shared by `phpize`, which is the same
statement from the other side -- it IS php and belongs here. 120 of the wrong
population name one of the four functions.

The text format is php's: `/` escaped, non-ASCII as `\uXXXX` with a surrogate
pair past the BMP, a list as `[..]` and any other array as `{..}`, and
`Malformed UTF-8` answered as `false` with php's own message. The reader is a
cursor over json's grammar, assoc or `stdClass`, and a trailing byte is a
syntax error.

### 9. The php type words are all accepted -- D4 (c) applied to D9's surface

**This is the biggest single block of T9 and it removed a refusal rather than
adding a feature.** T5's table refused `array`, `mixed`, `iterable`,
`callable`, `object`, `never`, `self`, `static`, `null`, `?T`, `T|U` and
`A&B` in a parameter or a return, and a class name with them, because T5 had
no zval. **T6 built one and the table was never re-measured**: since then a
union IS a zval and `mixed` IS one, which is exactly what D4 (c) and D9 say
the lowering is.

Every one of them now answers `PT_MIXED` (`array` answers `PT_ARR`), so
`function f(array $a): int`, `?int`, `int|string`, `Foo $b`, `callable`,
`iterable` and a root-namespaced class name all compile. Three details
measured rather than assumed: `A&B` is an intersection but `A&$x` is a
by-reference parameter, told apart by the cursor; a DNF type `(A&B)|C` is
consumed whole; and a leading `\` on a class name is a root-namespaced name.

Namespaces are FLATTENED with it -- `extends PHPUnit\Framework\TestCase`
resolves to the class `TestCase`, because D1 makes one program with one class
table. The cost is on record: two classes with the same base name in
different namespaces collide.

`probes/t9/r/d9-nullable.php` was a refusal fixture for `?int` and is not one
any more. It moved to `g/`; two live D6 refusals took its place.

### 10. Five string edges, and `sscanf`

`ext/standard/tests/strings` was the one graded directory that had not moved
since T8, and 176 of its 245 compile-and-differ tests differ on a `var_dump`.
Grouping them by the FUNCTION under test gave the list, and five are one rule
each, each measured against php 8.5.10:

* `strrpos`/`strripos` ignored the offset entirely -- a non-negative one is
  where the search starts, a negative one says the match must START at or
  before `strlen + offset` (14 tests);
* `strspn`/`strcspn` ignored `(offset, length)` (8);
* `str_split("")` is the EMPTY array since php 8.2, not `[""]` (6);
* `wordwrap` with `cut=true` cuts at EXACTLY the width, never one past it and
  never after the last byte (3);
* `trim`'s charlist reads `x..y` as a RANGE, so `trim("a..z", "a..z")` is
  `".."` and not `""` (the trim family, 9).

`sscanf` was the biggest missing name there (15) and `setlocale`'s arity the
third (7). `sscanf` is php's C-like scanner -- `%d %i %u %x %X %o %b %e %f %g
%c %s %[set] %%` with a width, whitespace in the format matching any run of
it, a literal that does not match stopping the scan, and a directive that
finds nothing yielding null. `setlocale` answers `"C"` -- the only locale a
byte-oriented runtime (D10) has.

`ext/standard/tests/strings` went **223 -> 262**.

### 11. Four more names

`getcwd`, `chdir`, `chmod`, `putenv`, and `set_error_handler` made real.
`set_error_handler` was a no-op STUB, which is why a test that installs one
to OBSERVE a diagnostic printed nothing where php printed the handler's line;
the handler is now called from `php_raise` with php's four arguments and a
return that is not `false` suppresses php's own output.
`set_exception_handler` takes an uncaught throwable, and the exit code is
what php 8.5.10 gives -- **0, measured**, not the 255 the documentation
suggests.

## The generator decision, with its number

`docs/plan.md` has no generators: `yield`, `yield from` and `Generator` are
not in `probes/t9/php.mc` at all, and `yield from` shows up in the parse
table as `expected ; after a php expression: from`.

**The population, measured:** **252 of the 13623 `wrong` tests use `yield`**
(1.8% of the wrong population; 260 of the 5312 under `Zend/tests`, 4.9% of
that directory). Of those 252, **145 use the manual Generator API**
(`->send`, `->current`, `->next`, `->valid`, `->getReturn`, `->rewind`,
`->throw`, `->key`) and **107 do not**.

**The shape, if it is built: a state machine the compiler builds out of the
function body.** mc has no `goto` and no computed goto, and D7 forbids a VM
and a second stack, so a generator function's body has to be linearised into
a flat dispatch loop (`loop { if (state == 0) {...} if (state == 1) {...} }`)
with the locals moved into a heap frame and every loop and `try` turned into
explicit state transitions. `php.mc` parses statements DIRECTLY into mc AST
nodes and has no IR to run a CFG pass over, so that pass has to be built
first: it is the largest single piece of work in this probe, on the order of
600 to 1000 lines plus the `Generator` class.

**The cheap shape was weighed and refused.** A generator whose object never
escapes a `foreach` can be compiled by INVERTING it -- the function takes a
callback and each `yield` calls it -- which is correct for laziness,
interleaving and ordering, costs perhaps 150 lines, and serves **at most 107
of the 252**. It cannot serve the other 145, and a compiler that accepts
`function g() { yield 1; }` and then refuses `$g = g(); $g->send(2);` is a
compiler whose generators are a trap. A partial generator is a WRONG answer,
not a missing one.

**The decision: not built in T9, and named for T10 with the shape above.**
1.8% of the wrong population for the largest single piece of work in the
probe does not justify it ahead of what T9 did instead -- `#[\Override]` was
120 lines for 28 tests, the type words were 60 lines for the 229-test drop in
`Zend/tests`'s refused column, the string edges were 60 lines for 39 tests in
one directory. The number is recorded so T10 can weigh it against its own
list rather than re-measure it.

## D8: the first `.php` in this repository that is not a fixture

Nothing here had ever written one, so D8's two obligations had never been
met. `probes/t9/bench/workload.php` is ordinary PHP -- a JSON round trip
(`ext/json`, written in mc by this probe), a template renderer (`strpos`,
`substr`, string building, array lookup) and a sort-heavy pass (`usort` with
a closure) -- and it runs under `php` unchanged.

**(a) Tests, both worlds.** `WorkloadTest.php` is a PHPUnit `TestCase` with
six tests. `shim.php` declares `PHPUnit\Framework\TestCase` where the real
one is absent -- and it IS absent on this machine, which is recorded rather
than worked around; beside a real phpunit the declaration needs one
`if (!class_exists(...))` and nothing else. `run.php` is the mc-php half and
it NAMES its test methods, because D6 forbids discovering them at run time
and there is no `mc-php test` subcommand yet. Both worlds: **6 ok / 0
failed**.

**(b) Bench.** `probes/t9/bench/bench9.sh`, interleaved, medians of 7, with
php's own start-up timed beside them:

```
== main.php ==      both answer 13608,  the binary is 313730 bytes
  php                median 0.0393 s
  mc-php             median 0.0067 s
  php -r (start-up)  median 0.0385 s
  php / mc-php = 5.85x      php WORK / mc-php = 0.12x

== heavy.php ==     both answer 99450
  php                median 0.0395 s
  mc-php             median 0.0273 s
  php -r (start-up)  median 0.0383 s
  php / mc-php = 1.45x      php WORK / mc-php = 0.04x
```

**The two ratios measure different things and both are reported.** mc-php
wins the whole program, because php pays about 38 ms of start-up and the
binary pays none. mc-php LOSES the work: php's own work in `heavy.php` is
1.5 ms of its 39.5 (confirmed by running the same program with twenty times
the repetitions -- 70 ms, so ~32 ms for 120 reps) and mc-php takes 27 ms for
it, which makes the generated code **8x to 23x slower than php's VM on this
workload**. D7 names the cause and T9 does not dispute it: every value is
arena-allocated and never freed, an array copies eagerly, and a string is
immutable so `$out .= ...` reallocates and copies.

The JSON phase is also what the 48 MiB arena cannot hold: `wl_json_roundtrip`
fits at 60 records x 3 repetitions and exhausts the arena at 80. That is the
string-BUILDING pressure D7 predicted, measured on a real program instead of
on a `.phpt`.

## D7, re-measured

`probes/t9/arena.py` over the sampled `wrong` tests: **2 of 1572** exhaust
the arena, against T8's 11 of 1396 -- and the two are
`range_bug70239_2` and `explode_bug`, both of which build a very large
string on purpose, which is the shape D7 predicted and T7 and T8 both
measured. Nothing new, and copy-on-write is still not built.

What DID meet the arena is the D8 bench above, on a program nobody wrote as
an arena test: the JSON round trip over 80 records exhausts 48 MiB where 60
fits. That is the first time the arena has bounded something this repository
wanted to do rather than something the corpus does on purpose.

## The two sub-populations

| population | T7 | T8 | T9 |
|---|---|---|---|
| assert a `Warning:`/`Deprecated:`/`Notice:`/`Fatal error:` line (4647) | 71 | 83 | **93** |
| mention `__destruct` (333) | 11 | 14 | **14** |

Neither was a target. The diagnostics moved because `set_error_handler` is
real (block 11) and because tests around them now compile; `__destruct` did
not move at all, which is D7 working exactly as T7 described -- the only
point php also has is the end of the program.

## Invariants

* `probes/t9/g/` -- **60 of 60** fixtures byte for byte php's, on BOTH
  streams and the exit code.
* `probes/t9/r/` -- **6 of 6** refusals named, exit 3. One of T8's five
  (`d9-nullable.php`) stopped being a refusal in block 9 and moved to `g/`;
  two live D6 refusals replaced it.
* `lencheck` **468 literal lengths, 0 wrong**; `aritycheck` **272 library
  rows, 0 wrong**.
* `probes/t8/` untouched, and `probes/t9/out/base/` reproduces its three
  numbers to the test.

## Cost

`probes/t9/php.mc` 6816 -> 7177 lines, `probes/t9/php_rt.txt` 7619 -> 8780.
The library table went 242 rows -> 272. `php.mc` calls **58 names from
outside itself**, the same set T8 reported plus `type_new` (which T8 called
too and did not list): 48 frozen, four core intrinsics
(`ld8`/`ld64`/`st8`/`st64`), three `<float>`'s, and three libc
(`write`, `exit`, `realpath`).

## mc gaps

**No new one.** The one T5 reported is unchanged and T9 hits it exactly as
often: **38 of the 21219 `.phpt` with a `--FILE--` section** open with inline
HTML and are refused by name, because nothing can own the bytes before the
FIRST token.

Two things T9 needed from mc that were already there:

* **`p_cp()` past the CURRENT token.** `ph_dcolon_next` (block 6) and the
  intersection-vs-by-reference test (block 9) both decide by reading the
  cursor, which sits just past the token the core last lexed. That is the
  road `ph_number` has taken since T5 for a literal's tail, and it is what a
  module reaches for when it has no token lookahead and needs one.
* **`type_new` with `TK_INT`**, which is how the three php handle types
  (`php_str`, `php_arr`, `php_zval`) exist at all.

One thing worth writing down for the next probe, because it cost a
segmentation fault: **a hash bucket IS a zval**, so its type is
`php_zv_type(b)` and not `php_zv_type(ld64(b))` -- `ld64(b)` is the VALUE,
which for a long is a number and for anything else is a pointer into the
middle of nothing.

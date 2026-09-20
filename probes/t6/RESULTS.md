# T6 -- how far does the wrong-reason table move?

Question (`docs/plan.md` § 4): T5 asked "does the runtime agree with php" and
answered **80 of 21033**. It also left a table of WHY the other 15367 were
wrong, measured over 1694 of them. T6 works that table in descending value and
re-measures it, so the next block is chosen by a number and not by a guess.

Run: `sh probes/t6/run.sh`. Host: macOS 26 / arm64, **mc 1.1.0**, PHP 8.5.10
(Homebrew, NTS), php-src at `php-8.5.10`.

`probes/t5/` is left exactly as it was: it is a measurement of record and its
`run.sh` still reproduces its own number. `probes/t6/` is its two files grown.

## Answer: green 80 -> 1073, a factor of 13

| grid | green | wrong | refused | skip | php-fail | total | T5's green |
|---|---|---|---|---|---|---|---|
| `tests/lang` | **74** | 157 | 50 | 12 | 1 | 293 | 12 |
| `Zend/tests` | **452** | 3717 | 1025 | 112 | 6 | 5306 | 38 |
| `ext/standard/tests/strings` | **180** | 360 | 140 | 54 | 0 | 734 | 12 |
| **the whole corpus** | **1073** | 13374 | 3657 | 2947 | 344 | 21051 | 80 |

T5's line, same corpus and same harness:
`green 80 / wrong 15367 / refused 2639 / skip 2947 / php-fail 362 / total 21033`.
T0's, before any compiler existed:
`green 0 / wrong 18109 / refused 0 / skip 2947 / php-fail 339 / total 21056`.

**1066 of the 1073 greens are in T0's "touched by none" set** -- the 84.2% of the
corpus none of `docs/plan.md` § 3's decisions touches. The other **7** are the
first greens that a decision DOES have an opinion about, which is what the
third column is for: they are tests T0 classified as D5 (an `include`) or D6
(a `class_exists`-shaped question) and which the answers those decisions name
turn out to satisfy.

`refused` grew from 2639 to 3657 and `wrong` fell from 15367 to 13374, which is
the third column doing its job: a construct mc-php meets and REFUSES by name is
counted apart from one it gets wrong.

## What it is

| file | lines (code) | what |
|---|---|---|
| `php.mc` | 5477 (4940) | the compiler: one mc Tier 3 module |
| `php_rt.txt` | 5022 (4428) | the runtime, pushed into every program it compiles |
| `run.sh` | 132 | the probe |
| `why.py` + `whytable.py` | 96 | the wrong-reason table, re-measured on every run |
| `lencheck.py` + `aritycheck.py` | 88 | the two invariants the sources carry |
| `mcphp.sh` | 37 | executor B for `probes/t0/phpt-run.py` |

T5 was 2541 + 843. `mc-php` itself is 1756163 bytes: `<mc/core>` + `<float>` +
its two machines + `php.mc`. There is no second binary and no linker.

**Nothing in mc was touched**, and nothing was worked around: `php.mc` calls
**51** external names, **48** of them in `tests/golden/surface.txt`; the three
that are not (`float_init`, `machine_arm64_float_init`,
`machine_x86_64_float_init`) are `<float>`'s, which the freeze covers as a
bundle name and not as symbols. That is T5's finding, unchanged.

## The six blocks, in the order the numbers argued for

### 1. A zval, and php's ordered hash

The foundation. T5's array was a packed HOMOGENEOUS vector with the keys
0..n-1; a key or a mixed element was a named error. T6 has php's own:

* **zval**: 16 bytes, php's shape -- the value at 0, `u1.type` at 8,
  `u2` at 12. The u2 word is the collision link when the zval lives inside a
  Bucket, which is why a value copy is `ld64` + `ld32` and never a 16-byte
  memcpy.
* **the ordered hash**: `zend_array` field for field (56 bytes), a 32-byte
  Bucket (zval, h, key) and the u32 hash slots BEFORE `arData`, exactly as in
  php-src. Integer and string keys, php's numeric-string key rule
  (`$a["10"]` is `$a[10]`, `$a["010"]` is not), `nNextFreeElement`, insertion
  order, the holes `unset` leaves, DJBX33A with the top bit set.
  One deviation on record: php derives the slot index from `nTableMask` with a
  negative index and this computes it from `nTableSize`. The FIELD layout is
  php's -- which is what D2(b)'s shim reads -- the indexing arithmetic is not.
* **`mixed` is a php type whose lowering is a zval** (D4 (c)). That is what
  makes an array element heterogeneous (D4 (d)), `int / int` expressible (its
  type is `int|float`, a union) and `null` a value.

### 2. Classes and objects

536 of T5's 1694 sampled `wrong` reasons were `the declaration`, by a factor of
four over the next thing.

The class entry is built at run time by statements the compiler emits in front
of `main`, and every member is reached BY NAME through a registry. **That is
not reflection** (D6): the name is a literal in the source and no program can
enumerate the tables -- `get_class_methods` and friends stay refused.

A method is `uptr m_<Class>_<name>(uptr this, uptr a1..)`: every argument is a
zval and so is the result, which is what lets one `callp` dispatch every call.
An argument that was NOT passed arrives as 0, which is how a default value and
`ArgumentCountError` are both expressible without the caller knowing the
callee's arity.

Implemented: `class` / `abstract` / `final` / `interface` / `trait` (copied in
member by member) / `enum` (pure and backed, with `cases()`, `from()`,
`tryFrom()`, `->name`, `->value`); `extends` and `implements`, with the parent
resolved at build time so a class may extend one declared later in the file;
properties with defaults, static properties (a zval SLOT, so `self::$n++` is an
ordinary expression), class constants, constructor promotion, `$this`, `->`,
`?->`, `::`, `self`/`static`/`parent`, `::class`, `new`, `clone`,
`instanceof`; and the magic methods D6 keeps -- `__construct`, `__toString`,
`__get`, `__set`, `__call`, `__callStatic`, `__invoke`, `__clone`.

**Visibility is checked at RUN time** against a scope the compiler passes with
every access, because a method is reached through the vtable and the compiler
does not know the receiver's class. `public`/`protected`/`private` on both
properties and methods.

### 3. Functions, closures, callables

* **A php function is `mixed` by default** -- the single most common shape in
  the corpus, and T5 got it wrong: `function f() { return $a; }` has no
  declared return type, T5 defaulted it to `int`, and every such function
  answered 0.
* **An untyped parameter is `mixed`**, which retires the refusal T5 measured
  as "53 of the first 200" and named as the cheapest move from refused to
  green. It is D4 (c) read literally: php declares such a parameter `mixed` by
  omission, and a variable of a union type is a zval.
* default parameter values, `...$rest`, recursion, `static` variables.
* **closures**: `function () use (...)` and `fn() =>` (which captures every
  enclosing variable by value), bound `$this`, and a callable as a VALUE --
  which is what `array_map`, `array_filter`, `array_reduce`, `usort`, `uasort`
  and `uksort` take. D6 refuses only the STRING form.

### 4. Exceptions, and the decision behind them

**There is no VM and no setjmp.** mc's five targets include a bare board with
no libc, and a per-architecture setjmp written in `#opcode` would be five
copies of the hardest code in the runtime -- so unwinding is a PENDING-
EXCEPTION FLAG. A throw sets it and returns from the function it is in; the
compiler emits `if (php_thrown()) <unwind>` after every statement that contains
a call, and after none that cannot throw. A `try` block is a one-iteration mc
loop, so the unwind inside it is `break` and the catch chain follows -- which
is why `break N` counts php LOOPS through a stack of loop/try markers.

**The measurement** (`probes/t6/bench/bench.sh`, this host, the same compiler
built twice -- once as it ships and once with `ph_check` emitting nothing --
compiling the same program and timed interleaved against `php`):

| | | |
|---|---|---|
| the hot function `f_mix` with the check | 64 instructions | |
| the same function without it | 48 instructions | **+33% of the function** |
| 20 million iterations, with | median 0.137 s | |
| 20 million iterations, without | median 0.153 s | **the checked build is FASTER** |
| `php` on the same program | median 0.654 s | mc-php is 4.8x php |

The static cost is real and is a third of that function; the dynamic cost is
**below the noise floor of code layout on this host** -- the checked build,
which does strictly more work, runs 10% faster than the unchecked one, and that
number is stable over 15 interleaved repetitions. What the benchmark says is
that the check is not what makes a php program slow here.

The alternative was weighed and not built: `setjmp`/`longjmp` from libc would
be one call per `try` instead of one per statement, but mc targets a bare
RISC-V board with no libc at all (`examples/kernel`), and a per-architecture
`setjmp` written in `#opcode` would be five copies of the hardest code in the
runtime. It is also not free of its own trap: mc's M49 register allocator
keeps locals in callee-saved registers, which `longjmp` restores -- so every
local live across a `try` would need the equivalent of `volatile`.

**The cost, named and not hidden**: a side effect between the throwing call and
the end of the SAME statement still happens. `echo "a", f(), "b"` is the common
shape and is exact -- each echo argument is computed into a temporary with the
check between computing it and printing it -- but `$x = f() + g()` still runs
`g()`. The value is then discarded, because the check fires before the next
statement.

The hierarchy is built in: `Throwable`, `Exception`, `Error` and 23 subclasses,
with `getMessage`/`getCode`/`getFile`/`getLine`/`getPrevious`/`getTrace`/
`getTraceAsString`/`__toString`. php records where a throwable was CREATED, so
`php_new_at` takes the file and line. An uncaught one prints php's exact text
on stdout and the `PHP Fatal error:  ` form on stderr, exit 255.
`DivisionByZeroError` comes out of `/`, `%` and `intdiv` on every road, typed
and zval.

### 5. Constants, references, and the rest of the grammar

* 80 predefined constants as a table, with php's own values (`E_ALL` is 30719
  on this build, `STR_PAD_LEFT` is 0), plus `NAN`, `INF` and `__CLASS__`.
  A `const` whose value is not a literal, and an unknown bare name, go through
  php's RUN-TIME constant table -- which is what php does.
* **A reference is a variable holding a zval pointer that is written THROUGH**,
  and the names that need one come from a BYTE SCAN of every source in
  `on_source`, before a token is lexed. A typed local has no address a second
  name can share, so `&$x` has to be known at the variable's first assignment.
  A false positive costs a zval and nothing else. That one flag gives
  `$a = &$b`, `global $x` (which shares one never-moved zval through a
  registry, so a rehash cannot invalidate an alias), a function `static`, and a
  writing `foreach as &$v`.
* `switch` (php numbers the arms and `m` is the first arm to run, so
  fall-through is `if (m <= k)` and `default` is just another number), `match`,
  the conditional and `?:` and `??` and `??=` (all short-circuiting through a
  temporary, since an mc expression has no branch), prefix `++`/`--`, unary
  `~`, a float literal that starts with a dot, a variable whose name is a word
  mc lexes as a core keyword (`$break`), a closing tag that ends a statement.
* **heredoc and nowdoc**, with php 7.3's indented closing label stripped from
  every body line -- 69 of 622 sampled reasons were this one construct.
* php's SIMPLE interpolation with one accessor: `"$a[foo]"`, `"$a[5]"`,
  `"$a[$k]"`, `"$o->p"`, and the braced form `"{$a['foo']}"`.
* `sprintf`/`printf`/`vsprintf`/`vprintf` in full: `[argnum$][flags][width]
  [.precision]` and `b c d e E f F g G o s u x X %`, with php's own rounding
  (printf rounds half to EVEN: `%.1f` of 2.25 is 2.2). The format is still a
  literal (D1) and the compiler still emits one call per conversion -- there is
  no run-time format walker in the binary.

### 6. The library

The mechanism is one table: a row is (php name, runtime symbol, min, max,
return type); every argument is a zval and a missing optional one is
`php_znull()`, so the runtime does its own ZPP and the compiler needs no
special case per function. **173 rows** today, chosen by what the corpus
measurably calls.

`probes/t6/aritycheck.py` enforces the one invariant that table has -- the
table's `max` and the runtime function's parameter count must agree, because a
mismatch is an mc compile error with no hint of which row is wrong. It found 37
at once when it was written.

## Where a decision met reality

Five things this probe found that `docs/plan.md` § 3 should carry.

1. **D4 (c) answers three of the four things T5 said D4 had no answer for.**
   `mixed` is a php type and its lowering is a zval, so an untyped parameter
   (T5: "the cheapest thing that would move the refused column back into
   green"), `int / int` and `$x = null` all have one. What is left with no
   answer is an UNDEFINED VARIABLE: php warns and yields null, and a variable's
   type is its declaration or its first assignment -- a read before either has
   neither. It is still refused by name.

2. **A php array is a VALUE, and D7 removed the mechanism php uses for it.**
   `$b = $a; $b[] = 1;` must leave `$a` alone; php does that with a refcount
   and copy-on-write, and a refcount that never drops (D7 has no free) would
   never separate. T6 copies EAGERLY at the four places the value is handed
   over -- an assignment, an insertion, an argument, a return -- which is
   exactly right and costs one O(n) copy each. The compiler skips the copy when
   the source is a value it has just built.
   **The cost, measured** -- 2000-element array, `$b = $a` in a loop, peak RSS
   from `/usr/bin/time -l`:

   | copies | mc-php | php |
   |---|---|---|
   | 100 | 8.7 MB | 25.2 MB |
   | 300 | 22.8 MB | 25.3 MB |
   | 500 | 36.8 MB | 25.3 MB |
   | 1000 | **`mc-php: arena exhausted`** | 25.3 MB |

   So the crossover is around **300 copies** and the 48 MiB arena is exhausted
   between 500 and 1000 -- the same shape D7 already predicted for string
   concatenation, now with an array's constant. It fails cleanly and by name
   rather than lying, and the answer D7 already names is a per-scope arena,
   which T6 does not implement.

3. **Unwinding without a VM and without setjmp is a flag and a check.** See
   § 4 above; the measurement is there.

4. **`__destruct` is not implemented, and that is a D7 consequence.** php runs
   a destructor when the last reference goes away; D7 has no refcount and no
   free, so the only honest points are scope end and program end, and neither
   is php's. **333 of the 21395 `.phpt` mention `__destruct`.** The decision is
   deferred to a milestone that can say what it costs; today the method is
   parsed, registered and never called.

5. **21.8% of the corpus asserts a php DIAGNOSTIC line.** 4657 of the 21386
   tests with an expect section contain `Warning:`, `Deprecated:`, `Notice:` or
   `Fatal error:` (1882 / 849 / 196 / 1990). A compiled binary has to produce
   those, with the file and the line, which means the compiler passing a
   position into every runtime function that can warn. T6 produces the
   `Fatal error:` form for an uncaught throwable and nothing else. This is the
   largest single structural item left and it is T7's.

## The wrong-reason table, re-measured

`probes/t6/why.py` asks the compiler what it has to say about every `wrong`
test under `tests/lang` and `ext/standard/tests/strings` and the first 900
under `Zend/tests` -- the same sample T5 took, so the two are comparable --
and `whytable.py` groups them. It runs on every `sh probes/t6/run.sh`.

```
  1417 `wrong` tests, by what mc-php said about each
    536  (compiled; output differs)
    288  a php function or constant mc-php does not have
     40  a php class member
     35  mc-php
     33  expected { in php
     32  the wrong number of arguments for
     30  expected ; after a php property
     28  expected ) in a php call
     27  a php variable used as a statement
     26  expected ; after a php expression
     25  a by-reference parameter in a typed function
     25  an anonymous class
     22  expected ; after a php assignment
     22  a by-reference use in a closure
     21  a php parameter
     20  an assignment by reference
     18  the storage keyword
     16  a function returning by reference
     16  var_dump of
     15  unknown name
     13  argument unpacking ...$args
     13  expected = after a php array index

  the most wanted names mc-php does not have:
  class_alias(24), fopen(20), pack(20), crypt(14), get_html_translation_table(12), spl_autoload_register(11), unpack(10), register_shutdown_function(9), file_put_contents(9), debug_print_backtrace(7), highlight_string(7), func_get_arg(6), addcslashes(6), strtok(6), php_strip_whitespace(5), serialize(5), mb_internal_encoding(5), set_exception_handler(4), sscanf(4), metaphone(4), parse_ini_string(4), get_called_class(4), __HALT_COMPILER(4), highlight_file(3), strnatcmp(3), quoted_printable_encode(3), str_getcsv(3), show_source(3), str_decrement(3), array_multisort(3), array_splice(3), b(3), foo(3), pathinfo(2), utf8_decode(2), unserialize(2), convert_uuencode(2), str_shuffle(2), strnatcasecmp(2), Array(2)
```

T5's table, for the same sample: `the declaration` 536, a missing function 420,
a missing constant 196, exceptions 97, `a php expression was expected` 82, a
keyed array literal 54, a heterogeneous array 52, and **44 of 1694 compiled and
then disagreed**.

Every one of those seven is gone. What replaced them is the honest shape of a
compiler that now compiles most of what it is given: **536 of 1417 compile and
then print the wrong thing**, where T5 had 44. That is the number T7 works.

## The mc gaps

### Still open, and unchanged: the bytes before the FIRST token

`p_skip_to` moves the cursor relative to a token that has already been lexed,
so a `.php` whose first bytes are inline HTML -- `Hello <?php echo 1;` -- is
lexed as stray identifiers before any handler can run. T5 reported it and T6
hits it exactly as often: ****38 of the 21219 `.phpt` with a `--FILE--` section** -- the same 38 T5 counted** die on it, and
`ph_on_source` refuses such a file by name rather than mis-lexing it.

The smallest additive fix is the one T5 named: let `on_source` return a byte
offset at which lexing should begin (0 = the whole buffer), or give
`p_push_source` an offset argument. Either is one parameter and changes nothing
for a module that does not use it.

### Nothing new

T6 is three and a half times T5 and calls three more external names than T5
did (51 against 48), all three of them already frozen. No new gap was found and
nothing was worked around.

### Notes, not gaps

* **mc's `N_ADDR` carries the name on the node itself** (`res_addr` reads
  `nd_name(n)`), not on a child `N_IDENT`. Building the child form segfaults
  the compiler with no diagnostic. `docs/reference/hooks.md` does not say this
  and `node_new(N_ADDR, ...)` is the natural thing to write.
* **A node reused in two argument lists is a CYCLE**, because `nd_next` is the
  argument link. It cost three bugs here, each of which recursed until the
  stack ran out. A module building its own calls has to build a fresh node per
  use, which is not obvious from the accessor names.
* **`mc --exe` must not overwrite its own output at the same inode**: the
  kernel kills the next run with SIGKILL. mc's own M12 note records this for
  `mc build`; it applies to the single-file road too, and it cost an hour of
  believing a compiler was miscompiling when it was not being rebuilt.

## Fixtures

**24 of 24** fixtures under `g/` produce byte for byte what `php` produces
(stdout, stderr and exit code) and **5 of 5** under `r/` are refused by name
with exit 3. `d4-intdiv.php` left `r/` for `g/`: `int / int` is no longer a
refusal, because D4 (c) answers it.

## What T7 must do

In the order the numbers argue for.

1. **`(compiled; output differs)`, 536 of 1417.** The largest and the least
   structured; each one is its own question. A sample of the first forty under
   `tests/lang` gave four kinds: php's DIAGNOSTIC lines (below), a private
   property shadowed by a public one of the same name in a subclass (php
   mangles a private property by its declaring class and T6 has one table per
   object), the float tail T5 already named (`1.7E-300` comes out
   `3.720368547758E-299`: the scaling by a power of ten stops being exact past
   1e±22), and ordinary missing behaviour.

2. **php's diagnostics: 4657 of the 21386 tests with an expect section --
   21.8% -- assert at least one `Warning:`, `Deprecated:`, `Notice:` or
   `Fatal error:` line** (1882 / 849 / 196 / 1990). T6 produces the
   `Fatal error:` form for an uncaught throwable and nothing else. Doing it
   means the compiler passing a file and a line into every runtime function
   that can warn, which is a wide but entirely mechanical change, and it is the
   biggest single structural item left.

3. **References across a call boundary**: a by-reference PARAMETER
   (`function f(&$x)`) needs the CALLER's variable to be a zval, and the
   caller's name is not the one the `&` is written next to -- so the byte scan
   that finds `&$x` cannot find it. The function table knows which parameters
   are by reference; what is missing is a second pass, or a scan that follows
   a declaration to its call sites. 25 + 20 + 22 + 16 of the 1417 are this
   family.

4. **The long tail of the library**: 288 of 1417 name a function or constant
   that is not there. The most wanted are in the table above; `class_alias`,
   `fopen` and the file family, `pack`/`unpack`, `crypt`, `serialize`/
   `unserialize` and `spl_autoload_register` lead it.

5. **The grammar's remaining corners**, each small and each named: an anonymous
   class (25), `...$args` at a CALL site (13), `list()`/`[$a, $b] =`
   destructuring, named arguments, `goto`, the alternative
   `if:`/`endif;` syntax, `__HALT_COMPILER`.

6. **`__destruct`** (333 tests mention it) and the per-scope arena D7 names,
   which are the same question asked twice: both need to know when a value dies.

## D8

`docs/plan.md` D8 asks that every `.php` written in this repository carry a
PHPUnit test that runs in both worlds and a `bench/` row. Everything under
`g/` and `r/` is a FIXTURE -- the probe's own input, compared against `php` on
every run, which is the same gate a test would be -- and nothing here is a part
of the runtime or the standard library written in PHP.

What T6 DOES add is `probes/t6/bench/unwind.php` and `bench.sh`, which exist
for the unwinding measurement in § 4. Its test in both worlds is the
byte-for-byte comparison `bench.sh` makes on every run -- php and the two
mc-php binaries must print the same line, and the script exits 1 if they do
not -- and its bench row is the table in § 4. `mc-php test`, D8 (a)'s
compile-time discovery of `test*` methods, does not exist yet: it belongs to
the compiler and not to a probe, and it is on T7's list.

# T8 -- the wall was `(does not compile)`, and it is not any more

Question (`docs/plan.md` § 4): T7 answered **1218 of 21050** and left one
number pointing at what to do next -- **878 of 1460 sampled `wrong` tests DO
NOT COMPILE**, of which **288 name a php function or constant mc-php does not
have**. T8 takes the first apart, group by group, and works the second in
descending frequency.

Run: `sh probes/t8/run.sh`. Host: macOS 26 / arm64, **mc 1.1.0**, PHP 8.5.10
(Homebrew, NTS), php-src at `php-8.5.10`.

`probes/t7/` is left exactly as it was. `probes/t8/out/base/`, measured here
against a snapshot of T7's compiler, is `tests/lang` **82**, `Zend/tests`
**539**, `ext/standard/tests/strings` **194** -- T7's three numbers to the
test.

Every measurement in this file was taken against a SNAPSHOT of the compiler
(`probes/t8/grid.sh`, and `probes/t8/fixtures.sh` does the same now), which
is T7's own note: the first baseline there measured a binary that was being
rebuilt underneath it.

## Answer: green 1218 -> 1450

| grid | green | wrong | refused | skip | php-fail | total | T7's green |
|---|---|---|---|---|---|---|---|
| `tests/lang` | **93** | 144 | 44 | 12 | 1 | 293 | 82 |
| `Zend/tests` | **635** | 3606 | 953 | 112 | 6 | 5306 | 539 |
| `ext/standard/tests/strings` | **223** | 350 | 107 | 54 | 0 | 734 | 194 |
| **the whole corpus** | **1450** | 13607 | 3026 | 2947 | 365 | 21030 | 1218 |

**The `php-fail` column is php's own**, and this run had 365 against the
previous one's 346: the machine was loaded (two grids and an analysis at
once) and nineteen tests failed on php's SIDE, five of them tests the
previous run had green. Re-run on a quiet machine with the same binary, all
five are green -- so **the tree's number is 1455** and 1450 is what the
loaded run measured. Both are recorded because the measurement is the claim.

T7's line, same corpus and same harness:
`green 1218 / wrong 13968 / refused 2917 / skip 2947 / php-fail 345 / total 21050`.
T6's: `green 1073`. T5's: `green 80`. T0's, before any compiler existed:
`green 0`.

**1441 of the 1450 greens are in T0's "touched by none" set** -- the 84.2% of
the corpus none of § 3's decisions touches. The other nine are the greens a
decision has an opinion about; T7 had seven.

`refused` rose 2917 -> 3026 and `wrong` fell 13968 -> 13607. Both are honest:
a test that now COMPILES gets far enough to hit a design refusal it never
reached before, which is the third column doing its job.

### The two sub-populations T7 measured, re-measured here

| block | tests | T7 green | T8 green |
|---|---|---|---|
| assert a `Warning:`/`Deprecated:`/`Notice:`/`Fatal error:` line | 4647 | 71 | **83** |
| mention `__destruct` | 333 | 11 | **14** |

Neither was a T8 target; both moved because the tests around the diagnostic
now compile.

## What it is

| file | lines | what |
|---|---|---|
| `php.mc` | 6808 (was 5807) | the compiler: one mc Tier 3 module |
| `php_rt.txt` | 7571 (was 5930) | the runtime, pushed into every program it compiles |
| `nocompile.py` | 59 | **new**: the `(does not compile)` block, grouped, with examples |
| `fixtures.sh` | 42 | **new**: the `g/` and `r/` gate, on a SNAPSHOT of the compiler |
| `subpop.py` | 26 | **new**: the two sub-populations T7 named, re-counted |
| the rest | | T7's, unchanged in shape |

The library table went **180 rows -> 242**; `g/` went 30 fixtures -> 46.

`php.mc` calls **58** names from outside itself: **48 are in mc's
`tests/golden/surface.txt`**, four are core INTRINSICS and not library
symbols (`ld8`, `ld64`, `st8`, `st64` -- `docs/reference/language.md` § 6),
three are `<float>`'s (`float_init`, `machine_arm64_float_init`,
`machine_x86_64_float_init`, which the freeze covers as a bundle name) and
three are libc: `write` and `exit`, which the module declares itself (T7),
and `realpath`, which `<mc/host>` already declares and T8 uses to resolve a
script's path the way php does.

**Nothing in mc was touched and nothing was worked around.**

## 1. `nocompile.py`, and what the groups turned out to be

`whytable.py` prints the head of the block as a flat top-22 with no way back
to a file. `nocompile.py` reads the SAME `why.tsv` -- so no compiler run is
repeated -- masks the variable part of each message, groups, and prints the
count with **three example files per group**. A group with examples is
workable; a group with a count is only countable.

Worked in descending order:

### References, 83 of the 1460 across four messages

A by-reference parameter is FREE once the caller's variable is a zval: a
`mixed` local already HOLDS a zval pointer, and a ref writes THROUGH it
(`php_zv_store`), which is the mechanism `$a = &$b` and `global $x` have used
since T6. What was missing is that the CALLER's variable had to be one, and
nothing made it so.

The source scan already had the rule -- "a variable that is ever aliased has
to be a zval from its FIRST assignment", from a byte scan for `&$x` -- so it
grew two passes: `ph_scan_brf` finds every `function name(... &$x ...)` (its
own pass, because a call may come before the declaration) and
`ph_scan_brf_calls` puts every `$variable` inside the parentheses of a call
to one of them into the ref set. It does not track argument POSITIONS:
over-marking costs a zval and nothing else, which is what the rule above it
already costs.

An UNBOUND name passed by reference is CREATED rather than read -- php does
not warn for one -- which is what makes an output parameter work.

With that in place the other three were small: `use (&$x)` in a closure (the
capture is the enclosing zval's ADDRESS, carried through the use array as an
integer, rather than a copy of its value -- the array slot `php_arr_set`
writes is a different cell and could not alias), a by-reference parameter in
a METHOD (free: every method parameter is already a zval pointer, so marking
it a ref is the whole change) and `function &f()` (D7 has no refcount, so
what `&` can mean here is that the value is not copied on the way out).

Five BUILTINS take a by-reference argument and the library table has no
column for it, so they are named: `settype`, `parse_str`, `array_splice`,
`similar_text`, `str_replace`. Every other by-reference builtin in this
runtime takes an ARRAY, and an array handle is already a pointer.

### `$f();` as a statement, 27

A statement that starts with a `$variable` and turns out not to be an
assignment now falls through to the ordinary expression road. `ph_expr` is
split into its primary half and `ph_expr_tail`, the operator half, which the
statement path continues with -- so `$f();`, `$x or die();` and `$a ?: b;`
are all the same road.

### The alternative syntax, all five

`if: endif;` and the same for `while`, `for`, `foreach` and `switch`. One
helper, `ph_alt_body`, which is `ph_block`'s loop with a WORD for its `}`;
`if` also stops at `elseif`/`else`, which the caller then reads.

### `list()` and `[$a, $b] =`, 21

The pattern is collected FIRST -- the source expression comes after the `=`
-- as a flat list of PATHS: each target is a variable plus the chain of keys
that reaches its value, so `[$a, [$b, $c]]` is three targets with the chains
0, 1/0 and 1/1, and nesting and `'k' =>` are the same code. A `$name` in a
pattern is either the target or the KEY of `$k => $v`, and the token after it
is what says which.

### Anonymous classes, 25

The body is an ordinary class declaration under a generated name
(`class@anonymous<N>`), registered with every other class before `main` runs.
The constructor arguments sit between the keyword and `extends`, so
`ph_class` reads them where they are and hands them back to the `new`.

### A method's `: void`, 37

`ph_skip_type` tested `ph_tid == T_IDENT`, and `void` is one of **mc's OWN**
keywords -- so the skip consumed nothing and the body's `{` was never
reached. The test is what the token LOOKS like now (`ph_wordish`), which is
also what `: static` and `: never` need.

### The lvalue chain, 71 across three messages

`ph_lv_walk` walked `[k]` only, so `$a[0]->p = 1`, `$t->x[0][0] = v` and
`$c = &$t->list` had nowhere to go. It walks `[k]` and `->p` in any order and
to any depth now, and answers a container plus EITHER a key or a property
name; `ph_store` writes whichever it is.

Two things worth keeping:

* The property name is PASSED to `ph_store` and not read from the global the
  walk sets. The other caller -- `ph_obj_stmt`'s `$o->p[k] =` -- would
  otherwise see a stale one, which is how `$t->x[0] = "q"` wrote a property
  named after an earlier statement's.
* **A node may appear in a tree ONCE.** The arguments of a call are its
  SIBLING chain, so sharing the hoisted container between the read and the
  write of a compound assignment made the chain a CYCLE -- which is a stack
  overflow in the walker, not a diagnostic. Each use gets its own `ph_tref`.

### `isset()` and `empty()` over the same chain, 34

Read QUIETLY, to any depth: php warns for nothing either of them touches, and
a key or property that is not there reads as null, which is the answer both
of them want. A string offset out of range reads as null too
(`php_str_off_q`), which is what `isset($s[9])` asks.

### A compound assignment to an element, 13

Plus `??=`, `++` and `--` on one. The container and the key are hoisted into
temporaries WHATEVER follows, because a compound form has to READ the element
as well as write it and the tokens cannot be walked twice. `??=`'s
temporaries have to be initialised OUTSIDE the branch that reads them, and
its right-hand side's own pendings have to stay INSIDE it, because php does
not evaluate it when the element is already set.

### The rest, each small

`@$a[0] = 1;` -- the suppression on a STATEMENT; an assignment is a statement
here, so T7's expression-level `@` never saw it. `$s[9] = "x"` -- php's byte
write, answered with a new string bound to the same name, which is the same
value semantics. `int ...$n` -- a variadic parameter written after its type.
`$r = &$o->p` and `$r = &$a[k]` -- the CELL the chain ends on.

## 2. The names, in the order the frequency list argues for

T7's list led with `fopen(40)`, `pack(20)`, `crypt(14)`,
`spl_autoload_register(13)`, `get_html_translation_table(12)`, `unpack(10)`,
`file_put_contents(10)`.

**Files and streams** -- the biggest block, and the one the corpus needs
most, because it writes temporary files constantly. A php `resource` is a
zval of type `IS_RESOURCE` whose value indexes ONE table; php's own resource
ids are small integers too, and `var_dump` prints exactly that. **39 library
rows** over the six calls `<sys>` declares plus five a module may declare
itself (`stat`, `lseek`, `access`, `getenv`, `getpid`, `unlink`, `rename`,
`mkdir`, `rmdir`). Two things the shape forced: mc's `open` is not variadic
(the mode goes on the stack and the core does not set it up), so a create is
`creat()` + reopen; and `php://stdout`, `://stderr`, `://stdin` and
`://output` are the four special paths the corpus uses.

**pack / unpack**, 30 -- every code php has, with its repeater and `*`. The
byte orders are spelled OUT rather than probed: a compiled program must give
the same answer on each of the five targets mc compiles for, which is the
same rule `docs/plan.md` D10 states for the string type. `pack` is VARIADIC,
so the compiler packs its arguments into an array the way a `...$rest`
parameter is packed at a call site.

**Output buffering**, which NESTS. `php_ob_start` was ONE level -- a capture
for `print_r($x, true)` -- so `ob_start(); print_r($x, true);` lost the outer
buffer. It is a stack now, and `ob_get_clean` / `ob_get_contents` /
`ob_get_length` / `ob_get_level` / `ob_end_clean` / `ob_end_flush` /
`ob_get_flush` / `ob_flush` / `ob_implicit_flush` / `flush` are php's own.

**`get_html_translation_table`**, 13 -- php's own 253-entry table, dumped
from php 8.5.10 as `codepoint:name` pairs and compared back against it by a
fixture that checks the count, two entries and both flag shapes.

**`fprintf` / `vfprintf`**, 22 -- the same formatter T6 built, with a stream
in front of it.

**`func_num_args()` and `func_get_arg(k)`** -- answered where php answers
them: inside the callee, from its OWN parameters. The count is a prologue
local (`phna`) filled BEFORE the defaults are, because after them every
parameter is non-zero and the count is lost; it is emitted only when the
source names one of the two, so no program that never writes them pays for
it. **Neither needs the run-time type table D6 refuses** -- see § 5.

And: `serialize`, `unserialize`, `settype`, `parse_str`, `array_splice`,
`str_getcsv`, `str_decrement`, `uniqid`, `quoted_printable_encode`/`_decode`,
`convert_uuencode`/`_uudecode`, `mb_internal_encoding`.

## 3. Four defects the blocks found, none of them in the block being built

1. **The source scans read BYTES, and a comment is not code.** One line of
   the RUNTIME's own commentary -- `// array_splice(&$a, offset, ...)` -- put
   `$a` in the ref set, so every `$a` in every program became a zval and the
   D4 refusal `$a = "one"; $a = 1;` stopped firing. `probes/t8/r/d4-retype.php`
   caught it, which is what the refusal gate is for. `ph_scan_hop` skips
   `//`, `#` (but not `#[`), `/* */` and both quote forms, in all three
   scans. A `&$x` inside a double-quoted string is an interpolation and not
   a reference either, so skipping it is right too.

2. **The unwinding check was missing on `return`.** T6's rule is that the
   check goes BETWEEN computing a value and using it; the return statement
   put it AFTER, where nothing runs. `return f();` inside a `try` left the
   exception pending and the `catch` beside it never saw it. Measured with a
   `ValueError` a library row raises.

3. **A class member's DEFAULT may be an array literal**, and an array literal
   is pending statements plus a local. `public $x = [1, 2];` captured the
   local before those ran, so the property came out `array(0)` and, with
   another array literal earlier in the file, the program **SEGFAULTED**.
   `ph_cfill` puts the pendings in front of the fill. Older than T8.

4. **`lencheck` did not cover `php_str_new("...", N)`**, which is how most of
   the runtime spells a literal. Three lengths were wrong, one of them ten
   bytes long -- which reads past the literal into whatever the linker put
   next. The pattern is in the check now: **100 pairs -> 418**.

## 3b. The tables, re-measured on the block-3 compiler

1396 `wrong` tests -- `tests/lang` + `ext/standard/tests/strings` in full plus
the first 900 of `Zend/tests`, T7's own sample shape -- by what mc-php said
about each. **The block INVERTED**: `(does not compile)` was 878 of 1460 and
is 638 of 1396, and the majority is now what a test PRINTS.

```
   758  (compiled; output differs)          (was 582)
   638  (does not compile)                  (was 878)
        of which:
    177  a php function or constant mc-php does not have   (was 288)
     54  expected ; after a php expression
     41  mc-php: <a named limit>
     31  PHP Fatal error
     30  expected ; after a php property
     27  expected ) in a php call
     26  an assignment by reference
     25  the wrong number of arguments for
     23  a php parameter
     19  the storage keyword                 (`static::`, late static binding)
     17  argument unpacking ...$args
     12  a reference &$x
     11  expected ; after a php assignment
     11  expected = after a php array index
     10  a php file that does not open with <?php   (the mc gap)
     10  an assignment by reference to something that is not a $variable
     10  a reference to a php variable of type
```

and the names that are left, by frequency:

```
  sscanf(16), crypt(14), spl_autoload_register(13), debug_print_backtrace(7),
  highlight_string(7), php_strip_whitespace(6), __HALT_COMPILER(5),
  set_exception_handler(4), metaphone(4), parse_ini_string(4),
  get_called_class(4), parse_ini_file(4), register_tick_function(4),
  highlight_file(3), show_source(3), array_multisort(3), next(3),
  stream_wrapper_register(3), restore_error_handler(3) ...
```

Three of those are not functions: `b(3)`, `foo(3)` and `Array(2)` are a
test's own names in a context this compiler reads as a call.

And the 758 that compile, by what differs:

```
      355  var_dump of a value
      166  a php diagnostic
      121  a blank line
       73  other text
       15  a float
       11  an integer
        9  print_r of a container
        2  (timed out)
        2  (agrees on this harness)
        2  var_export of an element
        1  print_r of an element
        1  a container delimiter
```

`a php diagnostic` is 166 and its head is now php diagnostics for features
this compiler does not have at all -- `Allowed memory size exhausted`,
readonly properties, `Deprecated`/`NoDiscard` as classes -- which is T7's own
finding one size larger. **`php '' / mc 'Done'`, 29 of the 121 blank lines,
is the biggest single pair in the whole table**: they are php COMPILE-TIME
fatals for constructs the parser accepts, and T7's road for those (stdout,
exit 255) exists and is only four messages wide.

Four of the pairs in that table were exact enough to fix on the spot, and
block 4 did: `similar_text`'s `$percent`, `str_replace`'s `$count`,
`str_decrement`'s wording and `unserialize`'s level and its input check.

### D7, re-measured

`probes/t8/arena.py`: **11 of 1396** sampled `wrong` tests exhaust the arena,
against T7's 9 of 1460. The two new ones are `bug69522` and `gh10940`, and
they are the same shape as the four T7 named -- a program that builds a very
large STRING. Still **not one is an array copy**, so T7's decision stands and
copy-on-write is not built.

## 4. What is not there, with its number

* **A referenced array element is not marked.** php's `var_dump` prints
  `&int(99)` for an element another name holds a reference to; D7 has no
  refcount, so there is nothing at run time that tells the mark from the
  value. The VALUES agree; `g/42-string-offset-ref.php` compares them with
  `echo` and says why.
* **`func_get_args` stays refused.** D6 names it, and a decision is the
  owner's to change -- see § 5.
* **A by-reference argument that is not a plain `$name`** -- `f($a[0])`,
  `f($o->p)` -- takes the ordinary road and so passes a COPY. php passes the
  cell. The shape is reachable (`ph_lv_walk` finds the cell for
  `$r = &$a[k]` already) and it is not built.
* **More arguments than a function declares.** php accepts them and
  `func_get_args` returns them; here it is still `the wrong number of
  arguments for`, 25 of the sample -- and it is why `func_num_args` counts
  the DECLARED parameters that arrived and no others.
* **`static::`** (late static binding) is still `the storage keyword: static`,
  19 of the sample. `new static` and `static function` compile.
* The **mc gap** is unchanged and T8 hits it exactly as often: **38 of the
  21219 `.phpt` with a `--FILE--` section** open with inline HTML, which the
  core lexes as stray identifiers before `syntax("<?php")` can fire.

## 5. One thing for the owner

`docs/plan.md` D6 lists `func_get_args` among the reflection functions,
because "a binary carries no run-time type tables". T8 measured that this
particular one needs no such table: the arguments of the currently executing
function ARE its own parameters, which the compiler has in front of it, and
`func_num_args()` / `func_get_arg(k)` -- which D6 does NOT name -- are built
here out of exactly that. `func_get_args` is the same information in an
array, and it is left refused because D6 names it and the decision is the
owner's, not a probe's.

## D8

`docs/plan.md` D8 asks that every `.php` written in this repository carry a
PHPUnit test that runs in both worlds and a `bench/` row. Everything under
`g/` and `r/` is a FIXTURE -- the probe's own input, compared against `php`
on every run, which is the same gate a test would be -- and nothing here is a
part of the runtime or the standard library written in PHP. T6's
`bench/unwind.php` is unchanged and still compared in both worlds by
`bench/bench.sh`. `mc-php test` still does not exist: it belongs to the
compiler and not to a probe.

## What T9 should do

In the order the numbers argue for, and they are all in § 3b.

1. **`var_dump of a value`, 355 of the 758 that compile** -- the largest
   single group in the whole table now, and no longer one theme. Its head is
   `php 'int(N)' / mc ''` (24) and `php 'array(N) {' / mc ''` (18), which is
   a test that stops before it gets there, and `php 'int(N)' / mc 'int(N)'`
   (23), which is the same shape with a different NUMBER.
2. **php COMPILE-TIME fatals, 29 of the 121 blank lines** and the single
   biggest pair in the table (`php '' / mc 'Done'`). The road exists since T7
   -- the text on stdout, exit 255 -- and only the duplicate-modifier family
   uses it. `Cannot redeclare`, the parse errors and the interface conflicts
   are each one check at their own site.
3. **`static::`, 19** -- late static binding, the last of the grammar's
   corners with a number. In an instance method it is a dispatch on `$this`
   and so allowed by D6; in a static one php tracks the CALLED class, which
   needs a runtime global set at each static call site.
4. **`sscanf` (16), `crypt` (14), `spl_autoload_register` (13)** lead what is
   left of the names -- and the third is D5-shaped: `docs/plan.md` D5 already
   says an autoloader over a literal map is compile-time resolution.
5. **php's `memory_limit`.** Six of the 166 diagnostic rows are tests that
   EXPECT php to run out, and the arena exhausts silently instead; a limit
   and its `Fatal error:` is the diagnostic channel plus a counter. Still
   T7's item 4, and the number has grown.
6. **`argument unpacking ...$args` (17)** and the four remaining reference
   shapes (`an assignment by reference` 26, `a reference &$x` 12, `an
   assignment by reference to something that is not a $variable` 10, `a
   reference to a php variable of type` 10), which is 58 between them and
   the same theme block 1 opened.

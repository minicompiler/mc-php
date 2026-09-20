# T5 -- does the runtime agree with php?

Question (`docs/plan.md` § 4): the first runtime, measured against the `.phpt` corpus.
The number that matters is **green**, and it was 0 before this probe.

Run: `sh probes/t5/run.sh`. Host: macOS 26 / arm64, **mc 1.1.0**, PHP 8.5.10 (Homebrew, NTS),
php-src at `php-8.5.10`.

## Answer: green moves off zero

| grid | green | wrong | refused | skip | php-fail | total |
|---|---|---|---|---|---|---|
| `tests/lang` | GREEN_LANG | WRONG_LANG | REFUSED_LANG | SKIP_LANG | PHPFAIL_LANG | TOTAL_LANG |
| `Zend/tests` | GREEN_ZEND | WRONG_ZEND | REFUSED_ZEND | SKIP_ZEND | PHPFAIL_ZEND | TOTAL_ZEND |
| `ext/standard/tests/strings` | GREEN_STR | WRONG_STR | REFUSED_STR | SKIP_STR | PHPFAIL_STR | TOTAL_STR |
| **the whole corpus** | **GREEN_ALL** | WRONG_ALL | REFUSED_ALL | SKIP_ALL | PHPFAIL_ALL | TOTAL_ALL |

T0's baseline, for the same corpus and the same harness, was
`green 0 / wrong 18109 / refused 0 / skip 2947 / php-fail 339 / total 21056`.

TOUCHED_LINE

Beside the grid, and measured on every run: **15 of 15** fixtures under `g/` produce byte for
byte what `php` produces (stdout, stderr and exit code), and **6 of 6** under `r/` are refused by
name with exit 3.

## What it is

Two files, and neither of them touches mc.

| file | lines (code) | what |
|---|---|---|
| `php.mc` | PHPMC_TOTAL (PHPMC_CODE) | the compiler: one mc Tier 3 module |
| `php_rt.txt` | RT_TOTAL (RT_CODE) | the runtime, pushed into every program it compiles |
| `mcphp.sh` | 37 | executor B for `probes/t0/phpt-run.py` |
| `run.sh` | 116 | the probe |

`mc-php` itself is MCPHP_BYTES bytes: `<mc/core>` + `<float>` + its two machines + `php.mc`.
There is no second binary and no linker -- `mc-php --exe x.php -o x` writes the executable.

### The lowering, D10's table as it stands

| PHP | mc | notes |
|---|---|---|
| `bool` | `u8` | the two values 0 and 1 |
| `int` | `i64` | |
| `float` | `f64` | mc's `<float>`, registered by this compiler's `user_init` |
| `string` | `php_str`, a `type_new(8, 8, TK_INT)` handle | the record is T3's `zend_string`: refcount u32 at 0, type_info u32 at 4, hash u64 at 8, len u64 at 16, bytes at 24. **Binary-safe and never encoding-validated** -- `strlen("\xc3\xa9")` is 2 (`g/03-binary-safe.php`), a NUL travels inside a string, and UTF-8 is content and not a property of the type. Immutable: every write makes a new string |
| `array` | `php_arr`, a second handle | a packed vector of 8-byte slots, keys 0..n-1, **homogeneous**. A key or a mixed element is a named error, not a zval. This is T5's own limit, not D4's |
| `int\|false` | `i64`, with -1 as the false | the ONE union, and it exists because `strpos` has it. `=== false` compiles to `== -1` and `var_dump` branches at run time, so both are right |
| `null` | -- | a value of `?T`/unions only (D9 (e)), and T5 has neither: assigning `null` to a variable is a named refusal |

Memory is D7's: one arena (48 MiB of `__bss`), never freed, released by `exit`. A string literal
is built once per program **run** and cached in a global the compiler emits beside it, because an
arena with no free cannot afford one copy per loop iteration.

### What the compiler implements

`source_claim` is **not** registered, and that is a change from T4. A registration is scoped to
the sources a module claims, and `type_new("f64")` inside `<float>` is a registration: claiming
`.php` alone would scope `f64` out of this compiler's own runtime. One `syntax("<?php", &f)`
plus `syntax_expr("$", &f)` is the whole surface, and `on_source` is used only to refuse a `.php`
that does not open with `<?php`.

* **Statements**: `echo` (any number of arguments), `print`, `if`/`elseif`/`else`, `while`,
  `do`-`while`, `for`, `foreach` with and without a key, `break N`, `continue N`, `return`,
  `{ }`, `;`, `require`/`require_once`/`include`/`include_once` of a literal path (D5),
  `const`, `declare()`, `namespace`/`use` (parsed and ignored), `exit`/`die`, inline HTML.
* **Expressions**: PHP's precedence for
  `** * / % + - . << >> < > <= >= == != === !== <> <=> & ^ | && || `, unary `- + !`,
  the four casts `(int) (float) (string) (bool)`, `[...]`/`array(...)` literals, `$a[i]`,
  `$a[] =`, `$a[i] =`, `++`/`--`, `.= += -= *= /= %= **=`, parentheses.
* **Literals**: decimal, hex, `0b`, `0o`, **legacy `0777`**, `1_000`, floats with an exponent,
  `'single'` with php's two escapes, `"double"` with php's OWN escape set (`\n \t \r \v \e \f
  \\ \$ \" \xNN \u{...} \NNN` octal) and `$name`/`{$name}` interpolation.
* **Functions**: a typed declaration (D4 requires the parameter types), recursion, `void`.
* **The named functions**: `echo`/`print`, `var_dump`, `strlen`, `str_repeat`, `substr`,
  `strpos`, `str_replace`, `implode`/`join`, `explode`, `count`/`sizeof`, `intdiv`, `abs`,
  `max`, `min`, `sprintf`, `printf` (`%d %s %f %%` only), `intval`, `strval`, `floatval`,
  `boolval`, `is_int`/`is_string`/`is_float`/`is_bool`/`is_array`/`is_null`/`is_numeric`,
  `isset`, `empty`, `chr`, `ord`, `strtoupper`, `strtolower`, `ucfirst`, `lcfirst`, `trim`,
  `ltrim`, `rtrim`, `str_pad`, `strrev`, `str_contains`, `str_starts_with`, `str_ends_with`,
  `strcmp`, `strcasecmp`, `define`, `defined`.
* **Compile-time answers**, because D4 makes the type static: every `is_*`, `isset`, `defined`,
  and a `printf` format, which must be a literal (D1) and is compiled into a chain of
  concatenations -- there is no run-time format walker in the binary.
* **The constants**: `true`, `false`, `null`, `PHP_EOL`, `PHP_INT_MAX`, `PHP_INT_MIN`,
  `PHP_INT_SIZE`, `PHP_FLOAT_DIG`, `STR_PAD_*`, `__LINE__`, `__FILE__`, `__DIR__`,
  `__FUNCTION__`, `__METHOD__`.

### What it refuses, by name, with exit 3

Every refusal is `mc-php: <what> is refused by design (docs/plan.md D<n>)` on stderr, and
`mcphp.sh` turns that into the grid's third column. A construct T5 simply has not built yet is a
DIFFERENT message -- `mc-php: <what> is not implemented in T5` -- and an ordinary compile error
(the grid counts it `wrong`), because inflating the refused column with "not implemented" would
make that column a lie.

| refusal | decision |
|---|---|
| `eval`, `create_function`, `assert` with a string, an `include` of a computed path, a `printf` format that is not a literal, `define()`/`defined()` with a computed name | D1 |
| a second assignment of another type, an undefined variable, `unset`, `int / int` (see below), converting an array to a scalar | D4 |
| `$$name`, `${expr}`, `extract`/`compact`, `get_object_vars` & co., `call_user_func`, `Reflection*` | D6 |
| `?T`, a union, `mixed`, `iterable`, `callable`, `object`, `never`, `self`, `static`, assigning `null` | D9 |
| the `@` operator | D1 |

## Where a decision met reality

Four things this probe found that `docs/plan.md` § 3 should carry, because they are not
defects -- they are the design being applied.

1. **`int / int` has no static type.** `10/2` is `int(5)` in PHP and `7/2` is `float(3.5)`: the
   static type of `$a / $b` over two ints is `int|float`, which D4 (c) sends to a zval. T5 has no
   zval, so it refuses the operator and names `intdiv()`. This is the single most common refusal
   in ordinary code and it is D4 working exactly as written.
2. **An untyped parameter has no first assignment.** `function f($x)` is the commonest shape in
   the corpus and D4 gives it no type: its "first assignment" is the call site, which a
   whole-program compiler could read (D1 resolves every call) but which T5 does not. **53 of the
   first 200 refusals under `tests/lang` + `ext/standard/tests/strings` are this one.** It is the
   cheapest thing that would move the refused column back into green, and it belongs in the
   milestone that does type inference.
3. **An undefined variable has no type either.** PHP warns and yields null; D4 has nowhere to put
   it, so it is refused. 34 of the same 200.
4. **A php variable reused for two element types is a refusal, and that is right.**
   `foreach ($ints as $v) ... foreach ($strings as $v)` is valid PHP and D4 refuses the second.
   The probe's own `g/05-array.php` was written that way by accident and had to be corrected --
   which is the rule catching a real program, not a test artefact.

## The first ten greens

FIRST_TEN

## The first ten wrong, and why

This is T6's plan. The reason is the compiler's own first diagnostic on the test's `--FILE--`
section, or `(compiled; output differs)` when it built a binary that printed the wrong thing.

WRONG_TEN

The shape of the whole `wrong` set, over the WHY_N tests of the three named directories:

WHY_TABLE

**Only WHY_DIFFER of WHY_N compiled and then disagreed.** The rest refused or failed to compile,
which is the property worth keeping: a compiler that cannot do something says so.

## mc gaps

### Closed by mc 1.1.0, and measured here

* **`p_skip_to` closes three of T4's four.** `'...'`, `#` comments and `#[Attr]`, and the inline
  HTML between `?>` and `<?php` are all read and skipped by the module. **T4's in-place
  `on_source` rewrite is deleted**, and with it the `don't` -> `don"t` corruption it caused:
  `g/09-html.php` has an apostrophe inside its HTML and comes out byte for byte php's.
* **A fourth thing it closes that T4 did not ask for: `"..."`.** The module now owns the
  double-quoted string too, which is the only way to get php's own escape set
  (`\xNN`, `\u{...}`, octal) and an escaped `\$`. The core lexer decodes ITS escapes before any
  handler runs, so `\$` and `$` were the same byte by the time T4 saw them.
* **`syntax_expr("$", &f)` closes the fourth.** `$name` arrives as the `$` token plus the
  identifier, and `hole $name has no rule binding it` is gone.
* **The frozen surface is no longer a question.** T4 reported 29 of 46 `<mc/core>` names
  unfrozen. T5 calls **48** external names: **45 are in `tests/golden/surface.txt`** and the
  three that are not (`float_init`, `machine_arm64_float_init`, `machine_x86_64_float_init`) are
  `<float>`'s, which the freeze covers as a bundle name and not as symbols. Nothing to report.

### Open: there is no way to own the bytes BEFORE the first token

`p_skip_to` moves the cursor relative to a token that has already been lexed, so a `.php` whose
first bytes are inline HTML -- `Hello <?php echo 1;` -- is lexed as stray identifiers before any
handler can run. `on_source` sees the buffer and `source_claim` is asked at push time, but
neither can move the cursor. T5 refuses such a file by name (`ph_on_source` checks the first five
bytes) rather than mis-lexing it; **REFUSE_HTML tests in the whole corpus die on it**, and every
`.phpt` that closes with `?>` and trailing text is fine because that region hangs off a token.

The smallest additive fix, in `p_skip_to`'s own shape: let `on_source` return a byte offset at
which lexing should begin (0 = the whole buffer), or give `p_push_source` an offset argument.
Either is one parameter and changes nothing for a module that does not use it.

### A note, not a gap: `p_skip_to` is once per token

The guard is `cp == tok_start(cur) + tok_len(cur)`, which the first skip breaks -- so a handler
cannot skip twice before the next `p_next()`. The consequence for a module owning several
adjacent regions (whitespace, then a `#` comment, then a `'` string) is that the whole scan has
to decide ONE destination and call `p_skip_to` once, which is what `ph_next` does. It is a real
constraint and it is not written down in `docs/reference/hooks.md`.

And: the guard cannot hold for a `T_STR` token, because `lex_string` points `tok_start` into the
arena. A module that owns `'` but NOT `"` therefore cannot skip a region that follows a
double-quoted string. T5 does not hit it because it owns both.

## What T6 must do

In the order the numbers argue for.

1. **Objects.** `class` is REFUSE_CLASS of the first WHY_N `wrong` reasons, by a factor of four
   over the next thing. Nothing else in this list is close.
2. **An untyped parameter's type, from the call site.** § "Where a decision met reality" 2: the
   single cheapest move from `refused` to `green`.
3. **A zval, for exactly two things**: an array element (so an array can be heterogeneous and
   keyed, D4 (d)) and `int|float` (so `/` works). Both are refusals today and both are common.
4. **Exceptions** (`try`/`throw`/`catch`), `switch`, `match`, closures, `?:` and `??`.
5. **The rest of `ext/standard`.** The most-wanted names T5 does not have, measured over
   `ext/standard/tests/strings`: MOST_WANTED.
6. **PHP's diagnostics.** A large part of the corpus asserts a `Warning:`/`Deprecated:`/
   `Fatal error:` line with a file and a line number. A compiled binary has to produce those too.
7. **The float tail.** `php_fmt_f64` is right for `echo` (precision 14) and for `var_dump`
   (shortest round-trip) on FLOAT_OK of a 180-line sweep against `php`; the FLOAT_BAD that differ
   are all 16 or 17 significant digits, or an exponent past 1e±22, where the scaling by a power
   of ten stops being exact. The fix is a bignum, and it is a milestone of its own.

## Files

| file | what |
|---|---|
| `run.sh` | the fixtures, the refusals, the four grids, the "touched by none" intersection |
| `php.mc` | the compiler |
| `php_rt.txt` | the runtime, `#embed`ed and pushed with `p_push_source` |
| `mc-php.mc` | the compiler's entry point: `<mc/core>` + `<float>` + `php.mc` |
| `mcphp.sh` | executor B |
| `g/*.php` | the fixtures, each compared with `php` on every run |
| `r/*.php` | valid PHP that mc-php refuses by name |
| `out/` | the grid's per-category lists (gitignored) |

## D8

`docs/plan.md` D8 asks that every `.php` written in this repository carry a PHPUnit test that
runs in both worlds and a `bench/` row. **T5 writes no such `.php`**: everything under `g/` and
`r/` is a fixture -- the probe's own input, compared against `php` on every run, which is the
same gate a test would be. Nothing here is a part of the runtime or the standard library written
in PHP. When one exists, D8 applies to it.

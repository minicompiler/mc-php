# T4 -- does mc's Tier 3 take PHP's grammar?

Question (`docs/plan.md` § 4): does Tier 3 take PHP's grammar, and where exactly does it not.

Run: `sh probes/t4/run.sh`. Host: macOS 26 / arm64, mc 1.0.0, PHP 8.5.10 (Homebrew, NTS).

## Answer: the grammar yes, the LEXER no

Every construct this probe reached is a Tier 3 registration away -- **one** of them
(`syntax("<?php", &ph_program)`), because a handler that owns the whole grammar needs no other
word. What Tier 3 does not reach is the byte stream: the core lexes every source before any
handler runs, and four PHP constructs die or lie in that pass. Three mc gaps are reported in
`docs/plan.md` § 5, each with its reproducer here.

The instrument is `probes/t4/php.mc` (~700 lines) plus `probes/t4/php_rt.txt`, a runtime of 50
lines pushed with `#embed` + `p_push_source`. It is not a compiler and is not meant to become
one: i64 for `int`, a NUL-terminated byte string for `string`, one bump arena, one `write` per
`echo`. It exists so that each row below is a measurement.

---

## 1. The lexer

31 constructs, one per file under `lex/`, each read twice: by the stock `mc`, and by
`lexprobe.mc` -- a compiler whose `user_init` does nothing but `tok_add`. **10 of 31 die under
the stock lexer; `tok_add` alone fixes 6; 4 are the lexer's own.** The third column is the token
stream the second compiler then produces, because "it lexed" and "it lexed correctly" are not the
same row.

| construct | stock mc | + `tok_add` | what it then is | class |
|---|---|---|---|---|
| `<?php` / `?>` | `unexpected character` | ok | one token each | (a) `tok_add` |
| `?->` `??` `??=` | `unexpected character` | ok | one token each | (a) `tok_add` |
| `\Name\Space` | `unexpected character` | ok | `\ Name \ Space` | (a) `tok_add` |
| `->` `=>` `::` `...` `**` `<=>` `.=` `<>` | ok, but split | ok | one token each | (a) `tok_add` |
| `<<<EOT` | ok, but `<< <` | ok | `<<<`, then the BODY as mc tokens | (b) the body |
| `$name` | ok | ok | ONE `T_HOLE`, lexeme `$name` | (b) no registration reaches it |
| `"a $x {$y} \n"` | ok | ok | one `T_STR`, escapes already decoded | (a) re-scan |
| `// …` `/* … */` | ok | ok | skipped | ok |
| `0x1F` | ok | ok | `31` | ok |
| `0b101` `0o17` `1_000` | ok | ok | `0 b101` / `0 o17` / `1 _000` | (a) `p_cp` + `p_take_lit` |
| `1.5e3` | ok | ok | `1 . 5 e3` -- **silently a concatenation** | (a) detect, (b) to lex |
| `'x'` | ok | ok | `120` -- **silently a char literal** | (b) mc gap |
| `'single'`, `'it\'s'` | `unterminated char literal` | same | -- | (b) mc gap |
| `# comment`, `#[Attr]` | `unknown directive` | same | -- | (b) mc gap |
| `if while for return break continue` | ok | ok | `if`/`return`/`break`/`continue` are `K_*`, `while`/`for` are `T_IDENT` | ok |
| `function class echo foreach match fn use namespace new static public yield` | ok | ok | all `T_IDENT` | ok |

Class (a) is "a Tier 3 handler recovers it", and every (a) row above was recovered and run in
§ 3 -- the punctuation by `tok_add`, the four integer formats by scanning from `p_cp()` and
calling `p_take_lit()`, the interpolation by re-scanning the `T_STR`'s bytes.

Three things worth writing down:

* **`tok_add` takes a lexeme with letters in it.** `tok_add("<?php", 5)` is one token, and
  `syntax("<?php", &f)` fires on it (`word_add` refuses the core keyword range and nothing else).
  So *yes*, `syntax` works keyed on punctuation -- that is what this probe's single registration is.
* **`word_id` answers only for ALPHA-initial lexemes** (`te_word`, set from `is_alpha` of the first
  byte), so the id of `;` or `(` has to come from `tok_add`, which is idempotent. `examples/lang`
  does exactly this (`lg_tok_dot = tok_add(".", 1)`); `docs/reference/hooks.md` does not say it.
* **A PHP keyword that is also an mc core keyword never arrives as `T_IDENT`.** `if`, `else`,
  `return`, `break` and `continue` come as their `K_*` ids, so a module recognising PHP keywords
  by name must compare the LEXEME (`p_name()`), with `T_STR`/`T_CHAR`/`T_INT`/`T_HOLE` excluded so
  that the string `"return"` is not a keyword. `while` and `for` are not core -- they are `#rule`s
  from `<prelude>`, which a `.php` compilation never includes.

## 2. The entry

Five shapes measured. `source_claim` is asked **once per frame, at push time, before the first
token of that frame is lexed** -- which is what makes any of this possible.

| shape | what the core lexer sees first | `source_claim` fires? | usable? |
|---|---|---|---|
| (i) `mc --exe main.php` | the `.php` bytes | yes, before token 1 | yes |
| (i') `mc build`, `[project].entry = "main.php"` + `[compiler] modules = ["php.mc"]` | the same | yes | **yes -- measured end to end**, `build/t4` agrees with `php` |
| (ii) a `.mc` stub with `#include "main.php"` | the stub | yes, when the core resolves the include | yes |
| (iii) `p_push_source` of a rewritten entry from `user_init` | the pushed text, **then the original** | yes, for both | **no**: `main` is declared twice |
| (iv) rewriting the entry IN PLACE inside the `on_source` callback | the rewritten bytes | n/a | yes -- and this is the workaround § 5 rests on |

(i') is the shape mc-php would ship and it needs nothing special: `mc build` does not look at the
extension.

(iii) is the one that does not work and the measurement is the reason: `lex_init` has already
pushed the entry when `user_init` runs, so a push there adds a frame *above* it and the original
is parsed when the pushed one is exhausted (`--dump-ast` shows `main` twice).

(iv) is what is left. `on_source` hands over `src`/`len` -- the buffer the lexer is about to read --
and mutating it before the first token is lexed reaches the lexer (measured: `'hello'` rewritten to
`"hello"` lexes as a string). `docs/reference/hooks.md` describes `on_source` as an announcement and
says only "reading is unrestricted"; writing is undocumented, and its cost is in § 5.

**`$name` is a `T_HOLE` and no registration reaches it.** `syntax_expr("$", &f)` does not fire:
`$name` is lexed as a hole, and outside a `#rule` template that is
`hole $name has no rule binding it` (`dollar/`). A handler that owns its position can read it
(`p_id() == T_HOLE`, `p_name()` is `"$x"`) -- so a module that wants `$x` inside an expression has
to own the **whole expression grammar**, which is what `php.mc` does.

## 3. The grammar

`php.mc`: `tok_add` for the punctuation, `on_source` for the two bytes of § 5, `source_claim` for
`.php`, and **one** `syntax("<?php", &ph_program)`. Every PHP keyword stays an ordinary
identifier, matched by `str_eq` -- a registration reserves its word for the whole program and PHP
has about seventy of them. The expression parser is the module's own (PHP's precedence is not
mc's, and `$x` could not reach `parse_primary` anyway).

| step | fixture | result |
|---|---|---|
| `<?php echo 1 + 2;` | `g/01-echo.php` | ran, php agrees: `3` |
| `$x = 1 + 2; echo $x;` | `g/02-assign.php` | ran, php agrees: `3` |
| **D4**: a second assignment of another type | `g/03-d4-retype.php` | refused: `a php variable has one type: $a was string, assigned int` |
| `function f(int $a, int $b): int` | `g/04-function.php` | ran, php agrees: `42` |
| `if` / `while` / `for` / `foreach` over a literal array | `g/05-control.php` | ran, php agrees |
| `echo "x=$x s=$s done\n"` | `g/06-interp.php` | ran, php agrees |
| `class` with properties and a method | `g/07-class.php` | parsed; offsets `0,8`, `Point_SIZE` 16, method `Point_sum(uptr v_this)`. No php oracle: those are compile-time constants, not PHP |
| **D5**: `require` / `require_once`, literal path | `g/08-require.php` | ran, php agrees: `42` |
| **D1**: `eval('1')` | `g/09-eval.php` | refused: `eval is refused: a binary has no interpreter` |
| `1.5` | `g/10-float.php` | refused by name (before the scan it compiled to `php_concat(1, 5)`) |
| `0b101 0o17 1_000 0x1F` | `g/11-numbers.php` | ran, php agrees: `5,15,1000,31` |
| `'single'` | `g/12-singlequote.php` | ran, php agrees -- through the § 5 rewrite |
| `# comment` | `g/13-hash.php` | ran, php agrees -- through the § 5 rewrite |
| inline HTML after `?>` | `g/14-inline-html.php` | **refused**: there is no way to skip raw bytes |

### D4, the rule this probe was asked to prove

A variable's type is its first assignment's and never changes; the module keeps
`(name, type, where)` per variable, emits an `N_VAR` for the first assignment and an `N_ASSIGN`
for every later one, and a type change is `err_at2` at the offending line. `g/03-d4-retype.php` is
valid PHP that `php` runs; mc-php refuses it, which is D4's own "green / wrong / refused-by-design"
third column.

### Where Tier 3 stops, and why

* **Raw-text regions.** Inline HTML between `?>` and `<?php`, and a heredoc body, are bytes PHP
  does not lex. Tier 3 can *read* them (`p_cp()` is the cursor, `p_src_end()` the end) but cannot
  *skip* them: `p_take_lit` only extends a NUMERIC token and `p_resplit_punct` only rewinds. This
  is gap 3 in `docs/plan.md` § 5.
* **`float`.** Detecting `1.5` is a `p_cp()` scan (done); representing it needs a float type, which
  is M24's `<float>` and not a grammar question.
* **`new` / `->` / `$obj->m()` / `match` / closures / generators / `??`** are *not measured here* and
  are not blocked by anything above -- `examples/lang` builds classes with vtables out of the same
  hooks. They were left out because T4 asks where Tier 3 STOPS, and none of them is a candidate.
* **`$$name`, `new $class`, a computed `include`, `Reflection*`** are refused by D1/D6, not by mc.

### What a Tier 3 module of this size actually depends on

`php.mc` calls **46 names** from `<mc/core>` (the `ld8`/`st8`/`ld64`/`st64` intrinsics excluded --
they are the language, not the library). **17 are in `tests/golden/surface.txt` and 29 are not**, so
`make check-freeze` does not protect those 29 -- including **16** that
`docs/reference/hooks.md` § 4 calls "the parser's public API. Fixed names": `parse_expr`,
`parse_stmt`, `parse_block`, `parse_params`, `parse_function`, `top_add`, `def_add`, `param_new`,
`list_append`, plus `lex_set_libs`, `lex_root_of` and the four `lex_root_*`/`lex_inc_*` readers
(the 17 frozen ones are `syntax`, `source_claim`, `on_source` and fourteen `p_*`). Reported in
`docs/plan.md` § 5 as a surface-coverage question, not a defect.

## Files

| file | what |
|---|---|
| `run.sh` | the three tables; exits 0 only when every measurement ran and every oracle agreed |
| `lex/*.php` | 31 one-construct fixtures |
| `lexprobe.mc` | a compiler whose `user_init` is nothing but `tok_add` |
| `entry/` | the five entry shapes, one module each |
| `dollar/` | the `syntax_expr("$")` measurement |
| `php.mc`, `php_rt.txt`, `mc.toml`, `main.php` | the grammar instrument and the `mc build` shape |
| `g/*.php` | the 14 grammar steps |

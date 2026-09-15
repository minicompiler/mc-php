# mc-php: the plan

## 1. What it is

A compiler taught to mc (Tier 3: `source_claim` for `.php`, `syntax*` hooks, the `$` token mc
already lexes as a claimable surface token) that turns a PHP 8.5 program into one native binary,
plus the runtime that binary links: the Zend semantics -- zval, `zend_string`, the ordered hash
array, objects with handlers, refcounting/GC, exceptions, closures, generators, references -- and
the internal functions and classes (php 8.5.10 NTS measured: 2143 internal functions, 544 of them
in `ext/standard`; 300 classes; 27 interfaces; 66 extensions built in).

PHP is dynamic, so the first compiler is AOT over a dynamic runtime: it emits calls into the zval
runtime, not typed native code. Type inference and native lowering are an optimization phase that
comes after the `.phpt` corpus is green.

## 2. The oracle

php-src's `.phpt` tests (~17k). A runner executes each test under `php` and under the mc-php
build and compares stdout/exit. The number that matters is "N of M green" and it is printed on
every run. Nothing is claimed compatible that this grid does not show.

## 3. Decisions to take before code (with the measurement that decides each)

D1. DECIDED (owner, 2026-09-15): there is no interpreter. A binary is whole-program -- every
    `include`/`require` is resolved at compile time (the closure of the entry, literal paths only)
    -- and `eval`, `create_function`, an `include` of a computed path, `$$name` and any call whose
    target is a run-time string that cannot be resolved at compile time are REFUSED with a named
    compile error, one per construct, listed in `docs/refused.md` (not written yet: T4 measured
    the mechanism -- `eval('1')` is refused at its own line with a named error,
    `probes/t4/g/09-eval.php` -- and the list belongs with the compiler, not with a probe). T0's
    corpus breakdown reports how many `.phpt` fall in that class, as a number, not as a claim.

D4. DECIDED (owner, 2026-09-15): variables have a STATIC type. A variable's type is its declared
    type or the type of its first assignment, and it never changes: `$a = "1"; $a = 10;` is a
    compile error naming the variable and both types. Consequences: (a) mc-php accepts a SUBSET of
    PHP -- every program it compiles runs unchanged under `php`, not the reverse; (b) a typed local
    is a native value, not a zval, so the first optimization is free; (c) `mixed` and union types
    exist only where PHP itself declares them (parameters, returns, properties) and a variable of
    such a type is a zval; (d) arrays stay heterogeneous inside (elements are zvals) -- the static
    type is the container's; (e) `null` needs a declared `?T` or a union, never an implicit one.
    The `.phpt` grid gains a third column: green / wrong / refused-by-design.

D2. Extensions. Two classes, two answers. **Decided by T1/T2/T3 (2026-09-15, macos/aarch64;
    `probes/`). D2(b) is taken: the shim is real, it is small, and it works.**
    (a) The engine, `ext/standard` and everything the distribution compiles in are not loadable:
        they ARE PHP and must be written in mc. Measured: `ext/json` cannot even be built shared by
        `phpize` in PHP 8, which is the same statement from the other side.
    (b) Third-party `.so` (pecl, pdo_*, gd, intl...) are reused through a Zend-ABI shim, and the
        three probes say what that costs.

        - **T1 -- the size.** **169 symbols**: 157 functions + 12 data globals, the union over
          `ctype`, `pdo_sqlite` and `mbstring`. `ctype` alone needs **7 functions and no data
          global at all**, because since PHP 7 the fast ZPP macros are expanded inline in the
          header and the string path of an internal function calls nothing. The union grows with
          each extension added -- 169 bounds the SHAPE (a few hundred entry points, a quarter of
          them allocator and array helpers), not "all of pecl".
        - **T2 -- the mechanics.** A `.so` built exactly as a php extension resolves symbols an mc
          binary defines, on every link road including `mc --exe`; `-export_dynamic` is an ELF
          habit and is not needed on macOS. A function written in mc can be the callee of a
          variadic C call with **no mc change**: on Apple arm64 every variadic argument is passed
          on the stack at `[sp + 8*n]`, and an mc callee reads parameter 9 at `[x29 + 16]`, which
          IS the caller's `sp`. So variadic argument N is mc parameter 8 + N, capped at **4**
          (`MAXPARAMS` 12, one spent on the format). `zend_parse_parameters` therefore reaches
          `execute_data` + a format + 3 pointers before the cap bites; past that the answer is to
          walk the stack by hand (`ld64(x29 + 16 + 8*n)`), which needs nothing from mc either.
        - **T3 -- the proof.** php-src's own `ctype.so` runs `ctype_digit` on a `zend_execute_data`
          and a `zval` laid out by mc, and `php` agrees on all five inputs; the extension calls
          back into `php_error_docref` **variadically** and reads the right argument. 39 layout
          facts (`zval` 16 B, `zend_string.val` at 24, `ZEND_CALL_ARG(ex,n)` at `ex + 80 + 16*(n-1)`,
          `zend_function_entry` **48** B since 8.4, ...) are checked against the installed headers
          with `offsetof`/`sizeof` on every run.

        What the probes did NOT measure, and what D2(b) is therefore still open on: refcounting,
        `HashTable`, `zend_object` + handlers, exceptions, the allocator -- `pdo_sqlite`'s 73
        imports are the next order of magnitude. And every number here is macos/aarch64; the ELF
        and PE hosts need their own run of `probes/t2/run.sh`.

D5. DECIDED (owner, 2026-09-15), and **measured by T4** (`probes/t4/g/08-require.php`: `require`
    then `require_once` of the same file, the program agrees with `php`). One thing the probe had
    to learn: mc's own `lex_include` does the includer-relative resolution AND the once-only list,
    but it is UNCONDITIONALLY once-only and its list is not the one a `p_push_source` enters, so a
    module cannot use `lex_include` for `_once` and `p_push_source` for the plain form -- the
    second splice then declares everything twice. All four spellings go through one road,
    `path_norm(path_join(includer, rel))` + `read_file` + `p_push_source`, with the once-list the
    module's own. `require`/`require_once`/`include`/`include_once` are sugar over
    mc's `#include` semantics -- the Tier 3 handler resolves the LITERAL path against the including
    file and pushes the source with `p_push_source` (M21: a textual splice at that point, in the
    includer's scope, errors attributed to the included file). All four are compile-time; the one
    distinction kept is `_once`, by normalized path (PHP's own realpath rule). A missing file is a
    compile error in all four (a binary has no "warn and continue"). `$x = include 'f.php';` where
    `f.php` is a single top-level `return EXPR;` splices the expression; an expression-position
    include whose file also runs statements is refused. Declarations (functions, classes) found in
    an included file are hoisted to the program; an include that is conditional or inside a loop
    and carries declarations is refused. A computed path is refused (D1). The real-world case,
    Composer's `spl_autoload_register` + `include $file`, is resolved STATICALLY: the compiler reads
    `vendor/composer/autoload_classmap.php` / the PSR-4 map (literal arrays) and includes the file
    when the class is first referenced -- autoload becomes compile-time resolution.

D6. DECIDED (owner, 2026-09-15): no reflection. A binary carries no run-time type tables, so
    every `Reflection*` class is refused, and with it what needs those tables at run time:
    `get_class_methods`, `get_object_vars`, `get_class_vars`, `property_exists`/`method_exists`
    with a non-literal name, `$obj->$prop`, `$obj->$method()`, `new $class`, `$class::$member`,
    a callable spelled as a string (`'Foo::bar'`, `[$o, 'm']` with a dynamic string),
    `func_get_args` (`...$args` stays), `debug_backtrace`. Attributes `#[Attr]` are accepted by
    the grammar and inert (only reflection read them). KEPT, because it is dispatch and not
    introspection: `__get`/`__set`/`__call`/`__callStatic`/`__invoke`, `instanceof` with a
    literal, `get_class($o)`, `$o::class`, typed closures/callables, `is_callable(Closure)`.
    ANSWERED AT COMPILE TIME when the argument is a literal: `class_exists('Foo')`,
    `method_exists($o, 'm')`, `function_exists('f')` fold to constants. Declared cost: frameworks
    built on reflection-driven DI containers (Laravel, Symfony) are out of scope; the target is
    programs and libraries that do not introspect.

D7. DECIDED (owner, 2026-09-15): no VM and no GC -- "teko already proves automatic arenas work".
    Execution is AOT only (D1 already removed the interpreter). Memory is arenas: Zend's own
    `emalloc` is a per-request allocator reset at request end, so the web shape is one arena per
    request (with the fork-per-connection server the child's exit IS the release), and the CLI
    shape is automatic per-scope arenas in teko's rule (what escapes a scope is copied up). There
    is no refcount-driven free and no cycle collector. Consequence for D2b: the refcount fields
    stay in the layouts (extensions read/write `GC_REFCOUNT` inline), and `zval_ptr_dtor`,
    `zend_string_release`, `_efree` and friends are arena-aware no-ops -- T3 measures that a real
    extension runs on it. The risk is measured, not assumed: a long loop that allocates (string
    concatenation in `while`) grows until its scope ends, so T5 gains a column, peak RSS against
    `php` on the same `.phpt`.

D8. DECIDED (owner, 2026-09-15): every `.php` written in this repository -- fixtures, any part of
    the runtime or standard library written in PHP, examples -- carries TESTS that run in BOTH
    worlds and BENCHMARKS between them. (a) Tests are PHPUnit test classes (`PHPUnit\Framework\
    TestCase`, `assertSame` & co.) run under `php` with the real phpunit; the SAME files run under
    mc-php through `mc-php test`, where a tiny `TestCase` shim provides the assertions and the
    compiler discovers `test*` methods at COMPILE time (D6: no reflection -- phpunit's own runner
    cannot run on mc-php, so discovery is the compiler's job and the generated `main` calls each
    test). Green in both is the gate; a test that passes in one world and not the other is a bug
    named by the test. (b) Benchmarks: `bench/` holds programs timed under `php` (version, opcache
    and JIT settings recorded as the tool prints them) and as an mc-php binary, in the shape of
    mc's bench cell (interleaved repetitions, medians, a committed dated `results.json`); the
    number reported is `php / mc-php` per program, and it is printed on every run, never claimed
    from memory. Nothing written in PHP lands without its test in both worlds and its row in the
    bench table.

D9. DECIDED (owner, 2026-09-15): the TYPE SYSTEM is PHP's, in full -- the manual's own list
    (`null`, `bool`, `int`, `float`, `string` and numeric strings, `array`, `object`, enums,
    resources, `callable`, `mixed`, `void`, `never`, `self`/`parent`/`static`, `?T`, unions
    (`int|string`), intersections (`A&B`) and DNF, `iterable`, the `true`/`false`/`null` singletons,
    type declarations on parameters/returns/properties/constants, and PHP's juggling and
    coercion rules, strict_types included). A `.php` file spells PHP types and nothing else.
    mc's types are the LOWERING behind them, never the surface: `int` -> `i64`, `float` -> `f64`
    (`<float>`), `bool` -> `u8` with the two values, `string` -> a `zend_string`-shaped handle
    (`uptr`), `array` -> the ordered-hash handle, an object -> its handle, `callable` -> a closure
    record, `mixed`/a union/`?T` -> a zval (D4 (c)); `null` is a value of `?T`/unions only. T4's
    probe mapped three names and refused `float`; that was a measurement, not the design.
    The owner allows the mc names to stay ACCEPTED by the compiler as a lowering hint, but a
    `.php` that uses one no longer runs unchanged under `php` (there `i64 $x` is a class type),
    so it cannot pass D8's php side and is out of every gate -- an escape hatch for probes only.

D10. DECIDED (owner, 2026-09-15): the lowering table, PHP -> mc.

    | PHP | mc | notes |
    |---|---|---|
    | `bool` | `u8`, the two values 0 and 1 | |
    | `int` | `i64` | PHP_INT_MAX/MIN are i64's; overflow to float is PHP's rule, implemented |
    | `float` | `f64` (`<float>`) | |
    | `string` | a NEW type: `len` as `i64` + the bytes, immutable | PHP strings are BINARY-SAFE byte sequences: `strlen("\xc3\xa9") == 2`, binary data travels in `string`, and the `.phpt` corpus asserts exactly that -- so the type stores bytes and never validates encoding; UTF-8 is the content convention `mb_*` interprets, not a property of the type. Immutable value: a write is a new string (PHP's copy-on-write, arena-friendly, D7). Laid out like `zend_string` (refcount, hash, len, val) so D2(b)'s shim gets it for free |
    | the rest | developed one by one | `array` (ordered hash), objects, enums, `callable`, `iterable`, `mixed`/unions/`?T` (a zval), resources, each with its own `.phpt` slice and its bench row |

D3. Web shape. The runtime ships an HTTP server (the `mc-forkka` fork-per-connection shape from
    mc's bench) that fills the superglobals; no CGI/FCGI, no `url/file.php`. Later.

## 4. The test grid (probes, before the compiler)

| id | question | measured how | exit number |
|---|---|---|---|
| T0 | how far is 0 from N | php-src cloned, `probes/t0/phpt-run.py` runs `php` and `mc-php` | green/total -- phpt: green 0 / wrong 18109 / refused 0 / skip 2947 / php-fail 339 / total 21056  (21395 tests; sapi/ excluded) (`probes/t0`) |
| T1 | how big is the Zend shim | `phpize` on `ext/ctype` and `ext/pdo_sqlite`, `nm -u` on the `.so` | imported symbols per `.so` -- **measured: 169** (`probes/t1`) |
| T2 | can an mc binary export a symbol to a `.so` and take a variadic call | `[linker]` with `-export_dynamic`, `dlopen`, a callback; a C caller of a variadic mc callee | yes/no per host -- **macos/aarch64: yes, yes** (`probes/t2`) |
| T3 | does a real extension run on our zval | zval/`zend_string`/HashTable at `zend_types.h` offsets in mc, `ctype_digit` from `ctype.so` | yes/no -- **yes** (`probes/t3`) |
| T4 | does Tier 3 take PHP's grammar | lexer/parser for `<?php echo 1+2;`, functions, arrays, strings -> `--dump-ast` | gaps list -- **grammar yes, lexer no** (`probes/t4`) |
| T5 | does the runtime agree with php | zval, ordered array, string, refcount; first ~100 `.phpt` of `Zend/tests` + `ext/standard/tests/strings` | green/total |

Gate for the compiler proper: T2 + T3 decide `.so` reuse (D2b); T4 decides that the grammar fits
Tier 3 with no mc change. Nothing in this grid touches mc's `src/`.

T1, T2, T3 and T4 are done (2026-09-15, macos/aarch64): see `probes/README.md` for the numbers and
`probes/tN/RESULTS.md` for each. **D2(b) is taken.** T4 answers its own gate: the grammar fits
Tier 3 with no mc change -- 14 grammar steps, 10 of them byte for byte what `php` prints -- and
the LEXER does not, which is the gap above.

T0 is done (2026-09-15, macos/aarch64; `probes/t0/RESULTS.md`): every `.phpt` under php-src run
through `php` and through a placeholder executor B that does not implement a compiler yet
(`probes/t0/mcphp-stub.sh`, exits 99, matches nothing) -- phpt: green 0 / wrong 18109 / refused 0 / skip 2947 / php-fail 339 / total 21056  (21395 tests; sapi/ excluded). The number that will move
once mc-php exists is `green`. Also: the corpus breakdown -- how much of it the decisions above
actually touch, with the real tokenizer, not a regex -- 21560 classifiable tests; D1 143 (0.7%), D5 1569 (7.3%), D6 1719 (8.0%), D4-suspect 123 (0.6%); touched by at least one 3409 (15.8%), by none 18151 (84.2%); extension-specific 9028, of which 1899 touched. Cross-checked
against php-src's own `run-tests.php` over `Zend/tests` and `ext/standard/tests/strings`, which
reconciles to the byte once three bugs this cross-check found in the harness itself were fixed
(a stray `--` corrupting `--ARGS--`, `--INI--` leaking a space around `=`, and a hardcoded
`error_reporting` value that was not this PHP build's actual `E_ALL`). T5 is not run.

## 5. What mc may need (reported, not worked around)

### Open: a module cannot own the LEXING of a source it claims (macos/aarch64)

Found by T4, reduced to `probes/gap-lexer-ownership/` (`sh probes/gap-lexer-ownership/run.sh`,
exits 0 only while it still reproduces). Measured on mc 1.0.0.

`source_claim` says a source belongs to a module and the six word registrations then apply to it,
but the core lexes every source **before any handler runs** and keeps four things for itself. The
reproducer registers `source_claim` returning 1 for every source and `tok_add`s every lexeme PHP
needs -- the whole of what the surface offers -- and still gets:

```
a-single-quote.php   $a = 'a php string';   -> a-single-quote.php:2: unterminated char literal
b-single-char.php    $a = 'x';              -> 2 3 120      (T_CHAR: silently the integer 120)
c-hash.php           # a php line comment   -> c-hash.php:2: unknown directive
d-attribute.php      #[Attr]                -> d-attribute.php:2: unknown directive
f-rawtext.php        ?> <p>don't</p> <?php  -> f-rawtext.php:2: unterminated char literal
e-dollar.php         return $name;          -> hole $name has no rule binding it
```

Four separate things, in decreasing order of how much they cost:

1. **`'`** is the char-literal rule. `tok_add("'", 1)` does not beat it. A PHP single-quoted string
   of one character is silently an integer; of any other length it is `unterminated char literal`.
2. **`#`** is a directive, and there is no `directive(name, &f)` registration. `#[Attr]` is the
   same byte.
3. **A region of raw bytes cannot be skipped.** Inline HTML between `?>` and `<?php`, and a heredoc
   body, are text PHP does not lex. A handler can READ them -- `p_cp()` is the cursor and
   `p_src_end()` the end, and T4 uses both to lex `0b101`/`0o17`/`1_000` correctly -- but it cannot
   ADVANCE past them: `p_take_lit(q)` only extends a NUMERIC token and `p_resplit_punct(n)` only
   rewinds.
4. **`$name` is a `T_HOLE` and no registration reaches it.** `docs/reference/hooks.md`
   § `syntax_expr` says `$` is claimable, and it is -- for `$"..."`. `$name` is lexed as a hole and
   a registered `syntax_expr("$", &f)` does not fire for it; outside a `#rule` template that is
   `hole $name has no rule binding it`. A handler that owns its grammar position can still read it
   (`p_id() == T_HOLE`, `p_name()` is `"$x"`), so the cost is that a module wanting `$x` inside an
   expression has to own the WHOLE expression grammar. For mc-php that is going to happen anyway
   (PHP's precedence table is not mc's), so this is a cost and not a blocker.

**The workaround T4 used, and what it costs.** `on_source` hands the module `src`/`len` -- the
buffer the lexer is about to read -- and mutating it in place inside the callback reaches the
lexer (measured: `'hello'` rewritten to `"hello"` lexes as a string; `probes/t4/entry/inplace.mc`).
`probes/t4/php.mc` rewrites `'` to `"` and `#` to `//` that way, which is what makes
`g/12-singlequote.php` and `g/13-hash.php` agree with `php`. Two costs, both measured: the rewrite
must be byte for byte or every `err_at` column moves, and it is made by something that does not
know PHP's lexical states -- in `probes/t4/g/14-inline-html.php` it turned `don't` inside an HTML
fragment into `don"t`. `docs/reference/hooks.md` describes `on_source` as an announcement and
documents only that "reading is unrestricted"; writing is undocumented behaviour this repository
is relying on.

**The smallest additive fix, and it is one function.** `void p_skip_to(uptr q)`: move the lexer
cursor of the source being lexed to `q`, under `p_take_lit`'s own guard (`q` at or after `p_cp()`,
not past `p_src_end()`, and only on a token just lexed from the source being read). That is the
generalisation of `p_take_lit`, which already proves the mechanism is sound -- T4 calls it from a
handler that never reaches `parse_primary` and the four PHP integer formats come out agreeing with
`php`. With it, items 1, 2 and 3 all go away: the module's own expression parser, standing on `=`
and seeing `ld8(p_cp()) == '\''`, scans to the closing quote, builds its own `N_STR` and skips the
region. It does not address item 4, whose fix is separate and also one `if`: when a
`syntax_expr("$", &f)` is registered, a `$` outside a `#rule` template lexes as the one-character
`$` instead of as a hole (outside a template a hole is already an error, so nothing an untaught
compiler does can change).

The alternative shape, `syntax_source(&f)` -- `on_source` with a return value, a replacement
buffer, called from `lex_push_mem` before the frame is read -- would make the in-place mutation an
explicit contract instead of an undocumented side effect, but it is strictly weaker: a whole-buffer
rewrite still cannot know PHP's lexical states, which is exactly the `don"t` above.

### Open: 29 of the 46 `<mc/core>` names a Tier 3 module of this size needs are not frozen

Measured by T4 over `probes/t4/php.mc` (`docs/reference/hooks.md` § 8 is the promise,
`tests/golden/surface.txt` is what `make check-freeze` enforces). 17 of the 46 are in the frozen
list -- `syntax`, `source_claim`, `on_source` and fourteen `p_*`. The other 29 are not, and **16 of
them are named in `docs/reference/hooks.md` § 4 as "the parser's public API. Fixed names"**:
`parse_expr`, `parse_stmt`, `parse_block`, `parse_params`, `parse_function`, `top_add`, `def_add`,
`param_new`, `list_append`, `lex_set_libs`, `lex_root_of`, `lex_root_count`, `lex_root_name`,
`lex_root_dir`, `lex_inc_count`, `lex_inc_at`. The remaining 13 are `<mc/core>` facilities a taught
compiler cannot avoid: `node_new`, the `nd_*`/`set_nd_*` accessors, `tok_add`, `word_id`,
`def_find`/`de_at`/`de_val`, `path_join`/`path_norm`, `read_file`, `xalloc`, `xstrdup`, `str_eq`,
`cstrlen`, `err_at`/`err_at2`.

Not a defect and nothing is worked around: it is a coverage question for
`scripts/surface-extract.sh`'s prefix list, and mc-php would like to know which of the 29 it may
depend on for 1.x.

### Settled by T4

- "does `syntax` work keyed on a PUNCTUATION token" -- **yes**. `tok_add("<?php", 5)` is one token
  even though it contains letters, and `syntax("<?php", &f)` fires on it; `word_add` refuses the
  core keyword range and nothing else. T4's whole grammar hangs off that one registration.
- `word_id` answers only for ALPHA-initial lexemes (`te_word`, from `is_alpha` of the first byte),
  so the id of `;` or `(` has to come from `tok_add`, which is idempotent.
  `docs/reference/hooks.md` does not say this; `examples/lang` does it (`tok_add(".", 1)`).
- A `p_push_source` from `user_init` does not replace the entry: `lex_init` has already pushed it,
  so the pushed text is parsed and then the original is too (`main` declared twice, measured).

### Open: `mc --exe` loses its exports once `__bss` reaches one page (macos/aarch64)

Found by T3, reduced to `probes/gap-bss-exports/` (`sh probes/gap-bss-exports/run.sh`, exits 0 only
while it still reproduces). Measured on mc 1.0.0, macOS 26 / arm64:

```
bss=8192  __DATA vmsize=16384 filesize=16384 | __LINKEDIT vmoff=32768 fileoff=32768 -> 42
bss=16000 __DATA vmsize=16384 filesize=16384 | __LINKEDIT vmoff=32768 fileoff=32768 -> 42
bss=16384 __DATA vmsize=32768 filesize=16384 | __LINKEDIT vmoff=49152 fileoff=32768 -> FAIL ... symbol not found in flat namespace '_mc_answer'
bss=65536 __DATA vmsize=81920 filesize=16384 | __LINKEDIT vmoff=98304 fileoff=32768 -> FAIL ...
```

An `mc --exe` Mach-O executable carries no `LC_DYLD_EXPORTS_TRIE` (`export_size 0`), so dyld
resolves a `dlopen`ed bundle's flat-namespace imports out of the classic symbol table
(`LC_SYMTAB` delimited by `LC_DYSYMTAB.iextdefsym`/`nextdefsym`). That works -- T2 proves it, and
patching `nextdefsym` to 0 turns the same binary into `symbol not found in flat namespace`, which
is what identifies the table. It stops working when `__bss` makes `__DATA`'s vmsize exceed its
filesize by a whole 16 KiB page: `__LINKEDIT`'s offset from the mach header **in memory**
(`vmaddr - __TEXT.vmaddr`) then diverges from its offset **in the file** (`fileoff`), the symbol
table is read out of `__DATA`'s zerofill instead, and every symbol the binary exports becomes
invisible. The binary still runs correctly -- only `dlopen` is affected. The control: 16384 bytes of
**initialized** data instead of `__bss` keeps the two offsets equal and works.

Two independent fixes, either one enough, both additive (a MINOR on mc's frozen surface):

1. pad the file so `__LINKEDIT.fileoff` equals its offset in memory (what a zerofill-heavy segment
   costs is one page of zeros in the file), or
2. write an `LC_DYLD_EXPORTS_TRIE`, which makes the symbol-table road moot. `ld` takes road 2,
   which is why the `[linker]` road is immune.

Nothing here is worked around: T3 uses the `[linker]` road and says so. This matters to mc itself
beyond mc-php -- mc's own compiler carries a 32 MiB `heap[]` in `__bss`, so *any* mc binary with an
arena is already past the threshold, and is not usable as a `dlopen` host today.

### Settled by T2, correcting what this section said before

- "`mc --exe` writes imports only ... Mach-O has no export trie" -- the second half is true and
  **does not matter**: dyld falls back to the classic symbol table, and mc fills it correctly (see
  above for the one case where it goes wrong). `mc --exe` is a usable `dlopen` host on macOS.
- "the `[linker]` road with `-export_dynamic` does it today" -- `-export_dynamic` changes nothing on
  macOS; the same link without it behaves identically. It is an ELF habit.
- "a variadic callee in mc" -- **no mc change needed** on Apple arm64. Variadic argument N is mc
  parameter 8 + N, so four of them are reachable directly and any number by walking
  `ld64(x29 + 16 + 8*n)` by hand. SysV passes the first eight variadic arguments in registers
  instead, so on Linux the natural shape is different again and needs its own probe -- neither is
  an mc gap.

### Still unmeasured

- The ELF half of everything above: `probes/t2/run.sh` has never run on Linux.
- Windows/PE: not applicable yet.

## 6. After the corpus is green

Native lowering behind type inference, the web server, multithreading, async. Not before.

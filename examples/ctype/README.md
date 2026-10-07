# ctype — php-src's `ext/ctype`, ported to PHP and compiled by mc-php

`php-src/ext/ctype/ctype.c` is eleven character-class predicates — `ctype_alnum`
… `ctype_xdigit`, each `(mixed): bool`. This is that extension rewritten in
typed PHP and compiled by mc-php into a loadable `ctype.so`, graded byte for
byte against php's own ctype.

```
mc-php build examples/ctype --config examples/ctype/mcphp.toml
php -d extension=examples/ctype/build/ctype.so examples/ctype/check.php
```

`sh tests/examples.sh` builds it, grades `check.php` against `check.expect`,
checks the published surface, and prints the bench row.

## Why `cty_*` and not `ctype_*`

ctype is **compiled in** to the php this is graded on — not a loadable `.so`,
so `php -n` still has it and there is no `ctype.so` on disk — and php refuses to
redeclare an internal function (`Cannot redeclare ctype_alnum()`). So the port
publishes **`cty_alnum` … `cty_xdigit`** and `check.php` compares each `cty_X`
against the built-in `ctype_X` **in the same process**. The built-in ctype *is*
the reference here, so there is no C twin and no oracle — ctype.so is the twin.

## The semantics, measured, not assumed

The grading reference is the host's own `ctype_*`; the port reproduces
`ext/ctype/ctype.c` exactly. Every rule below was read from that source and
verified against the host extension before it was trusted (php 8.5.10).

- **A string**: non-empty AND every byte passes the C `is*()` predicate. The
  empty string is **false**.
- **An int** — ctype.c's fallback, by range (`Z_LVAL`):
  - `0 … 255` → that byte: `isX(n)`.
  - `-128 … -1` → that byte **+ 256**: `isX(n + 256)`. So `ctype_alpha(-1)` is
    `isalpha(255)`.
  - `> 255` → the per-function constant `allow_digits`.
  - `< -128` → the per-function constant `allow_minus`.

  So the famous cases hold: `ctype_digit(48)` is **true** (48 is in range and is
  the code for `'0'`), `ctype_digit(1)` is **false** (code 1 is not a digit),
  `ctype_alpha(65)` is **true** (`'A'`), `ctype_digit(256)` is **true**
  (`allow_digits` for `digit` is 1), and `ctype_alnum(-129)` is **false** while
  `ctype_graph(-129)` is **true** (`allow_minus` is 1 only for `graph`/`print`).
  The out-of-range int is **not** re-read as its decimal string — that is an old
  description; the modern source returns the two constants. The eleven
  `(allow_digits, allow_minus)` pairs in `ctype.php` are ctype.c's verbatim.
- **Anything else** (float, bool, null, array): **false**.
- php 8.5 also emits `E_DEPRECATED` "Argument of type int will be interpreted as
  string in the future" for every non-string argument. That is a transitional
  notice about a future php, not a return-value difference; the port reproduces
  the 8.5 **return** semantics, and `check.php`/`bench.php` run with
  `E_DEPRECATED` off. It is not replicated.

## The per-byte predicate is libc's, exactly as ctype.c's is

`ctype.c` delegates each byte to `<ctype.h>`'s `isalnum()` etc. This port
declares those with `#[Extern('c', name: 'isalnum')]` and calls them: the symbol
`isalnum` is **exported** by libSystem (and by glibc) and resolves from php's
own process at load, like db's `sqlite3_*`. The exported function is the same
classification `ctype.c` inlines, so the module agrees with php's ctype on all
256 bytes — **including 128…255**, whose answers come from the host's locale
tables — on whatever libc the host runs, with **no hardcoded locale table** in
the PHP. The int-argument quirk is written in the PHP; the byte test is libc's.

## The differential

`check.php` runs **3322** comparisons — every one of the 256 byte values as a
one-character string, the empty string, all-pass and one-fail multi-character
strings, an embedded NUL, ints across and outside the `-128…255` window
(`0, 1, 47, 48, 57, 58, 64, 65, 90, 91, 96, 97, 122, 123, 127, 128, 255, 256,
300, 1000, -1, -2, -128, -129, -1000, PHP_INT_MAX, PHP_INT_MIN`), and the
non-int/non-string types — and compares each `cty_X` against the built-in
`ctype_X`. **0 mismatches**: byte for byte php's own ctype.

## The bench

`bench.php` times `cty_*` against php's own compiled-in `ctype_*` in one
process, best of nine interleaved. The reference is the C extension itself, so
the printed ratio is **`cty_*` / `ctype.so`**. The measured ratio is **~10x**
(macOS, Apple M4, `-O`): over the **< 2.0** DONE bar.

Why, and what it would take to close it. `ctype.c`'s loop indexes a rune table
per byte — no function call. This port **calls** `isalnum()` per byte, and each
`cty_X` crosses the php call boundary into `_ctype_chk` and `_ctype_is`. That
per-byte libc call plus the php boundary is the whole ~10x; a fully-inlined
single-predicate variant (no helpers, the extern in-line) measures ~4.9x — still
not < 2x. The only thing that reaches ctype.c's order is to classify a **whole
string in one pass** with `strspn($s, $set)` against a per-predicate byte set
built once from libc — the same table-driven shape ctype.c has. That version was
written, measured correct (0 mismatches) and is in the git history of this
branch; it is **blocked by a compiler leak** and not shipped.

Two leaks are in play, and only the first is fixed:

1. `strspn($s, $set)` with a `$set` that is not a frame-owned literal used to
   escape the subject on the generic path and leak ~48 bytes/call. That is
   **fixed** (the native path borrows a mixed/global set with no reference
   taken); a one-frame `strspn` loop over a mixed set now moves php's peak 0
   bytes.
2. A table-driven `cty_X` must read its per-predicate set once **per call**, and
   the set is module-persistent (built at MINIT). Reading any module-persistent
   refcounted string per call — through `global`, a `static` class property, or
   a `static` local — **retains ~32 bytes/call** (released only at request end),
   which exhausts the heap in a hot loop *and* thrashes the allocator (the
   table-driven bench measured *slower* than the per-byte form while leaking).
   `$GLOBALS[...]` is refused by design, so there is no escape. This second leak
   is what still blocks < 2x, and it is independent of `strspn`:

```php
$M = "0123456789abcdef";
function f(mixed $v): int { global $M; return strlen($M); }   // no strspn at all
// f() called in a hot loop retains ~32 bytes/call (peak +6.4 MB over 200k).
// A `static` class property and a function `static` local leak the same way.
```

Per the port's rules a faithful port needs no compiler change, so this one ships
the **correct, leak-free, per-byte** form (~10x) and reports the gap rather than
fixing `src/*.mc`. When the per-call persistent-string read stops retaining, the
table-driven `strspn` form drops straight in for < 2x.

## Files

- `ctype.php` — the port: eleven `cty_*`, the private `#[Extern]` `is*()` and
  `_ctype_chk`/`_ctype_is` helpers.
- `check.php` / `check.expect` — the differential against the built-in ctype.
- `bench.php` — `cty_*` vs `ctype.so`, best of nine.
- `mcphp.toml` / `mcphp.linux.toml` — the build (macOS bundle road; Linux
  shared). `[extension].name` is `ctype_port`, not `ctype`, so it does not
  collide with the compiled-in ctype module.

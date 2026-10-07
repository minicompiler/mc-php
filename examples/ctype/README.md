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
the printed ratio is **`cty_*` / `ctype.so`**.

The port is **leak-free** (both compiler leaks it first exposed are fixed: the
`strspn` subject escape, and the per-call read of a module-persistent `global`
or `static`). It is **correct** (the 3322-case differential is 0 mismatches).
But it does **not** reach the < 2.0 bar, and no faithful form does — the ratio
is **~22x** on short tokens (the typical ctype input), falling to ~2.2x only on
512-byte strings.

Why `ctype` is unlike `examples/db`. `db`'s bench is dominated by `libsqlite3`,
shared by the module and the C twin, so the thin mc-php glue measures 1.37x.
`ctype` has **no** heavy shared component: `ctype.so` is a trivial inlined C
loop (~17 ns for an 8-byte string), and the whole cost is the one thing mc-php
cannot make free — crossing the php↔module call boundary and doing per-call
work. Three faithful, leak-free forms were measured; none is < 2x:

- **per-byte libc** (`isalnum()` per byte via `#[Extern]`): ~10x on short
  input. One extern call per byte.
- **table-driven `strspn`** (this file): a whole-string `strspn($s, $SET)` over
  a per-predicate set built once from libc. php's `strspn` rebuilds a 256-entry
  charmask from the set on **every** call, and the sets that include the
  high-byte (128..255) classes are large (`alnum`/`alpha`/`print`/`graph`/`cntrl`
  run to ~60–250 bytes), so the rebuild dominates: ~22x at 8 bytes, 13.8x at 32,
  4.9x at 128, 2.2x at 512. It wins only once the subject is long enough to
  amortize the rebuild — which realistic ctype calls are not.
- **256-byte flag table, index per byte** (closest to `ctype.c`): ~24x and
  worsening with length — per-byte php string indexing is itself expensive.

This file ships the **table-driven `strspn`** form: the "classify a whole string
in one pass" shape `ctype.c` has, now that it is leak-free. The < 2.0 bar is a
property of a port with a heavy shared cost (db); a pure per-byte classifier
against an inlined C extension does not have one, so < 2x is not reachable here
on any faithful form.

## Files

- `ctype.php` — the port: eleven `cty_*`, the private `#[Extern]` `is*()` and
  `_ctype_chk`/`_ctype_is` helpers.
- `check.php` / `check.expect` — the differential against the built-in ctype.
- `bench.php` — `cty_*` vs `ctype.so`, best of nine.
- `mcphp.toml` / `mcphp.linux.toml` — the build (macOS bundle road; Linux
  shared). `[extension].name` is `ctype_port`, not `ctype`, so it does not
  collide with the compiled-in ctype module.

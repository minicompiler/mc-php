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

## How it classifies, and the locale it targets

`ctype.c` indexes a static classification table per byte. This port carries the
same table as a **compile-time string literal** per predicate, inline at the
`strspn` call so mc-php precomputes the scan (see *The bench*). The sets are the
**C locale's** classification — the standard 7-bit ASCII classes; no byte
128…255 is in any class. The port therefore matches ctype under the C locale,
which is what `check.php` and `bench.php` set with `setlocale(LC_CTYPE, "C")`
for both the module and the reference. A program that selects a different
`LC_CTYPE` at run time would see `ctype.so` adapt its 128…255 answers and this
port not — the one documented difference. An int argument is turned into the
one-byte string it denotes and runs the same scan, so the int-quirk path uses
the same literal; the `(allow_digits, allow_minus)` constants are inlined per
function as the `> 255` and `< -128` results. No libc call and no byte-by-byte
loop: a whole string is one `strspn`.

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
process, best of nine interleaved, both in the C locale. The reference is the C
extension itself, so the printed ratio is **`cty_*` / `ctype.so`**.

The string path is now table-driven the way `ctype.c` is: each `cty_X` scans a
whole string in one pass with `strspn($s, "<literal>")`, and because the set is
a **compile-time string literal** mc-php precomputes the scan — a contiguous
class (`digit`, `upper`, `lower`, `print`, `graph`) lowers to a run test
(`php_spn_r`, `lo <= c <= hi`), and a non-contiguous one (`alnum`, `alpha`,
`xdigit`, `punct`, `space`, `cntrl`) to `php_spn` over a byte map built **once
at compile time** (`ph_bmap_of`). There is no per-call charmask rebuild and no
module-global read: the hot loop moves php's peak **0 bytes/call**. This removed
the earlier ~22x (a per-call rebuild of the mask from a non-literal global set).

Per-predicate ratio (2026-10-08, macOS/arm64), best of nine, 200000 calls a
round, on an all-pass input of four to eight bytes and on a FAILING input whose
bad byte is first (where `ctype.so` returns at once). "direct" calls
`cty_X($v)` by name; "dynamic" calls it through a variable, which is how
`bench.php` reaches all eleven:

| predicate | direct, pass | direct, fail | dynamic, pass | dynamic, fail |
|---|---|---|---|---|
| alnum  | 1.58x | 1.73x | 1.13x | 1.07x |
| alpha  | 1.60x | 1.76x | 1.12x | 1.06x |
| cntrl  | 1.75x | 1.77x | 1.09x | 1.08x |
| digit  | 1.65x | 1.91x | 1.12x | 1.13x |
| graph  | 1.44x | 1.73x | 1.10x | 1.09x |
| lower  | 1.52x | 1.74x | 1.08x | 1.08x |
| print  | 1.49x | 1.74x | 1.08x | 1.14x |
| punct  | 1.60x | 1.74x | 1.16x | 1.07x |
| space  | 1.64x | 1.75x | 1.16x | 1.13x |
| upper  | 1.45x | 1.73x | 1.10x | 1.08x |
| xdigit | 1.85x | 1.87x | 1.14x | 1.08x |

**Every predicate, every case, under the 2.0 bar** -- the closest is
`digit` on a failing input called directly, 1.91x. `bench.php`'s own
aggregate over its mixed token list is **1.62x** (`tests/examples.sh`).

What is left is not the scan (it is precomputed) but the fixed per-call cost of
a compiled-PHP function that takes a `mixed` parameter. A faithful ctype port
**must** take `mixed`: `ctype_digit(48)` is the char-code quirk (true), not the
string `"48"`, so an int argument has to reach the function un-coerced, and
`ctype_digit(1.5 / null / [] / a resource)` must return `false`, not raise a
`TypeError`. A `string` parameter gives neither.

An earlier version of this port sat at ~2.4–2.6x, above the bar: binding a
`mixed` on entry built a runtime zval, copied the value and escaped/proxied it
for every call. mc-php now **borrows** such an argument in place when the body
only ever type-tests and coerces it (`phx_zarg_ro`, `lib/php_ext.mc`; the
read-only proof is `ph_borrow_scan`, `src/ext.mc`) — no allocation, no copy, no
proxy. The failing-input column came under 2.0 later, with the extension
handler's entry and exit: the arena is entered lazily, and a call that
allocates nothing never sets its cursor (`phx_enter`, `lib/php_ext.mc`). Both
are changes in **mc-php's own** `src/`/`lib/`, not in the mc compiler
(`mini_compiler` is untouched), and each is inert where it cannot prove itself
safe.

## Files

- `ctype.php` — the port: eleven self-contained `cty_*`, each inlining its
  C-locale set literal at the `strspn` call (no libc call, no helper, no global).
- `check.php` / `check.expect` — the differential against the built-in ctype.
- `bench.php` — `cty_*` vs `ctype.so`, best of nine.
- `mcphp.toml` / `mcphp.linux.toml` — the build (macOS bundle road; Linux
  shared). `[extension].name` is `ctype_port`, not `ctype`, so it does not
  collide with the compiled-in ctype module.

# db -- sqlite3 from PHP source

PHP source that calls libsqlite3's C API through `#[Extern('sqlite3')]`, compiled by `mc-php`
into an extension php loads:

```sh
mc-php build examples/db --config examples/db/mcphp.toml
php -d extension=examples/db/build/db.so examples/db/check.php
```

Every `#[Extern]` parameter and return is an `int`, a `Ptr` or a `string` -- all the surface
carries. It opens a database (`:memory:` or a file), runs DDL, bulk-loads rows through ONE
prepared statement in one transaction (`sqlite3_bind_*`, `step`, `reset`), reads a first column
back as an int or as text, reports sqlite's own error codes and messages, and (slice 2) pulls
whole result sets back as php arrays.

| file | |
|---|---|
| `db.php` | the extension: the `sqlite3_*` declarations (never published) and the eight `db_*` functions |
| `mcphp.toml` | macOS; `mcphp.linux.toml` is the same file with the Linux `[linker]` |
| `check.php` | the driver: in memory and on disk, with the error paths and the rows-as-arrays reads |
| `check.expect` | its recorded output |
| `oracle.php` | the same SQL through php's own `SQLite3` class, which must print `check.expect` too |
| `c/db.c` | the C twin: the same eight functions as an ordinary hand-written C extension |
| `bench.php` | the triangular bench: the module, the C twin, and php's `SQLite3` interpreted |

## Rows as arrays (slice 2)

`db_rows($db, $sql): array` returns a query's rows as a php array of associative arrays
(`column name => value`), assembled **in PHP** over the scalar column reads
(`sqlite3_column_count`, `sqlite3_column_name`, `sqlite3_column_text`) -- no new `#[Extern]`
return type: the array is a core php value, and a published function may return one
(`docs/php-extension.md`). Each value is the text sqlite coerces the column to, so a generic row
reader is text in, text out, the same shape whatever the column's declared type. The array is
built and handed back by copy, as every php value the module returns is.

## How it is graded

`tests/examples.sh` builds `db.so`, runs `check.php` against `check.expect`, runs `oracle.php`
against the same bytes, checks that only the eight `db_*` names are published, builds the C twin
and grades it the same way, and prints the triangular bench. It is **not** a differential
(running the interpreted `db.php` against the module): interpreted, an `#[Extern]` body is empty.

It is **SKIPPED by name** on Windows (`#[Extern]` is refused there) and on a php with no sqlite3
extension. On the extension road the `sqlite3_*` symbols resolve from php's own process, so the
link names no `-lsqlite3`. The requirement is a php with the `sqlite3` module loaded: the gate
skips without it, and `oracle.php` uses its `SQLite3` class. `pdo_sqlite` alone is not enough.

## DONE: the C twin and the ratio

The example is DONE when the compiled module runs in **less than 2x** the hand-written C twin's
time on the same workload (`module/C < 2.0`), measured beside php's own `SQLite3` interpreted for
context. The bench workload is the example's own story -- a 1000-row prepared bulk load, three
aggregates, and a 200-row page pulled back with `db_rows` -- so it is dominated by libsqlite3,
shared by all three, the way a real DB task is; the compiled glue is the thin edge the ratio
measures.

Measured on macos/arm64 (Apple M4, php 8.5.10, best of nine, three rounds interleaved):

```
interpreted ~0.88 ms, compiled ~0.66 ms (1.33x), C twin ~0.59 ms, module/C 1.12x
```

**1.12x < 2.0, so the example is DONE** -- and so is each function on its own
(2026-10-08, best of three rounds, each the best of a timed loop, module and
twin interleaved):

| call | module/C | call | module/C |
|---|---|---|---|
| `db_open` + `db_close` | 1.02x | `db_scalar` | 1.07x |
| `db_exec` | 1.02x | `db_text` | 1.20x |
| `db_error` | 1.29x | `db_rows`, 200 rows | **1.78x** |
| 1000-row prepared load | 1.04x | `db_rows`, 1 row | 1.29x |

`db_rows` over a page of rows is the closest, and it was **2.6x** before: a row
assembled in PHP moves into the result array instead of being copied into it
twice, an array's element is set without a zval box, and the finished array is
handed to php as php's own hash table (`php_arr_mv`, `php_arr_set_*`,
`phx_r2e_arr` in `lib/php_rt.mc` and `lib/php_ext.mc`). A bulk row-reading
`#[Extern]` return (an array built in C) would still close the rest; it is not
needed for DONE.

## The out parameters

`sqlite3_open` and `sqlite3_prepare_v2` return their handle through `sqlite3 **`. PHP has no
pointer-to-pointer, so the module passes a string it made at run time of exactly 8 bytes
(`str_repeat("\0", 8)`) as the parameter, which C writes into, and reads the pointer back with
`unpack('P')` -- the form `docs/php-extension.md` § A C function sanctions for a C function that
writes.

## A connection as an object (a later slice)

Today the connection is a plain php int (the `sqlite3 *` handle). Surfacing it as a `Db` object
-- `$db = Db::open(...); $db->rows($sql)` -- needs **no compiler change**: a top-level `class`
whose name has no leading underscore is already published at MINIT (`docs/php-extension.md`
§ What is published), its methods callable and its int handle held in a scalar property. It is a
design choice for a later slice, not a compiler gap; the int/Ptr handle is what this example
uses, and it is enough for DONE.

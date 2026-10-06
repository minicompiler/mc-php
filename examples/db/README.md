# db -- sqlite3 from PHP source (slice 1)

PHP source that calls libsqlite3's C API through `#[Extern('sqlite3')]`, compiled by `mc-php`
into an extension php loads:

```sh
mc-php build examples/db --config examples/db/mcphp.toml
php -d extension=examples/db/build/db.so examples/db/check.php
```

Slice 1 is **scalars only**: every `#[Extern]` parameter and return is an `int`, a `Ptr` or a
`string`. It opens a database (`:memory:` or a file), runs DDL, bulk-loads rows through ONE
prepared statement in one transaction (`sqlite3_bind_*`, `step`, `reset`), reads a first column
back as an int or as text, and reports sqlite's own error codes and messages.

| file | |
|---|---|
| `db.php` | the extension: the `sqlite3_*` declarations (never published) and the seven `db_*` functions |
| `mcphp.toml` | macOS; `mcphp.linux.toml` is the same file with the Linux `[linker]` |
| `check.php` | the driver: 15 lines, in memory and on disk, with the error paths |
| `check.expect` | its recorded output |
| `oracle.php` | the same SQL through php's own `SQLite3` class, which must print `check.expect` too |

## How it is graded

`tests/examples.sh` builds `db.so`, runs `check.php` against `check.expect`, runs `oracle.php`
against the same bytes, and checks that only the seven `db_*` names are published. It is **not**
a differential against `db.php` required: interpreted, an `#[Extern]` body is empty.

It is **SKIPPED by name** on Windows (`#[Extern]` is refused there) and on a php with no sqlite3
extension. On the extension road the `sqlite3_*` symbols resolve from php's own process, so the
link names no `-lsqlite3`; a php that has `sqlite3` or `pdo_sqlite` loaded is the whole
requirement.

## The out parameters

`sqlite3_open` and `sqlite3_prepare_v2` return their handle through `sqlite3 **`. PHP has no
pointer-to-pointer, so the module passes a string it made at run time of exactly 8 bytes
(`str_repeat("\0", 8)`) as the parameter, which C writes into, and reads the pointer back with
`unpack('P')` -- the form `docs/php-extension.md` § A C function sanctions for a C function that
writes.

## Not in slice 1

* **Rows as arrays or objects**, and a connection as a resource or an object the module declares:
  those need signatures past the scalars, which the compiler does not have yet (a class the
  source declares compiles and is not published). That is slice 2.
* **The C twin** (`c/db.c`, measured beside the compiled module) -- an example is DONE only with
  one, so this one is not done yet.
* **Windows**: `#[Extern]` is refused there.

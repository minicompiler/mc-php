# `mcphp.toml` -- the project file

**Not implemented.** This page is the schema, decided and written down so the README can
describe it truthfully as the shape that is coming. `mc-php build` does not read it yet; today
the compiler is driven by `mc-php --exe FILE.php -o BIN`, which is the PROGRAM road and not the
extension road.

## Why a file and not a command line

The same reason `mc.toml` exists for mc. Building a PHP extension the old way is `phpize &&
./configure && make` -- three tools, a generated `config.m4`, a C toolchain and the php
development headers. The whole point of mc-php is that none of that is needed, and that claim is
not worth much if the replacement is a command line nobody can remember twice.

So: one file describes the extension, and

    mc-php build

reads it, reads the target php, compiles, links and writes the artefact. No make, no cmake, no
long command line. The repository's own build follows the same rule -- `mc build` for the
compiler, shell only for the test grid.

## Why this subset of TOML

`mc-php` is an mc program, and `src/toml.mc` comes free inside `<mc/core_build>`. Using it costs
nothing; inventing syntax around it would cost a parser. So the schema below stays inside what mc
already parses, which is exactly ([mc's `docs/reference/toml.md`](https://github.com/minicompiler/mc/blob/main/docs/reference/toml.md) § The TOML subset):

* `[table]` and `[[array.of.tables]]` headers, dotted headers included
* bare, quoted and dotted keys -- a quoted key may **not** contain a `.`
* strings (escapes `\" \\ \n \t \r`), integers (`+ - _`), floats, booleans
* flat arrays of strings or of integers, multi-line, trailing comma allowed

and does **not** include inline tables (`{ a = 1 }`), literal strings (`'...'`), multi-line
strings (`"""..."""`), datetimes, or nested arrays. The result is a flat `(path, value, type,
index)` table in source order, which is what lets a reader walk the **keys** of `[libs]` and
`[externs]` rather than only their values.

Every path in the file is relative to the directory of the file, never to the working directory
-- mc's rule, kept.

## The whole file

```toml
[extension]
name    = "hello"                # what php sees:  extension=hello,  extension_loaded("hello")
prefix  = "hello_"               # the C symbol prefix (defaults to name + "_")
version = "0.1.0"                # what phpinfo() shows
entry   = "src/hello.php"        # one entry; or `sources`, never both
out     = "build/hello.so"

[php]
bin = "/opt/homebrew/bin/php"    # interrogate this php -- or state the four values below

[target]
os   = "macos"                   # macos | linux | windows
arch = "aarch64"                 # aarch64 | x86_64

[[extension.deps]]               # other PHP extensions, not native libraries
name = "json"
type = "required"

[libs.windows]                   # per OS; an unqualified [libs] applies to every OS
php = "build/php8.lib"

[externs.windows]
"zend_*" = "php"

[linker.macos]                   # the escape hatch, only when the default road does not fit
cmd  = "ld"
args = ["-bundle", "-undefined", "dynamic_lookup", "-o", "{out}", "{obj}"]
```

---

## `[extension]`

### Two names live here, and a third one does not

The file carries only what the linker and the module entry have **no other source for**:

| key | who consumes it |
|---|---|
| `name` | **php.** `extension=NAME` in `php.ini`, `extension_loaded("NAME")`, and the string another extension puts in its `zend_module_dep` record to depend on this one. It lands at **offset 32** of the module entry |
| `prefix` | **the linker.** The C symbol prefix every exported symbol carries -- see [The symbol prefix](#the-symbol-prefix) |

Both of those are outside the PHP language, which is why they are here.

**The namespace is not, and it is not a key.** It is declared in the extension's own `.php`
source and obeyed as written:

```php
<?php
namespace awaitable;
function await(...) { ... }        // reaches zend_function_entry as awaitable\await
```

`mcphp.toml` does not carry it, does not override it, and never prepends one. Nothing is
inferred and no default is imposed.

The reason is bigger than the field: the whole premise is that the source stays ordinary,
readable, valid PHP -- a file you could still hand to the interpreter. A compiler that injected
a namespace from outside would break exactly that, and would make the same file mean two
different things depending on which tool read it.

**On collision**: two extensions that publish the same name in the same namespace are reported
by the ENGINE at startup. That is the developer's conflict to resolve. This compiler does not
check it, and this page does not promise a check nobody is going to write.

| key | type | default | meaning |
|---|---|---|---|
| `extension.name` | string | **required** | the module name php sees, as above. `[a-z][a-z0-9_]*` |
| `extension.prefix` | string | `name` + `_` | the C symbol prefix. Written explicitly when it must differ from `name` -- a module called `my-ext` cannot derive one, because `-` is not a symbol byte, and is told so rather than mangled |
| `extension.version` | string | `"0.0.0"` | `zend_module_entry.version`, which `phpinfo()` prints |
| `extension.entry` | string | one of `entry`/`sources` is **required** | the single `.php` the compiler is handed. Its `require`s pull in the rest, the way a program's do |
| `extension.sources` | array of strings | — | several independent `.php`, each compiled into the same module. Giving both `entry` and `sources` is an error: there is one answer to "what is this extension made of" |
| `extension.out` | string | **required** | the artefact. `.so` on Linux, `.so` on macOS (php loads a bundle under that name), `.dll` on Windows |

**What is NOT configured here, on purpose**: which functions and classes the extension exports.
Every top-level `function` and `class` in the sources is registered -- the `zend_function_entry`
table is built from the source, not from a list someone has to keep in step with it. A `.php`
file is PHP, and PHP already says what it declares.

## `[php]` -- the target php

An extension's module header carries exactly four values about the php it will be loaded into,
and they are all that is consulted. Measured against php-src's own `Zend/zend_modules.h`
(`zend_module_entry` fields `zend_api`, `zend_debug`, `zts`, `build_id`):

| key | type | `php -i` line | `zend_module_entry` field |
|---|---|---|---|
| `php.api` | integer | `PHP API` | `zend_api` |
| `php.build_id` | string | `PHP Extension Build` | `build_id` |
| `php.thread_safety` | boolean | `Thread Safety` | `zts` |
| `php.debug` | boolean | `Debug Build` | `zend_debug` |
| `php.bin` | string | — | a php binary to read the four out of, instead of stating them |

Give **either** `bin` **or** the four. Stating both is an error: two sources of truth for the
same four numbers is how a cross-build silently targets the wrong php.

Stating them is what makes a cross-build need no php on the machine. On this host (macOS 26 /
arm64, PHP 8.5.10 Homebrew NTS, measured 2026-09-22) `php -i` gives:

```
PHP API => 20250925
PHP Extension Build => API20250925,NTS
Thread Safety => disabled
Debug Build => no
```

which is written as:

```toml
[php]
api           = 20250925
build_id      = "API20250925,NTS"
thread_safety = false
debug         = false
```

Nothing else about php is read. In particular **no php header file is opened**, which is the
whole point: `php-config`, `phpize` and the development package are not on the road.

## `[target]`

| key | type | default | accepted |
|---|---|---|---|
| `target.os` | string | the host | `macos`, `linux`, `windows` |
| `target.arch` | string | the host | `aarch64`, `x86_64` |

With no `[target]` the host pair is used, which is mc's own rule.

## `[libs]` and `[externs]`, per OS

Same two tables mc.toml has, and the same meaning: `[libs]` names a library, `[externs]` maps a
symbol pattern onto one of those names. The addition is the OS qualifier:

```toml
[libs]                           # every OS
[libs.linux]                     # linux only, on top of the unqualified table
[externs.windows]
"zend_*" = "php"
```

`macos`, `linux` and `windows` are **reserved** as the first segment under `[libs]`,
`[externs]` and `[linker]`. A library actually called `linux` has to be renamed; the flat table
cannot tell `libs.linux` the OS section from `libs.linux` the library, and refusing the
ambiguity is better than picking a winner (mc's `toml.mc` makes the same call for a quoted key
containing a `.`).

On macOS and Linux this is usually **empty**, and that is not an oversight: an extension
resolves `zend_*` out of the running php process, so there is no library to name. Windows has no
flat namespace, so every `zend_*` comes from an import library -- and an import library is only a
list of names, which is why a two-line `.def` and `llvm-dlltool` replace the whole development
pack (see the README's dependency table).

## `[[extension.deps]]` -- other PHP extensions

`[libs]` is NATIVE libraries. This is the other thing entirely: **an extension that needs
another PHP extension**, which the Zend engine already has a record for and already enforces.
mc-php keeps that convention rather than inventing one.

```toml
[[extension.deps]]
name = "json"
type = "required"                # required | optional | conflicts

[[extension.deps]]
name    = "mysqlnd"
type    = "optional"
rel     = "ge"                   # lt | le | eq | ge | gt -- see the caveat below
version = "8.1"
```

`[[...]]` is an array of tables, so the flat paths are `extension.deps.0.name`,
`extension.deps.1.name`, ... and **the order is the file's order**. That matters: the record it
becomes is a NULL-terminated array walked front to back.

It maps one to one onto php's own `zend_module_dep`, read out of
`php-src/Zend/zend_modules.h` at tag `php-8.5.10` (verified 2026-09-22):

```c
struct _zend_module_dep {
    const char *name;       /* @0  */
    const char *rel;        /* @8  version relationship: NULL (exists), lt|le|eq|ge|gt */
    const char *version;    /* @16 */
    unsigned char type;     /* @24 */
};                          /* 32 bytes on LP64 */
```

`zend_module_entry.deps` is at **offset 24** and points at that array.
`MODULE_DEP_REQUIRED` is 1, `MODULE_DEP_CONFLICTS` 2, `MODULE_DEP_OPTIONAL` 3 --
so `ZEND_MOD_REQUIRED("json")` is `{"json", NULL, NULL, 1}`, which is what a row with only
`name` and `type` becomes.

| key | type | default | meaning |
|---|---|---|---|
| `name` | string | **required** | the other extension's module name, matched case-insensitively |
| `type` | string | `"required"` | `required`, `optional` or `conflicts` |
| `rel` | string | none | `lt`, `le`, `eq`, `ge`, `gt` -- the relationship to `version` |
| `version` | string | none | the version `rel` compares against |

### The engine enforces it, so the compiler does not

Measured in `php-src/Zend/zend_API.c` at the same tag, so this is what the generated module
entry buys and the compiler emits no run-time check at all:

* **`zend_sort_modules`** reorders startup so that a `required` **or** an `optional`
  dependency gets its `MINIT` first. Declaring the dependency IS the ordering.
* **`required` and absent** -> `E_CORE_WARNING: Cannot load module "X" because required module
  "Y" is not loaded`, and the module does not start.
* **`conflicts` and present** -> `E_CORE_WARNING: Cannot load module "X" because conflicting
  module "Y" is already loaded`, and the module is not registered.

**The caveat, and it is php's own, not ours**: `rel` and `version` are carried and **not
checked**. Both enforcement sites in 8.5.10 read

```c
/* TODO: Check version relationship */
```

so a `ge`/`8.1` row today means exactly what a bare row means -- the extension must be there.
The schema carries the two keys because the RECORD carries them and a module entry that dropped
them would be lying about itself; nobody should plan around them being enforced until php
enforces them.

### A required dependency resolves early; an optional one must not be assumed

A `required` dependency has had its `MINIT` run before yours, so a symbol from it may already
be resolved when your module starts. An `optional` one **may simply be absent**, and the honest
road there is a lookup at CALL time rather than at load time -- which has the second benefit of
making the load order of the two extensions irrelevant.

Measured (owner, 2026-09-22): two mc-php extensions, either load order, the same answer both
ways; and with the producer absent the consumer degrades to a clean answer instead of crashing.

## The symbol prefix

One extension reaches another through **plain exported symbols carrying the extension's
prefix**. There is no dispatch table and no vtable; functions and data are alike and flat. Read
off the installed php (Homebrew PHP 8.5.10, macOS arm64, 2026-09-22):

```
$ nm -gU "$(which php)" | grep ' [TDS] _mysqlnd_'
00000001014d0ec0 D _mysqlnd_allocator
00000001013ebce8 S _mysqlnd_command_to_text
00000001004415e0 T _mysqlnd_connection_connect
000000010043d1f0 T _mysqlnd_cset_escape_quotes
...                                     # 49 T, 16 D, 10 S in all
```

The namespace is **flat**, so the prefix is the only thing standing between two extensions that
both want a common name -- and when two do want it, the first one loaded wins, in silence.

In C that prefix is the author's discipline. Here the compiler generates the symbols, so it can
**require** it instead of trusting it. So the prefix is **declared**, in `[extension].prefix` --
not derived silently, not left to discipline -- and the decision on record for the compiler to
enforce later is:

> Every symbol an extension exports begins with `extension.prefix`. A declaration that would
> export anything else is a compile error, named, before the link.

### `get_module` is the one exemption

**`get_module` may never be prefixed.** php's loader fetches that exact name.
`php-src/ext/standard/dl.c` (tag `php-8.5.10`, verified 2026-09-22):

```c
get_module = (zend_module_entry *(*)(void)) DL_FETCH_SYMBOL(handle, "get_module");
/* Some OS prepend _ to symbol names while their dynamic linker
 * does not do that automatically. Thus we check manually for
 * _get_module. */
if (!get_module) {
    get_module = (zend_module_entry *(*)(void)) DL_FETCH_SYMBOL(handle, "_get_module");
}
if (!get_module) {
    ...
    php_error_docref(NULL, error_type, "Invalid library (maybe not a PHP library) '%s'", filename);
```

Two names are tried -- `get_module` and `_get_module` -- and nothing else. A bundle whose entry
point is called anything else is refused with `Invalid library (maybe not a PHP library)` and no
further explanation, which is exactly what the first hand-built bundle answered (owner,
2026-09-22). It is the only symbol outside the rule, and it belongs here where the rule is
stated rather than in a footnote.

## `[linker]`, per OS -- the escape hatch

The default road needs no `[linker]`. When it does not fit, this replaces it, with mc's own
substitutions inside each argument:

| placeholder | what it becomes |
|---|---|
| `{out}` | `extension.out` |
| `{obj}` | the object the compiler wrote |
| `{sdk}` | `xcrun --show-sdk-path`, run lazily and only if an argument asks |
| `{libs}` | expands to one argument per `[libs]` entry |

```toml
[linker.linux]
cmd  = "ld.lld"
args = ["-shared", "-Bsymbolic", "-o", "{out}", "{obj}"]
```

`-Bsymbolic` on Linux is not optional and the reason is in the README: mc takes the address of
its own functions with `adrp`/`add`, and in a shared object a default-visibility symbol is
preemptible, so the link is refused without it.

## `[include]`

| key | type | meaning |
|---|---|---|
| `include.paths` | array of strings | extra roots a literal `require`/`include` is resolved against, after the includer's own directory |

A computed include is refused by design (`docs/plan.md` D1); this is for the literal ones.

## Not covered yet

* INI entries (`PHP_INI_ENTRY`), a module globals struct, and the `MINIT`/`RINIT` hooks beyond
  what the compiler emits by itself.
* More than one target in one file. Today a cross-build is a second file and `--config`.

Each of those is a decision, not an omission, and each will be written down here when it is made.

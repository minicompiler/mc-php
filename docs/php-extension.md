# The extension back end

**A `.php` source compiled into a native PHP extension**: no C, no `phpize`, no autotools, no
php development headers. This page is what is IMPLEMENTED; [`docs/mcphp-toml.md`](mcphp-toml.md)
is the full schema of the project file and [`docs/php-abi.md`](php-abi.md) is every Zend number
this rests on, with what it was measured against.

## The whole road

```sh
mc-php build examples/hello --config examples/hello/mcphp.toml
php -d extension=examples/hello/build/hello.so -r 'echo hello_addone(41), "\n";'   # 42
```

On Windows the artefact is a `.dll` and the file is `examples/hello/mcphp.windows.toml`, after
`sh tests/winsys.sh x86_64` has written the import libraries its link names (§ Windows below).

There is no flag and there will not be one. The switch is the project file, exactly as
`docs/mcphp-toml.md` says: **an `[extension]` table means an extension, and no `[extension]`
table means the program road, unchanged.** `mc-php --exe x.php -o x` sees no project file at all
and is what it always was.

## What a source may say today

Plain functions, with **declared scalar parameters and a declared scalar return**:

| | parameter | return |
|---|---|---|
| `int` | yes | yes |
| `string` | yes | yes |
| `float` | yes | yes |
| `bool` | yes | yes |
| `void` | — | yes |

Everything else is a **named refusal at the declaration's own position**, never a silent
lowering -- because a silent one would publish a signature php does not have:

```
hello.php:7: mc-php: an exported parameter whose type is not a declared scalar: f is not implemented yet
hello.php:7: mc-php: a variadic parameter in an exported function: f
hello.php:7: mc-php: a by-reference return in an exported function: f
hello.php:7: mc-php: an exported function whose return type is not a declared scalar: f
hello.php:3: mc-php: a namespace in an extension source
```

A parameter with a **default** and an **untyped** parameter are both `mixed` by
`docs/plan.md` D4 (c), so both land on the first of those. One more is worth naming because it
is ordinary php and the reason is not obvious:

```
hello.php:4: mc-php: an exported function called before it is declared (move it above its first call): b
```

php HOISTS a global function, so calling one declared further down the file is legal -- but D4
builds that call against a zval signature and then widens the declaration to match it, and a
widened signature is not exportable. **Declare before the first call**, which is the fix the
message names. Closing it properly means teaching the byte pre-scan the declared TYPES, which
would move every forward call's lowering on the program road too; that is a step of its own. A `namespace` is refused rather than
flattened: flattening costs a program nothing (T9) but would make the module publish `f` where
the source says `aw\f`, and `docs/mcphp-toml.md` promises the module obeys the source's own
namespace.

The body is the whole language. Classes, closures, `match`, exceptions, the 272-row library --
everything the program road compiles compiles here; it is the SIGNATURE that is narrow, because
the signature is what crosses the boundary.

## What is published

**Every top-level function whose name does not begin with `_`.** A function named `_anything`
is MODULE-PRIVATE: it compiles, the module's own functions call it, and it gets no handler and
no function-table row, so from php `function_exists('_anything')` is false and
`get_extension_funcs()` does not list it. Being unpublished, its signature is not the
boundary's either -- it may take and return arrays, objects, `mixed`, anything the language
compiles -- and the scalar-only rule above applies to the published functions alone.

Why this rule and not an export list in `mcphp.toml` or an attribute: php has no private
function at all, and the leading underscore is php's own long-standing spelling for "internal"
(the PEAR and Zend coding standards), so a php author reads it the way the compiler does. It
keeps the whole contract in the source, next to the declaration -- a second list in the project
file is a second place to keep in sync, and a forgotten entry there is a function silently not
published -- and the source stays php that runs unchanged. The one thing it gives up is a
published name that begins with `_`; name it without one. Interpreted, php of course sees the
helpers too: the differential therefore calls only published functions, and
`tests/examples.sh` checks the published list of `examples/decimal` against the six `dec_*`
names (`tests/ext.sh` step 9 is the general gate).

## What the compiler emits

For `function hello_addone(int $n): int { return $n + 1; }`:

```
void x_h_hello_addone(uptr ex, uptr rv) {            // the Zend handler
    phx_enter();
    if (phx_arity(ex, 1, "hello_addone")) {
        if (phx_chk(ex, 0, 0, "hello_addone", "n")) {
            phx_ret_int(rv, f_hello_addone(phx_i(ex, 0)));
        }
    }
    phx_leave();
}

uptr get_module() {
    phx_fn("hello_addone", &x_h_hello_addone, 1, 0);
    phx_arg("n", 0);
    return phx_module("hello", "0.1.0", 20250925, "API20250925,NTS", 0, 0,
                      &mc_php_minit, 0);
}
```

and `main` becomes **`mc_php_minit`**, the module's `MINIT`, so the source's top-level statement
stream -- `php_bootstrap`, the class entries, a `declare`, a `require` -- runs when php loads the
module. `src/ext.mc` is the emitter, [`lib/php_ext.mc`](../lib/php_ext.mc) is everything it calls,
and the emitter knows no Zend offset at all.

## `declare(strict_types)`: mc-php is strict by definition

An mc-php source does not need `declare(strict_types=1)` and does not carry it: the type rules
are php's STRICT ones always (`docs/plan.md` D4), so the declaration would say nothing the
compiler does not already do. It is still **accepted, as a no-op**, because it is valid php and
a file written for php may have it. `declare(strict_types=0)` asks for the weak-mode coercions D4
rules out, so it is a **named refusal**, exit 3:

```
x.php:2: mc-php: declare(strict_types=0) is refused by design (docs/plan.md D4)
```

The argument check is **php's strict rule, always**: the zval's tag must be the declared one,
plus `int` where a `float` is declared, which is the one widening strict mode allows. There is
no weak mode and no coercion.

That is a divergence on the CALLER's side, and it is the honest one to take. An extension's
function is an INTERNAL function, and for a real C extension what decides weak-or-strict is the
`declare(strict_types=1)` of the file that CALLS it, resolved inside ZPP. mc-php generates its
own check, so it cannot see the caller's declaration. A caller under `strict_types=1` gets
exactly php's behaviour; a caller without it gets a `TypeError` where php would have coerced.
The php files that CALL a module in this repository (`examples/*/check.php`, `errors.php`,
`bench.php`) therefore keep `declare(strict_types=1)`: there it steers php, not mc-php.

## What a wrong call says

php's own words, measured against an extension of the same signatures built the ordinary C way
([`tests/ext/refx.c`](../tests/ext/refx.c)), and they are **not** a userland function's:

```
TypeError: hello_addone(): Argument #1 ($n) must be of type int, string given
ArgumentCountError: hello_addone() expects exactly 1 argument, 0 given
ArgumentCountError: hello_addone() expects exactly 1 argument, 2 given
TypeError: hello_addone(): Argument #1 ($n) must be of type int, stdClass given
```

No `called in FILE on line N` tail, and an EXTRA argument is an error rather than being ignored --
both of which php does differently for a userland function, which is why
[`examples/hello/errors.php`](../examples/hello/errors.php) is graded against a recorded
expectation and not against the interpreted source.

## What differs from the interpreted source, and it is written down

[`examples/hello/check.php`](../examples/hello/check.php) is run twice on every gate -- once with
the module loaded, once with the source `require`d -- and the two must print the same bytes on
each stream and exit the same. These are the places where they would not:

* **Output buffering is php's.** What a module echoes goes through `php_output_write`, php's own
  output layer, exactly as an internal function's `php_printf` does -- so `ob_start()` captures it
  in order with php's own `echo`, nested levels included (`check.php`'s last two lines). The
  runtime keeps one sink, `php_out1`: fd 1 on the program road, `php_output_write` once
  `get_module` has run. Before batch A it wrote fd 1 on both roads and `ob_start(); hello_say("B");`
  left `[B]` on the terminal. The other direction holds too: an `ob_start()` the MODULE calls is
  php's own (`php_output_start_default` and the rest of `main/php_output.h`), so a level it leaves
  open captures the script's echo after the call, as an internal function's would
  (`tests/ext.sh` step 10). The runtime's own stack stays for what it captures itself
  (`print_r($x, true)`).
* **An exception the body throws** crosses as its own class when php has one of that name --
  every built-in does, so `throw new InvalidArgumentException(...)` arrives as itself. A class
  the SOURCE declares is not in the engine's class table (the back end registers no class yet),
  and the fallback is a plain `Exception` whose message names it.
* **Destructors and `register_shutdown_function`** do not run. A program runs them when it ends;
  a module's request end (RSHUTDOWN) restores state and does not call back into php code, and
  `module_shutdown_func` is 0 on purpose -- running `php_shutdown`'s destructors into a stdout
  the SAPI is tearing down would be worse than not.
* **The argument check is strict always**, as above. The RETURN is checked on both roads with
  php's own rule and php's own `TypeError` (`f(): Return value must be of type int, string
  returned`), the same check a declared parameter goes through on the program road; `tests/ext.sh`
  step 8 compares the module's answer with the interpreted source's.

## Thread safety

`[php].thread_safety` is carried into the module header because the loader compares it, and a ZTS
php refuses an NTS module by name. It is **not** a claim that the runtime is thread safe: the
module's arena, the call's chunk, the class table and the pending-exception flag are process
globals, and a ZTS php running two requests in two threads through one loaded module would share
all four. Nothing here has
been run under a ZTS php. Build for the php you have, and until that measurement exists, that
php should be NTS.

## The memory

`docs/plan.md` D7 -- one arena per process, never freed -- is the PROGRAM road's model, and on
the extension road it is **superseded**: a module allocates the way a C extension does, through
the Zend Memory Manager. The runtime has ONE allocation seam, `php_alloc`, with two
implementations chosen by road: the arena (a program, and a module's MINIT) or the Zend chunk an
extension call bumps through ([`lib/php_ext.mc`](../lib/php_ext.mc) § the call's memory).

| lives for | what | where |
|---|---|---|
| the module | what MINIT builds -- the bootstrap classes, the source's classes and top-level constants -- and every string literal's cache | the module's own static arena, never freed |
| one call | everything the call allocates | a 32 KiB Zend chunk the request reuses: zeroed again, and every other block the call took `efree`d, when the call returns |
| the request | what a call that writes MODULE STATE kept -- a `static`, a `global`, `define()`, an error or exception handler, a class, a file, a destructor, an output buffer left open | the call PINS itself: its blocks stay, and RSHUTDOWN puts the state back as MINIT left it |

**Strings cross without a copy where they can.** The runtime's string IS a `zend_string`
(`docs/php-abi.md`), and strings are immutable here, so a string ARGUMENT is borrowed: the engine
keeps it alive for the call, the runtime only ever writes the hash into it (the same DJBX33A
`zend_string_hash_val` stores, and never into an interned string, whose hash is set). A result the
call built in a block of its own is handed to php as it is; a small one lives inside the chunk and
is copied once; an argument returned unchanged gains a reference.

**RSHUTDOWN is the request's end, as php has one.** It is the `request_shutdown_func` slot of the
module entry (`docs/php-abi.md`). Statics a request initialised go back to "never run", files it
opened are closed, an output buffer it left open is written out, the runtime's roots (the global
table, constants, handlers, the class table, the pending exception, `error_reporting()`) are
restored from the copy taken when MINIT ended -- and, if a call pinned, the arena itself. Then the
request's blocks are freed. `RINIT` is 0: a request starts from the state the last RSHUTDOWN
restored, so there is nothing to set up.

Measured (2026-09-24, macos/arm64, php 8.5.10, `examples/decimal/soak.php`): **1 000 000
`dec_add` calls in one request**, `memory_get_usage()` 513 888 -> 513 928 bytes (the 40 are the
accumulator growing) and `memory_get_peak_usage()` 515 336 -> 515 336. Before batch A the same
loop died with `mc-php: arena exhausted` between 28 000 and 30 000 calls. Through `php -S`, 20
requests each keeping 4 MiB in a `static` answer the same line every time, as interpreted
(`tests/ext.sh` step 10); before, the statics survived from one request into the next and the
server ran out of arena at the twelfth.

What a pinned call costs, measured: a function with a `static $n` called 100 000 times in one
request keeps **32 bytes a call** until the request ends (3.2 MB); the next request starts clean.
A pinned call also keeps a reference on each string ARGUMENT it borrowed, because nothing tells
which of its writes retained one: `tally(string $s)` adding `strlen($s)` into a static, called
100 000 times with a fresh 105-byte string each time, keeps **240 bytes a call** (24 MB) until the
request ends. A call that pins nothing keeps nothing.
That is the one shape whose memory grows with the call count inside a request, and it is php's
own shape too -- php frees what refcounting frees, and a module has no refcount.

## Two extensions in one process

Both define `php_alloc`, `ph_heap`, `php_bootstrap` and every other runtime symbol, and the
example's link line exports everything. **Measured, they do not collide**: `tests/examples.sh`
loads `examples/hello` and `examples/decimal` into one php in both orders, on every host, and each
answers. mc calls a function and takes an address with a direct `bl`/`adrp`, and the Linux link
is `-Bsymbolic`, so nothing inside a module is resolved through the loader and each keeps using
its own runtime. What IS shared is the exported names: a third module that looked one up would
find the first one loaded -- which is exactly how
[`examples/two-extensions`](../examples/two-extensions/) reaches from one extension into the
other on purpose. `docs/mcphp-toml.md` § The symbol prefix is the design that gives each module
names of its own; it is not implemented. The cheap half would be a linker argument --
`-exported_symbols_list` naming only `_get_module` on macOS, a version script on Linux -- and it is
not taken here because the schema's answer is the prefix.

## Windows

The same source and the same emitter; three things differ, each measured on the Windows runners
and each said in `examples/hello/mcphp.windows.toml`:

- **The link.** `lld-link -dll -noentry -export:get_module`, against `php8.lib`, `kernel32.lib`
  and `ucrtbase.lib`. **Non-thread-safe php only**: a thread-safe php is `php8ts.dll`, refuses
  an NTS module at load, and has not been built or run against on Windows (`docs/plan.md` § 5). All three are IMPORT libraries,
  lists of names that `tests/winsys.sh` writes with `lld-link -lib -def:` from `src/win/*.def`:
  no php development pack, no Windows SDK, no `llvm-dlltool`. Only `get_module` is exported, so
  unlike the flat namespace of § Two extensions in one process, two mc-php DLLs in one php do
  not see each other's runtime symbols (not yet measured with two).
- **`_emalloc` is `_emalloc@@8`.** An MSVC build of php makes `ZEND_FASTCALL` `__vectorcall`,
  whose exports carry their argument bytes in the name. The convention is the ordinary Win64 one
  for integer arguments, so the call is unchanged and only the import needs the alias
  (`_emalloc == _emalloc@@8`). Without it the loader answers `The specified procedure could not be
  found` and php says nothing else.
- **The architecture is php's.** php publishes no arm64 Windows build, so on a Windows-on-ARM
  machine php is the x64 build, emulated, and loads x64 DLLs: the project file says
  `arch = "x86_64"` on both Windows hosts, and the arm64 mc-php cross-compiles across
  ARCHITECTURES for it.

The build id names the compiler php was built with: `API20250925,NTS,VS17` on both runners.

## The project file

What `mc-php build` reads today, of the schema in [`docs/mcphp-toml.md`](mcphp-toml.md):

| key | |
|---|---|
| `extension.name` | required. Its presence is the switch |
| `extension.version` | default `"0.0.0"` |
| `php.api` | required -- `php -i` line `PHP API` |
| `php.build_id` | required -- `PHP Extension Build` |
| `php.thread_safety` | required -- `Thread Safety` |
| `php.debug` | required -- `Debug Build` |

and mc's own `[project]`, `[linker]`, `[target]` and `[include]` carry the rest, because
`mc-php build` IS `mc build` and mc's driver ignores a table it does not know. One of mc's keys
matters here more than on the program road: **`[project].opt = 1`**, mc's optimizer (its register
allocator, branch peephole and loop hoisting), which every extension's project file in this
repository carries. An extension is called from a php that is already warm, so the generated code
is the whole cost: `examples/decimal` measured 2.78 ms without it and 1.64 ms with it
(`docs/plan.md` § 7). A taught compiler cannot set it for you -- mc applies its optimizer level
after the module's `user_init` has run -- so it is a line in the file. What is in the
schema and **not** implemented: `extension.prefix` (nothing but `get_module` needs a name, see
above), `extension.entry`/`sources`/`out` (mc's `[project]` says those), `[[extension.deps]]`,
`[libs]`/`[externs]`/`[linker]` per OS -- mc's `[linker]` is flat, so a second host is a second
file, which is how this repository already spells its own cross-builds -- and `php.bin`, which is
a NAMED refusal:

```
mcphp.toml:1: mc-php: [php].bin is not implemented: state php.api, php.build_id,
php.thread_safety and php.debug (php -i prints all four)
```

Reading the four out of a php binary means spawning one and parsing its output, which belongs to
the driver and not to a Tier 3 module. Stating them is also what makes a cross-build need no php
on the machine.

## The gate

[`tests/ext.sh`](../tests/ext.sh), inside `tests/run.sh` and inside `tests/linux.sh`. Six steps,
each a comparison against something php produced; its own header says what each one measures.
Green on **macos/arm64**, **linux/aarch64** and **linux/x86_64**, each against a php 8.5.10 of
that host's own, and on **windows/x86_64** and **windows/arm64** inside `tests/windows.sh`, each
against the runner's own php 8.5 (8.5.10 and 8.5.11 on the day it was measured; the patch is not
pinned). The two Windows legs run four of the six steps: the layout gate and the C reference need
`php-config` and a C compiler, and a Windows runner has neither -- the compiler needs neither
either, which is the claim.

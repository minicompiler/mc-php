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

## What `declare(strict_types=1)` means here

The type check is **php's strict rule, always**: the zval's tag must be the declared one, plus
`int` where a `float` is declared, which is the one widening strict mode allows. There is no weak
mode and no coercion.

That is a divergence and it is the honest one to take. An extension's function is an INTERNAL
function, and for a real C extension what decides weak-or-strict is the `declare(strict_types=1)`
of the file that CALLS it, resolved inside ZPP. mc-php generates its own check, so it cannot see
the caller's declaration. A caller under `strict_types=1` gets exactly php's behaviour; a caller
without it gets a `TypeError` where php would have coerced. Write `declare(strict_types=1)` in
the caller and the two agree.

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

* **Output buffering.** The runtime writes what a php function `echo`s straight to fd 1; php's
  own `ob_start()` never sees it. Measured on 2026-09-23: with `ob_start(); echo "A";
  hello_say("B"); $x = ob_get_clean();` the interpreted run captures `A[B]` and the module's `[B]`
  is already on the terminal. Ordinary output is in php's own order because the CLI SAPI does not
  buffer. **The fix is named**: `php_output_write` is exported, and routing `php_flush`'s one
  `write(1, ...)` through a sink the extension road sets is the whole of it -- it touches the
  runtime's hot path, so it belongs to a step of its own with its own bench row.
* **An exception the body throws** crosses as its own class when php has one of that name --
  every built-in does, so `throw new InvalidArgumentException(...)` arrives as itself. A class
  the SOURCE declares is not in the engine's class table (the back end registers no class yet),
  and the fallback is a plain `Exception` whose message names it.
* **Destructors and `register_shutdown_function`** do not run. A program ends and D7's arena is
  released; a module does not end, and `module_shutdown_func` is 0 on purpose -- running
  `php_shutdown`'s destructors into a stdout the SAPI is tearing down would be worse than not.
* **The type check is strict always**, as above -- and the RETURN is not checked at all. Measured
  on 2026-09-23: `function f(): int { $s = "x"; return $s; }` answers `int(0)` in the module and
  throws a `TypeError` interpreted. That is D4/D9's return coercion and it is the FRONT end's:
  the program road gives `int(0)` for the same source, so a module and a `mc-php --exe` binary
  agree with each other and not with php. Closing it means a return check in `ph_function`,
  which moves the program road and the `.phpt` grid, so it is a step of its own with its own
  re-measured numbers. Found by the reviewer of #15.

## Thread safety

`[php].thread_safety` is carried into the module header because the loader compares it, and a ZTS
php refuses an NTS module by name. It is **not** a claim that the runtime is thread safe: D7's
arena, the class table and the pending-exception flag are process globals, and a ZTS php running
two requests in two threads through one loaded module would share all three. Nothing here has
been run under a ZTS php. Build for the php you have, and until that measurement exists, that
php should be NTS.

## The memory

`docs/plan.md` D7 is unchanged: one 48 MiB arena per PROCESS, never freed. That is a program's
model and a module lives longer than a program, so a long-running php that calls an mc-php
extension in a loop will exhaust it. Nothing here bounds it; it is the first thing a request
lifecycle (`RINIT`/`RSHUTDOWN`) would answer, and it is not built.

## Two extensions in one process

Both would define `php_alloc`, `ph_heap`, `php_bootstrap` and every other runtime symbol, and the
namespace a php extension is loaded into is FLAT -- the first one loaded wins, in silence. The
example's link line exports everything, which is what makes the two collide.
`docs/mcphp-toml.md` § The symbol prefix is the design that answers it;
[`reference/extA.mc`](../reference/extA.mc) and [`reference/extB.mc`](../reference/extB.mc)
are the measurement it rests on. Neither is implemented, and until one is, **load one mc-php
extension per process**. The cheap half of the fix is a linker argument and nothing else --
`-exported_symbols_list` naming only `_get_module` on macOS, a version script on Linux -- and it
is not taken here because the schema's answer is the prefix and picking the other one by accident
would be worse than saying so.

## Windows

The same source and the same emitter; three things differ, each measured on the Windows runners
and each said in `examples/hello/mcphp.windows.toml`:

- **The link.** `lld-link -dll -noentry -export:get_module`, against `php8.lib` (or `php8ts.lib`
  for a thread-safe php), `kernel32.lib` and `ucrtbase.lib`. All three are IMPORT libraries,
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
`mc-php build` IS `mc build` and mc's driver ignores a table it does not know. What is in the
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

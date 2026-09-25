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
the Zend Memory Manager, and a STRING has php's own lifetime -- one `_emalloc` block laid as a
`zend_string`, a refcount, and `_efree` when the last reference goes. The runtime keeps ONE
allocation seam with two implementations chosen by road (`lib/php_rt.mc` § the allocation seam
and § who owns a string): the arena (a program, and a module's MINIT) or Zend's allocator (a call).

| lives for | what | where |
|---|---|---|
| the module | what MINIT builds -- the bootstrap classes, the source's classes and top-level constants -- every string LITERAL, and `$s[$i]`'s 256 one-byte strings | the module's own static arena, never freed. A string there carries `IS_STR_INTERNED` (`GC_IMMUTABLE`): nobody counts it, nobody frees it, nobody writes into it, and php, handed one as a result, treats it as the interned string it is |
| its last reference | every string a call builds | one `_emalloc` block of its own, a `zend_string` with refcount 1 and `GC_STRING`, `_efree`d at zero -- php's `zend_string_release`, persistent ones through `free(3)` as `pefree` does |
| one call | the zvals, arrays, objects and class entries a call builds | a 32 KiB Zend chunk the request reuses, bumped through; every other block the call took is freed when it returns. Nothing is zeroed |
| the request | what a call that writes MODULE STATE kept -- a `static`, a `global`, `define()`, an error or exception handler, a class, a file, a destructor, an output buffer left open | the call PINS itself: its chunk part stays, and so do the references its blocks hold on strings; RSHUTDOWN puts the state back as MINIT left it and releases them |

**Who holds a reference to a string** (`src/rc.mc` for the compiled code, `lib/php_rt.mc` for the
runtime):

* **a temporary** -- what a runtime call answered and nothing took yet -- sits on the runtime's
  POOL with one reference, above the building function's entry mark. The top of every loop
  iteration and every return drain the function's own part of it, which is php's rule that a
  temporary dies with the statement that used it: a loop inside ONE call keeps a bounded
  high-water mark (`tests/ext.sh` step 12). A string a function returns comes out as the
  caller's temporary, exactly like a runtime call's -- or, when it is a string parameter the body
  never assigned, as the caller's own string, which it holds already;
* **a counted slot**, in a function that LOOPS -- a php variable of type `string`, a string
  parameter the body assigns, and the compiler's own string temporaries. The slot is declared
  0; a store takes the new value's reference (the pool's own, when the value is the temporary on
  top) and releases the old value's; the function releases every slot on its way out, the
  exceptional early return included. A function with NO loop never drains before it returns,
  so there its locals BORROW from the pool and nothing is counted: every string it built stays
  alive until the return that drains them all. A parameter the body never assigns is read where
  it stands in either kind: the caller holds it for the call, as php holds an argument. The
  take, the release and the pool push are written into the function itself, not called
  (`src/rc.mc`);
* **a container that is not counted** -- a zval, an array key, a class entry -- takes a reference
  of its own when a string is put into it (`php_str_esc`), and that reference lives as long as
  the container does: until the call's chunk goes, or until RSHUTDOWN for a call that pinned.

**The boundary copies nothing.** A string ARGUMENT is the engine's `zend_string`, borrowed: the
module never writes into it except the hash (the same DJBX33A, top bit set, that
`zend_string_hash_val` stores, and never into an interned string, whose hash is set), and a
store that keeps it past a statement takes a reference like any other. A string RESULT is the
same `zend_string` the function built -- `return_value` takes the reference the answer carried
as the call's temporary -- and a literal goes out as the interned string it is (`IS_STRING`,
no reference). Before, a result was built in the call's chunk and copied into a fresh Zend
string on the way out (`phx_ret_str`).

**A string with one reference is written in place**, as php does. `$s .= x`, `$s = $s . a . b`
and `$s[$i] = c` on a string nothing else holds grow or write it where it is -- `_erealloc`,
php's `zend_string_extend` for a refcount-1 left operand -- and anything else (an interned
string, a literal, a string a second variable or a zval also holds) is copied first, the copy
becoming the slot's own. `tests/ext.sh` step 11 counts the two: with `MCPHP_STATS=1` in php's
environment the module prints `mc-php stats: in place N, copied M, strings built K` at the end of
each request -- K every string the request built, a copy included, which `tests/examples.sh`
gates for `examples/decimal`.
That is the counted slot's privilege: a function with no loop copies on `.=`, because nothing
says the pool's reference is the only one (and it appends a bounded number of times).

**RSHUTDOWN is the request's end, as php has one.** It is the `request_shutdown_func` slot of the
module entry (`docs/php-abi.md`). Statics a request initialised go back to "never run", files it
opened are closed, an output buffer it left open is written out, the runtime's roots (the global
table, constants, handlers, the class table, the pending exception, `error_reporting()`) are
restored from the copy taken when MINIT ended -- and, if a call pinned, the arena itself. Then the
references pinned calls kept are released and the request's blocks freed. `RINIT` is 0: a request
starts from the state the last RSHUTDOWN restored, so there is nothing to set up.

**Why zvals, arrays and objects still live in the call's chunk.** They have no count in this
runtime, and giving them one is not a change to one seam: a php array is a VALUE the runtime
copies eagerly (D7's own rule), a zval is copied bitwise at 114 sites of the runtime (56
`php_zv_cp`, 58 `php_zv_cpv`), and a handle to either is passed by raw pointer through the 501
runtime functions the compiler calls, none of which says who owns what. A string needed its OWNERS
found -- the compiler's typed slots and the four places the runtime stores one into a container
-- and those were countable; the containers' owners are not yet, and a count that is wrong frees
a live array. So a zval, an array or an object lives as long as the call that built it (or the
request, for a call that pinned), exactly as before -- which is also why a loop that builds zvals
inside one call grows until the call returns, where a loop that builds strings does not.

**What was audited instead of zeroed.** A reused chunk and an `_emalloc` block hold whatever was
there before; the call's chunk used to be zeroed on the way out (`phx_zero`, 4.1% of the module's
time) because the runtime's allocations assumed zeroed memory. Every allocation site was read
for a reader that depends on it: the 56 `php_str_alloc` sites write every byte they allot (27 of
them shrink the length afterwards, and each of those writes the NUL at the new end), and the 29
`php_alloc` sites either write each field before it is read (a zval's both words, a hash's
header and its slot table, an object's header but the four padding bytes at +12 that nothing
reads, a class entry's thirteen fields) or zero what they
read on purpose (`md5`/`sha1`'s padding block). The one allocation that relied on zeroed memory
is `ph_ch1`'s table of one-byte strings, which lives in the arena and the arena is fresh `__bss`.

**Graded without an extension, too.** The phpt grid runs the program road, which never counts
(every string there is the arena's and immutable). Compiled with `MCPHP_RC=check` in the
compiler's environment -- `tests/mcphp.sh` passes it on as `MCPHP__RC=check` -- a program counts
its arena strings exactly as a module counts Zend ones, drains its temporaries after every
statement rather than every loop iteration, and POISONS a string that reaches zero instead of
freeing it (a length no string has, and a use of it dies with
`mc-php: MCPHP_RC=check: a string was used after its last reference went`). The fixtures and the
three grid directories compiled that way must answer exactly what they answer without it. They
do: 109/109 fixtures in both builds (`tests/run.sh` and `tests/linux.sh` run the second pass), and
the grid's 15 lists hold the same test names in both (green 104 / 766 / 272), with no dead-string
message anywhere.

Measured (2026-09-24, macos/arm64, php 8.5.10):

* **1 000 000 `dec_add` calls in one request** (`examples/decimal/soak.php`, after a thousand
  warm-up calls): `memory_get_usage()` 517 336 -> 517 336 bytes, `memory_get_peak_usage()`
  517 544 -> 517 560. The peak follows the size of a call's own temporaries, which grow with the
  accumulator (three more digits over the million calls); the gate allows a kilobyte. Before
  batch A the same loop died with `mc-php: arena exhausted` near 29 000 calls; after it, and
  before this change, the peak did not move at all, because the chunk was a fixed 32 KiB.
* **100 000 iterations inside ONE call**, each building two 1 KB strings (`tests/ext.sh` step
  12): php's peak moved **0 bytes**. On the batch-A runtime the same function died with php's
  `Allowed memory size of 134217728 bytes exhausted`: the chunk kept every string until the
  call returned.
* **`$s .= "x"` 100 000 times in one call** (step 11): 100 002 writes in place and 2 copies, the
  answer php's. On the batch-A runtime it exhausted php's memory the same way (every `.=` a copy
  kept until the call returned).
* **20 requests through `php -S`** (step 10): every response the interpreted source's.
* **Leaks** (`tests/leaks.sh`): php 8.5.10 built with `--enable-debug` from the
  `php:8.5-alpine` image's own source, linux/aarch64 (docker inside a Lima VM on this Mac), and
  `examples/decimal`'s check, soak (100 000 calls) and bench plus the ownership shapes, a pinned
  call and a loop inside one call run in it: the debug allocator reports **no block left** at the
  end of any request. The check is proved to see a leak: with RSHUTDOWN's release of a pinned
  call's strings disabled it reports `mc-php(0) :  Freeing ... (38 bytes)` and
  `=== Total 27 memory leaks detected ===`. macOS's `leaks` (with `USE_ZEND_ALLOC=0`) could
  not be used: it cannot read Homebrew's php ("Process ... is not debuggable. Due to security
  restrictions, leaks can only show or save contents of readonly memory of restricted
  processes"), so the check runs on Linux.

What a pinned call costs, measured before this change: a function with a `static $n` called
100 000 times in one request kept **32 bytes a call** until the request ended (3.2 MB); the next
request started clean. A pinned call no longer keeps a reference on every string argument it
borrowed -- a string it stored is referenced by the zval that holds it, and one it did not store
is not kept at all.

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
allocator, branch peephole and loop hoisting), which the project file of every extension this
repository BUILDS from php carries (`examples/hello`, `examples/decimal`; the files of
`two-extensions` and `awaitable` exist to pin a refusal and compile nothing). An extension is called from a php that is already warm, so the generated code
is the whole cost: `examples/decimal` measured 2.79 ms without it and 1.64 ms with it
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

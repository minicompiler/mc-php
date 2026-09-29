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

Plain functions, with any parameter and return a php function may declare -- **except a
reference** across the boundary:

| | parameter | return |
|---|---|---|
| `int`, `float`, `string`, `bool` | yes, read in place (the fast road) | yes |
| `void` | -- | yes |
| `array`, `?array` | yes | yes |
| `mixed`, untyped, a union | yes | yes |
| `callable` | yes | -- |
| `object`, a class, `?Class` | yes | yes |
| a default value | yes | -- |
| `T ...$rest` | yes | -- |

Each argument is checked the way php's own parameter parsing checks an internal function's, with
its words: `f(): Argument #1 ($a) must be of type array, int given`, `must be of type ?array`,
`must be a valid callback, function "nope" not found or invalid function name`,
`f() expects at least 1 argument, 0 given`, `... at most 2 arguments, 3 given`. A variadic
argument is named by number alone (`Argument #2 must be of type int`), as php names it. The
argument records say the same types, so Reflection reads what the source declared. What a
USERLAND function says differently -- a `called in FILE on line N` tail, `Too few arguments to
function`, extra arguments ignored -- is not what an internal function says, and the module is
one (`tests/ext.sh` step 17 compares its answers with the interpreted source's and its errors with
a recording).

php's **arrays and objects** cross both ways (`lib/php_ext.mc` § engine values). An array is a
VALUE in php and crosses as a copy: into the runtime's own array on the way in, into a new engine
array on the way out. An object crosses as ITSELF: inside the module a php object is a proxy of
the engine's -- its properties read and written, its methods called, `get_class`, `instanceof`
and `===` answered by the engine, with the engine's rules and errors -- and the same object goes
back out. Every array or object the module holds is a reference it took, given back when the
call's memory goes (or at RSHUTDOWN for a call that pinned); `tests/leaks.sh` runs the same module
300 times under a debug php and nothing is left. The same crossing serves a call through php's
function table (§ A call to a function the source does not declare): an array or an object is an
argument and an answer there too. What does not cross: a php resource, and an object of a class the module
keeps private (`_Name`).

**Classes are published** as functions are: every class whose name does not begin with `_` is
registered with the engine at MINIT as an internal class of that name (`lib/php_ext.mc`
§ published classes) -- its declared properties with their defaults and visibility, its
methods as internal methods whose handlers run the compiled bodies, `final` and `abstract` as
declared. Every object of it, made by php (`new Box(3)`) or by the module (`new Box` inside a
function), is the engine's, and the module holds it as a proxy: `$this->n` in a method is the
engine's property read with the class as the scope, so a private property is the method's and
nobody else's -- `$b->secret` from php is php's own `Cannot access private property`. What is
published is a plain class at a file's top level; the rest is refused by name: an interface, a
trait, an enum, `extends`/`implements`, a static method or property, an abstract method, and a
property whose default is not a scalar (an internal class's default is the engine's to keep for
the process). A method's arguments are checked by its compiled body, which is a userland
method's check (`Too few arguments to function Box::add()`), and a published method takes at
most six. `tests/ext.sh` step 18 runs a module that publishes a class, loaded and interpreted,
byte for byte.

**A php callable is called** as a C extension calls one (`lib/php_ext.mc`'s `phx_vcall`): a
value the module received -- a function's name (`'strtoupper'`), `"C::m"`, an array callable, a
`Closure`, an object with `__invoke` -- called with `$fn(...)` goes through php's own
`_call_user_function_impl`, a spread's arguments counted as php counts them. What the callable
throws is the module's to catch, as the same source interpreted would catch it; a value that is
not callable is php's own `Error` in the words `$f()` uses (`Call to undefined function nope()`,
`Object of type stdClass is not callable`, `Value of type int is not callable`) -- except for an
array and a `"C::m"` string, where it is `zend_call_function`'s `Invalid callback ...`. A
**throwable the module keeps** -- caught and stored, or made with `new` and returned -- crosses
back as the engine's object of that class with its message and code (`phx_exc_obj`), and one
the module caught from php crosses back as the very object php threw. `tests/ext.sh` step 19
runs such a module, loaded and interpreted, byte for byte.

```
hello.php:3: mc-php: an interface an extension would publish: I is not implemented yet
hello.php:7: mc-php: a by-reference parameter in an exported function: f is not implemented yet
hello.php:7: mc-php: a by-reference return in an exported function: f is not implemented yet
```

A php `count()` of an engine object that is `Countable` is not the object's count yet (the
runtime has no Countable), and `var_dump` of a proxy shows no properties.

One more is worth naming because it is ordinary php and the reason is not obvious:

```
hello.php:4: mc-php: an exported function called before it is declared (move it above its first call): b
```

php HOISTS a global function, so calling one declared further down the file is legal -- but D4
builds that call against a zval signature and then widens the declaration to match it, and a
widened signature is not exportable. **Declare before the first call**, which is the fix the
message names. Closing it properly means teaching the byte pre-scan the declared TYPES, which
would move every forward call's lowering on the program road too; that is a step of its own.

**Namespaces** are php's, on both roads (`src/ns.mc`): a declaration in `namespace aw\util;` is
`aw\util\name`, published under that name; `use` imports a class, a namespace, a function or a
constant, alone, aliased or grouped; a class name has no fallback, and an unqualified function or
constant falls back to the global one -- the source's own `aw\util\f` when it declares one, else
php's `f`, and on the extension road a name neither the source nor the library has is looked up
in php's function table as `aw\util\f` and then `f`, as php does. `__NAMESPACE__`, `X::class`
and `get_class()` answer the qualified names, and both forms are read, `namespace X;` and the
braced `namespace X { ... }` / `namespace { ... }`, at a file's top level only, as php reads
them: in a function body or a block, and a namespace inside a braced one, they are refused while
compiling. A leading underscore
makes a function module-private under its namespace too (`aw\util\_h`).

**A C function** is declared in php with `#[Extern('lib')]` and an empty body
(`src/extern.mc`, both roads), and called like any function the source declares:

```php
#[Extern('c', name: 'atoi')] function c_atoi(string $s): int {}
#[Extern('curl')] function curl_easy_init(): Ptr {}
#[Extern('curl', variadic: 1)] function curl_easy_setopt(Ptr $h, int $opt, mixed $v): int {}
#[Extern('c')] function strerror(int $e): string {}
```

The declaration is the ABI. `int` is C's `int` (a returned one is sign-extended from bit 31, since
the ABI leaves the bits above it unspecified); `Ptr` is a pointer-sized integer (a pointer,
`size_t`), php's `int` to the source; a `string` parameter is `const char *` to the string's own
NUL-terminated bytes and a `string` return a C string copied into a php one (`""` for null); a
`bool` parameter is 0 or 1; a `mixed` parameter is decided per call by the value -- an int, a
string's bytes, a bool, null as 0, anything else php's `TypeError` with no C call. `void` returns
nothing. `errno` is a macro in C and not a symbol: `#[Extern('c')] function errno(): int {}`
reads the calling thread's error number where the host keeps it (`__error()` on macOS,
`__errno_location()` on Linux), so the source can ask it right after the call that failed, as
C does. A C function may WRITE into a `string` argument's bytes -- `pipe()`'s two descriptors,
`read()`'s buffer, `waitpid()`'s status -- only when the string is one the module made at run time
for it, of that length (`str_repeat("\0", 8)`), and never a literal, which may live in read-only
memory; the bytes are read back with `unpack()` or `substr()`. `examples/awaitable` passes its
buffers so until native memory has a surface of its own. `variadic: N` marks the last N parameters as the C variadic ones: Apple's arm64 passes
those on the stack after the eight argument registers, so there the fixed arguments are padded to
eight; elsewhere a variadic int travels as a fixed one. The C symbol is the function's name
without its namespace, or `name:` when the php name is another one (`name:` is validated as a C
identifier); declarations that share a symbol share its one C declaration, the first fixing how
many argument words it takes (a later one with more is refused: declare the widest first). The
body is `{}`, which keeps the file php, or `;`. The declaration is never published. The attribute is the item of its
list whose NAME is `Extern` (or `\Extern`) -- `#[Doc("Extern")]` is not -- and it annotates the
function right after it: before anything else (a statement, a class member, a `namespace`, a
`use`, a closure) it is refused at the attribute's own line, so it can never reach a later
declaration. A name that is one of the runtime's own functions is refused too. On the extension road the symbol
comes from php's own process, as every Zend name does; on the program road from the C library, so
the library named is `c` or `pthread`. **Windows refuses it by name**
(`an #[Extern] function on Windows: the link names no library for it`): its link names each
import library, and none is named for a C function the source declares.

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

* **C's rules, always** ([semantics.md](semantics.md)). An int that overflows in `+ - *` wraps,
  and a string offset or a packed array element read outside its range is undefined behaviour,
  not php's warning. Inside php that read is memory the process owns, so build an extension with
  `[php] checked_reads = true` to find one (a trap that names the line). A read inside the range,
  and everything else, is php's answer.

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
* **An exception the body throws** -- or a throwable it returns or stores -- crosses as its own
  class when php has one of that name, with its message and code: every built-in does, so
  `throw new InvalidArgumentException(...)` arrives as itself. A throwable class the SOURCE
  declares is not published (a published class may not `extends`), and the fallback is a plain
  `Exception` whose message names it. Its file and line are the statement php was running when
  it crossed, not the module's `new`.
* **Calling a non-callable array or `"C::m"` string** is php's `Error` with
  `zend_call_function`'s message (`Invalid callback ...`), not the one `$f()` says in a script.
* **A published class's `__destruct` runs at the end of the module's call** when the last
  reference to the object dies inside the module (an object the module makes and drops): what a
  call holds of the engine's is released when the call returns to php, not when a variable goes
  out of scope. An object php holds is destroyed where php destroys it. For the same reason a
  method of a published class called from a loop INSIDE the module keeps what each call made --
  measured at about 500 bytes a call -- until the module's call returns: a million such calls in
  one call exhaust a 128 MB `memory_limit`.
* **Destructors of the program itself and `register_shutdown_function`** do not run. A program
  runs them when it ends; a module's request end (RSHUTDOWN) restores state and does not call
  back into php code, and
  `module_shutdown_func` is 0 on purpose -- running `php_shutdown`'s destructors into a stdout
  the SAPI is tearing down would be worse than not.
* **The argument check is strict always**, as above. The RETURN is checked on both roads with
  php's own rule and php's own `TypeError` (`f(): Return value must be of type int, string
  returned`), the same check a declared parameter goes through on the program road; `tests/ext.sh`
  step 8 compares the module's answer with the interpreted source's.

## Thread safety

`[php].thread_safety` says which php the module is for: `"nts"` (the default), `"zts"`, or `"both"`
for one of each from the same project ([mcphp-toml.md](mcphp-toml.md) § `php.thread_safety`). The
loader compares the header's `zts` and build id, so a php refuses a module built for the other
kind, by name.

A ZTS module differs from an NTS one in four places, all in `lib/php_zts.mc`, the ZTS-only swaps
`src/program.mc` lists and `src/tls.mc`'s lowering, and pushed only for a ZTS output
([threads.md](threads.md) § ZTS has the whole model and its measurements):

- **the engine's globals.** A ZTS php has no `executor_globals` symbol. Its executor globals are
  the calling thread's TSRM block plus `executor_globals_offset`, and php exports
  `tsrm_get_ls_cache` and that offset; the module reads them on each php thread, never once for
  all. `EG(exception)` is at the same offset on both builds: `tests/ext/abi.c` prints 960 against
  the NTS and the ZTS headers alike, and the runtime still measures it at the first call. A php
  that exports neither name is refused from `get_module` by name, as an `E_CORE_ERROR`.
- **every php thread.** The module declares TSRM module globals, so php gives each of its threads
  a runtime block; a threaded SAPI (FrankenPHP) runs requests on several of them at once.
- **the module state.** The global variables, the constants, the class registry, the functions'
  statics, the classes' static properties and the call sites' caches are per php thread, and each
  request starts from a copy of what MINIT left. MINIT's own memory is read by every thread and
  written by none; `tests/frankenphp.sh` makes it read-only while it runs to prove it.
- **Windows.** The ZTS php is `php8ts.dll`. The module is linked against `php8ts.lib`, and the
  runtime's `php_dlsym` asks `php8ts.dll` for the names it looks up at load.

**An NTS module is byte for byte what it was before thread safety was a choice.** The `cmp` of
every NTS output this repository builds, before and after, is in the PR that added it.

The runtime keeps its own state per thread (`docs/threads.md`). A worker thread that the module
starts still gets an Error when it reaches php's engine. That is interim until step 3 on both
builds.

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
find the first one loaded. Nothing here looks one up: one extension reaches another through php's
own function table (below), as a C extension does. `docs/mcphp-toml.md` § The symbol prefix is the design that gives each module
names of its own; it is not implemented. The cheap half would be a linker argument --
`-exported_symbols_list` naming only `_get_module` on macOS, a version script on Linux -- and it is
not taken here because the schema's answer is the prefix.

## A call to a function the source does not declare

php resolves a call when it RUNS, in its function table; an extension's source may call a
function another extension publishes, php itself has, or the script defines -- and on the
extension road mc-php compiles such a call to exactly that (`lib/php_ext.mc`'s `phx_fcall`), which
is also what a C extension does to call another extension's function
([`examples/two-extensions`](../examples/two-extensions/) and its C twin, `c/extB.c`):

- the function is looked up in php's table (`zend_fetch_function_str`, the lowercased name) the
  first time the call site runs in a request, and cached in two words beside the call site for
  the rest of it (a userland function is gone at the request's end, so RSHUTDOWN moves the
  request counter on);
- the arguments are laid out as engine zvals on the stack -- an int, a string and a bool as
  themselves, anything else through a runtime zval -- and the call is
  `zend_call_known_function`; what the module echoed so far is flushed first, so output keeps its
  order;
- the answer is a value, typed by its context with php's rules. As the value of `return` in a
  function declared `: int` it is read straight out of the engine's zval when it is an int (two
  int arguments take one call, `phx_fcall_l2`), and php's return-value rule applies otherwise;
- an exception the callee throws is taken off the engine and stands in the runtime as the nearest
  class the runtime knows, with the same message, code, file and line, so the module's own
  `catch` sees it; uncaught, the ENGINE's object goes back into php, class and trace intact. A
  name php does not have is php's own `Error`, `Call to undefined function NAME()`;
- the module may be re-entered through the callee (tests/ext.sh step 14).

What does not cross, by name: a php resource, either way (`mc-php: a php resource returned by
NAME(): a resource does not cross php's function table`); an array or an object crosses as
§ What a source may say today describes. Argument unpacking and more than 4 arguments are refused
while compiling. A by-reference parameter of the callee gets a value, and php warns.
On the PROGRAM road there is no other module to call, and such a call stays the refusal it was.

**A handler that needs no runtime.** A published function whose body, copied into its handler,
calls nothing but mc's loads -- `a_add`'s `return $a + $b;` -- is compiled as a C handler is: the
count and the tags tested in place, the body, the answer stored, returned. Everything else (the
call context, the checks that raise php's errors) is a second function the handler tail-calls when
a check fails, so the handler is a leaf. A body whose only other call is one through the function
table with an int answer (`b_use`) keeps that road too: the call takes a call context only on its
slow side and gives it back before the handler returns (`phx_enter_lz`/`phx_leave_lz`).

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
| `php.thread_safety` | `"nts"` (default), `"zts"` or `"both"` -- `Thread Safety`; see [Thread safety](#thread-safety) |
| `php.debug` | required -- `Debug Build` |

and mc's own `[project]`, `[linker]`, `[target]` and `[include]` carry the rest, because
`mc-php build` IS `mc build` and mc's driver ignores a table it does not know. One of mc's keys
matters here more than on the program road: **`[project].opt = 1`**, mc's optimizer (its register
allocator, branch peephole and loop hoisting), which the project file of every extension this
repository BUILDS from php carries (`examples/hello`, `examples/decimal`,
`examples/two-extensions`; the file of `awaitable` exists to pin a refusal and compiles nothing). An extension is called from a php that is already warm, so the generated code
is the whole cost: `examples/decimal` measured 2.79 ms without it and 1.64 ms with it
(`docs/plan.md` § 7). A taught compiler cannot set it for you -- mc applies its optimizer level
after the module's `user_init` has run -- so it is a line in the file. What is in the
schema and **not** implemented: `extension.prefix` (nothing but `get_module` needs a name, see
above), `extension.entry`/`sources`/`out` (mc's `[project]` says those), `[[extension.deps]]`,
`[libs]`/`[externs]`/`[linker]` per OS -- mc's `[linker]` is flat, so a second host is a second
file, which is how this repository already spells its own cross-builds -- and `php.bin`, which is
a NAMED refusal:

```
mcphp.toml:1: mc-php: [php].bin is not implemented: state php.api, php.build_id and php.debug,
and php.thread_safety unless it is nts (php -i prints all four)
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

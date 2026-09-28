# two-extensions -- one extension calls another, compiled from PHP

`extA.php` publishes `a_add`; `extB.php` publishes `b_use`, which calls `a_add` -- a function
B's own source does not declare. `mc-php build` compiles each into its own module, and php
loads both:

```sh
mc-php build examples/two-extensions --config examples/two-extensions/extA.toml
mc-php build examples/two-extensions --config examples/two-extensions/extB.toml
php -d extension=examples/two-extensions/build/extA.so \
    -d extension=examples/two-extensions/build/extB.so -r 'echo b_use(40, 2), "\n";'
# 42
```

php resolves a call when it RUNS, in its own function table, and so does the compiled `b_use`:
the name is looked up there the first time the call runs in a request (`zend_fetch_function_str`)
and cached beside the call site for the rest of it, the two ints are laid out as engine zvals on
the stack, and the call is `zend_call_known_function` -- what a C extension does to call a
function that belongs to another extension, and what `c/extB.c` does. The order php loads the
two in does not matter, and with A absent `b_use` throws php's own `Error`,
`Call to undefined function a_add()`, as the source does interpreted. `docs/php-extension.md`
§ A call to a function the source does not declare is the whole rule: what crosses, what is
refused by name, and what happens to an exception the callee throws.

| file | |
|---|---|
| `extA.php`, `extB.php` | the two sources |
| `extA.toml`, `extB.toml` | one project file per extension (macOS); `*.linux.toml` and `*.windows.toml` are the same files for the other hosts, as `examples/decimal` has one per host |
| `c/extA.c`, `c/extB.c` | the C TWINS: the same two functions written as ordinary C extensions, the specification the compiled pair is measured against |
| `check.php` | the differential: A and B loaded (compiled, or the twins) against the two sources required |
| `alone.php` | B without A: php's own `Error`, twice |
| `bench.php` | the bench row |

## How it is checked -- `tests/examples.sh`, on all five hosts

| step | |
|---|---|
| the differential | `check.php` runs with the two modules loaded -- **in both orders** -- and with `extA.php` and `extB.php` required, and the runs must print the same bytes on both streams and exit the same |
| B alone | `alone.php` with only B's module loaded, against `extB.php` alone: `Error: Call to undefined function a_add()`, twice (a lookup that failed caches nothing) |
| the C twins | `c/extA.c` and `c/extB.c`, built with `php-config` and `cc` where the host has both, graded by the same `check.php` and `alone.php`; elsewhere `SKIPPED`, and the bench has two columns |
| the bench row | `bench.php`: `b_use` 100 000 times from a php loop -- a call into B and from B into A through php's table -- and `a_add` 100 000 times straight from php, a warm-up and the best of nine per process, the interpreted, compiled and twin processes interleaved three times. The answers must be equal; the ratios are printed and not gated |

`tests/ext.sh` step 14 grades the same road with more on it: a module calling the script's own
php functions with every value that crosses, an exception thrown by the callee caught by the
module and uncaught across it, an undefined function, output ordered around the call, the module
re-entered through the callee, and the two refusals.

## The three columns

Measured on 2026-09-28 on this repository's Mac (macos/arm64, php 8.5.10), the through-B row of
`bench.php`, fifteen rounds with the processes interleaved, each process the best of nine. The
machine ran slower in this sitting than in the ones before it (the same interpreted row was
2.2-2.3 ms earlier the same day); the ratios, taken per round, are what compare:

| | through B, 100 000 calls (median of 15) | per round against the twins |
|---|---|---|
| interpreted (`extA.php` + `extB.php`) | 4.330 ms | 1.215 (1.163-1.276) |
| compiled by mc-php | 3.906 ms | **1.083 (1.038-1.174)** |
| C twins | 3.579 ms | 1 |

The module is faster than the interpreter in every round (module / interpreted 0.882, 0.830-0.987)
and under 2x the twins in every round. Per call, over a million calls minus a loop that calls
nothing (cycles, instructions retired, the best of three): `b_use` 67 cycles / 484 instructions
against the twins' 64 / 428 (the first compiled `b_use` was 131 / 973); `a_add` 21 / 102 against
11 / 111 -- a per-call noise of about ±5 cycles in this sitting, where earlier sittings gave
12 against 20.

On the pull request's CI run (`tests/examples.sh`, three rounds interleaved, minimums; the twins
are built only where the host has `php-config` and `cc`):

| host | interpreted | compiled | compiled / interpreted |
|---|---|---|---|
| macos/arm64 (`macos-15`) | 3.430 ms | 2.786 ms (twins 2.488) | **1.23x** faster |
| windows/x86_64 | 9.859 ms | 6.780 ms | **1.45x** faster |
| windows/arm64 (x64 php emulated) | 16.378 ms | 11.257 ms | **1.45x** faster |
| linux/aarch64 (`php:8.5-alpine`) | 3.644 ms | 4.110 ms | 0.89x -- slower |
| linux/x86_64 (`php:8.5-alpine`) | 3.346 ms | 4.034 ms | 0.83x -- slower |

**On the Linux image the C twins are slower than the interpreter too.** Measured on
`php:8.5-alpine` in the Lima VM `mc-k7` (linux/aarch64), with the twins built there with `cc`,
nine rounds: twins / interpreted 1.10 (0.96-1.51), compiled / twins 1.09 (0.81-1.15), compiled /
interpreted 1.19 (1.01-1.24). There a call from one extension into another through
`zend_call_function` costs more than php's own userland call, and the module and the twin both
pay it: the row straight into A, which has no such call, is faster compiled on both Linux legs
(1.484 against 2.273 ms, 1.576 against 1.894 ms).

**Kept as it is, by the owner's decision (2026-09-28).** The C twin makes the same call, through
`zend_call_known_function`, and on that image both are slower than the interpreter: that is
php's own cost for calling from one extension into another, not the module's, so the module does
what the twin does and does not go round it (by calling an internal callee's handler directly,
say).

This is not an arithmetic benchmark. Almost all of a call's time is php's -- the VM's call of an
internal function and `zend_call_function`, the same in all three columns -- so the interpreted
column is only ~1.2x the twins', and "faster than interpreted" left the module ~20% of room.

## What the C twin showed, and what was built

The twin's `b_use` is ZPP inline, the cached lookup, two `ZVAL_LONG`s, the call, one tag test
and `RETURN_LONG`. The first compiled `b_use` took twice its time per call and was SLOWER than
the interpreter (3.6 ms against 2.2 ms in that sitting). The diff, row by row, and what was built
for each -- one change at a time, each measured:

| the twin | mc-php, first | built | per call (`b_use`) |
|---|---|---|---|
| the arguments as zvals on the stack, the answer read as an int | each argument boxed as a runtime zval and copied into an engine zval by a helper each, the answer boxed again, then php's return-value coercion and a mixed-to-int conversion | the (value, kind) arguments packed in registers, the engine zvals on the stack (`phx_fcall`); on `return` in a `: int` function the int read straight out of the engine's zval (`phx_fcall_l`) | 131 -> 104 |
| no call context | `phx_enter`/`phx_leave` around every handler | the BARE road: a handler whose body calls nothing (`a_add`) or only such a call (`b_use`) runs with no context; the call takes one on its slow side only (`phx_enter_lz`) | 104 -> 76 |
| two int arguments, one call | the generic call | `phx_fcall_l2`, the two-int form written in place | 76 (within noise) |
| the argument read where it is used | the handler's argument copied into a local, reread | a load of a pure address is substituted where the parameter is read when the body writes no memory, and a handler's own argument always (`src/opt.mc`); a `return E` body whose dead tail follows the return is copied as E | `a_add` 111 -> 102 instructions |
| `RETURN_LONG` in place | a call to `phx_ret_int` | two stores (`src/ext.mc`) | |
| a leaf `a_add` | a frame and saved registers for the slow road's sake | the slow road is a second function the handler tail-calls, so a pure handler is a leaf (P11) | `a_add` at the twin's |
| nothing but the arguments on the hot path | the name, the caller's name and the packed word passed on every call | kept in the call site's own words (`phx_fcall_l2(cache, v1, v2, lazy)`); the position announcements dropped on the bare road, where nothing can catch | 76 -> 60-67 |

Found on the way and fixed: P11 (`src/mach.mc`) dropped EVERY frame load or store of a register
it moved, taking an ordinary copy from a frame-resident local for a restore; a leaf that had one
read garbage (`tests/ext.sh` step 7's nested function answered 4446605840 for 22 once its handler
became a leaf). It drops a register's save and its restore only, now.

## The floor

What is left between the module and the twins is small and diffuse. `b_use`'s call through the
table is one call level more than the twin's: the runtime's `phx_fcall_l2` holds the stack
buffer, and mc-php cannot put it in the handler -- the inliner refuses a function with an array
local -- and mc's allocator gives that routine's values callee-saved registers, saved and
restored on every call. Then the lazy-context test at the end of the bare road and the unwinding
test after the call. Each is a cycle or two, inside the per-call noise; the rest is php's.

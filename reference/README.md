# reference -- hand-written mc, not mc-php output

**Every file here was written BY HAND in mc. None of it is what `mc-php` produces, and the
compiler does not yet produce any of it.** They are the measured proof that the Zend ABI
[`lib/php_ext.mc`](../lib/php_ext.mc) implements is right, and they are the artefact the back
end has to grow into. `examples/` is for what mc-php compiles; when the back end can emit one of
these from a `.php`, that one moves there and the copy here becomes the golden it is checked
against.

Measured by the owner on **macOS 26 / arm64, PHP 8.5.10 (cli, NTS, `API20250925,NTS`), September
2026**, with **mc 1.1.0**. `tmpl.mc` and `aw6.mc` are TEMPLATES: the four `@API@`/`@ZTS@`/
`@DEBUG@`/`@BUILDID@` placeholders are what the two generator scripts fill from `php -i`, so
neither compiles until one of them has run over it. Verified here on 2026-09-23 that the copies
are intact -- `bench.mc`, `extA.mc` and `extB.mc` compile with plain `mc` as they stand, and
`tmpl.mc` and `aw6.mc` compile, link and LOAD once filled (`aw6.so` registers
`awaitable\parallel`). Nothing here is a gate: they are a record, and this directory is
excluded from `docs/plan.md` D8 for the same reason `probes/` is
([`tests/d8check.py`](../tests/d8check.py) says so in code).

## What each one proved

| file | what it measured |
|---|---|
| [`tmpl.mc`](tmpl.mc) | the SHAPE: `get_module()`, a 168-byte `zend_module_entry`, a `zend_function_entry` table, `zend_internal_arg_info`, and one handler per function. The four values the target php decides -- API number, TS/NTS, debug, build id -- are `@PLACEHOLDER@`s the generator fills. This is exactly what `src/ext.mc` now emits, and it is what the emitter was written against. |
| [`extgen.sh`](extgen.sh), [`extgen-linux.sh`](extgen-linux.sh) | the generator: `php -i` in, one `sed`, `mc --backend=`, and the link. macOS is `ld -bundle -undefined dynamic_lookup`; Linux is `ld.lld -shared -Bsymbolic`, and the `-Bsymbolic` is not optional -- mc takes the address of its own functions with `adrp`/`add`, and in a shared object a default-visibility symbol is preemptible, so the link is refused without it. |
| [`bench.mc`](bench.mc), [`bench.php`](bench.php) | a typed function compiled to a working extension, **and both sides agreeing on the value**: `fib(30)` = 832040 and `sum(3000000)` = 8999997 under php and under the module alike. Measured here: **fib(30) 2.8 ms against the interpreter's 31 ms (11.1x)** and **sum(3000000) 1.8 ms against 9.1 ms (5.2x)**. |
| [`aw6.mc`](aw6.mc), [`aw6.php`](aw6.php) | the widest one, and every part of it is out of this back end's scope today: a class the extension DECLARES, a php callable called back into userland, variadic arguments, an exception captured into a returned object, real pthreads for native work, a semaphore capping concurrency, and `fork` per job so that any php callable runs off the main line. Measured against `https://minicompiler.dev`, 8 pages: **545 ms sequential against 85 ms**, with the semaphore holding peak concurrency at exactly 2. |
| [`awaitable.src.php`](awaitable.src.php) | the PHP source that should one day compile into that extension. It carries the `#[Extern('curl')]` / `#[Extern('curl', variadic: 1)]` attribute shape -- the attribute names the library and the signature is the ABI, and `variadic` marks a call whose extra argument travels on the stack, which the compiler has to know in order to place it. It is the target of the LANGUAGE, not of any milestone that has landed, and `mc-php` refuses its first line today (a `namespace` in an extension source). |
| [`extA.mc`](extA.mc), [`extB.mc`](extB.mc) | two extensions of ours reaching each other's symbols: php loads an extension `RTLD_GLOBAL`, and a LATE `dlsym` at call time makes the load order of the two irrelevant. That is the mechanism `docs/mcphp-toml.md` § The symbol prefix describes. |

## What mc-php does against them today

`bench.mc`'s two functions, written as ordinary PHP and compiled by `mc-php` into an extension of
the same name, on the same host, the same php and the same `bench.php` (three interleaved runs,
2026-09-23):

| | interpreted | `reference/bench.mc`, by hand | `mc-php` |
|---|---|---|---|
| `fib(30)` | 31 ms | **2.8 ms (11.1x)** | 9.6 ms (3.3x) |
| `sum(3000000)` | 9.1 ms | **1.8 ms (5.2x)** | 11.7 ms (**0.78x -- slower than php**) |

Both answer the same values. The gap is not the boundary and not the module header -- it is the
BODY, and `--dump-asm` names it in one look: the generated loop carries **two real calls per
statement**, `php_pos` (T7's diagnostic position) and `php_thrown` (T6's unwinding check), and
every local lives in the frame. A 3-million-iteration loop pays six million calls the hand-written
mc does not make. `docs/plan.md` D7 and the D8 bench already record the same thing for the program
road ("the generated code is 8x to 23x slower than php's VM"); this is that number seen from the
extension road, where it matters more, because the whole point of a native extension is the work.

One more thing that fell out of the same measurement and is **not** the extension road's: a php
ternary allocates per evaluation, so `function f(int $n): int { return $n < 2 ? $n : f($n-1) +
f($n-2); }` exhausts the 48 MiB arena at `f(30)` -- on the PROGRAM road too, with
`mc-php --exe`. The `if` form of the same function runs in both. Reported rather than worked
around.

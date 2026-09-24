# reference -- hand-written mc, not mc-php output

**Every file here was written BY HAND in mc. None of it is what `mc-php` produces, and the
compiler does not yet produce any of it.** They are the measured proof that the Zend ABI
[`lib/php_ext.mc`](../lib/php_ext.mc) implements is right, and they are the artefact the back
end has to grow into. `examples/` is for what mc-php compiles; when the back end can emit one of
these from a `.php`, that one moves there and the copy here becomes the golden it is checked
against. Three of them are ALSO in `examples/` already, by the owner's rule that what has code
is a gate first: `extA.mc`/`extB.mc` as `examples/two-extensions` and `aw6.mc` as
`examples/awaitable`, each labelled hand-written on its README's first line and each beside the
PHP source whose refusal its gate pins. The copies here stay the record.

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

`bench-steady.php` runs the same two functions with a warm-up and the best of nine, because
`bench.php` times ONE cold call each and that carries a band this host can see: nine processes
give `sum` a minimum of 2.26 ms and a maximum of 5.76 ms for the SAME binary, and two builds of
the same source differing only in the module's NAME -- so in nothing but where the code lands --
measured 5.9 and 1.9. The table below is nine processes, interleaved, at the minimum.

| | interpreted | `reference/bench.mc`, by hand | `mc-php` before | `mc-php` today |
|---|---|---|---|---|
| `fib(30)` | 30.4 ms | **2.78 ms (11.0x)** | 9.62 ms (3.18x) | **4.82 ms (6.31x)** |
| `sum(3000000)` | 9.05 ms | **1.65 ms (5.5x)** | 10.55 ms (**0.86x**) | **2.26 ms (4.00x)** |

All three answer the same values. The "before" column is what this page recorded on 2026-09-23
and it is reproduced here by a compiler built from that commit; `sum` was slower than the
interpreter, and `--dump-asm` named the cause in one look: **two real calls per statement**,
`php_pos` (T7's diagnostic position) and `php_thrown` (T6's unwinding check), so a
3-million-iteration loop paid six million calls the hand-written mc does not make.

Both calls are gone from that loop. A statement announces its position only when something in it
can raise a diagnostic or throw, and is followed by the unwinding check only then -- under
`declare(strict_types=1)` with declared scalar types `$i <= $n` and `$s += ...` can do neither --
and `%` by a literal the compiler can see is positive lowers to `sdiv`/`msub` rather than to
`php_mod`, which is the only call left in the body. `--dump-asm` of `mcb_sum` is now call-free.

What is left, and it is the rest of the sentence this page has always carried: **every local
lives in the frame**. The hand-written column keeps its values in registers, which is the whole
of the remaining 1.4x on `sum` and most of the 1.7x on `fib`. `docs/plan.md` D7 and the D8 bench
record the same thing for the program road.

One more thing that fell out of the same measurement and is **not** the extension road's: a php
ternary allocates per evaluation, so `function f(int $n): int { return $n < 2 ? $n : f($n-1) +
f($n-2); }` exhausts the 48 MiB arena at `f(30)` -- on the PROGRAM road too, with
`mc-php --exe`. The `if` form of the same function runs in both. Reported rather than worked
around.

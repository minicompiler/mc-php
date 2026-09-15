# mc-php: the plan

## 1. What it is

A compiler taught to mc (Tier 3: `source_claim` for `.php`, `syntax*` hooks, the `$` token mc
already lexes as a claimable surface token) that turns a PHP 8.5 program into one native binary,
plus the runtime that binary links: the Zend semantics -- zval, `zend_string`, the ordered hash
array, objects with handlers, refcounting/GC, exceptions, closures, generators, references -- and
the internal functions and classes (php 8.5.10 NTS measured: 2143 internal functions, 544 of them
in `ext/standard`; 300 classes; 27 interfaces; 66 extensions built in).

PHP is dynamic, so the first compiler is AOT over a dynamic runtime: it emits calls into the zval
runtime, not typed native code. Type inference and native lowering are an optimization phase that
comes after the `.phpt` corpus is green.

## 2. The oracle

php-src's `.phpt` tests (~17k). A runner executes each test under `php` and under the mc-php
build and compares stdout/exit. The number that matters is "N of M green" and it is printed on
every run. Nothing is claimed compatible that this grid does not show.

## 3. Decisions to take before code (with the measurement that decides each)

D1. `include`/`require`/`eval` at run time. A binary is whole-program: every include is resolved
    at compile time (the closure of the entry) and `eval` of source not present at compile time is
    refused. An embedded interpreter is the later road, not the first. Decided by T0's corpus
    breakdown: how many `.phpt` need run-time `eval`.

D2. Extensions. Two classes, two answers.
    (a) The engine, `ext/standard` and everything the distribution compiles in are not loadable:
        they ARE PHP and must be written in mc.
    (b) Third-party `.so` (pecl, pdo_*, gd, intl...) can be reused only through a Zend-ABI shim:
        the exact layouts of `zend_types.h` (zval 16 B, `zend_string`, `Bucket`/`HashTable`,
        `zend_object` + handlers, `zend_execute_data`) and the subset of the 1612 functions +
        171 globals (`executor_globals`...) the `php` binary exports that each `.so` imports.
        Decided by T1 (the size of that subset), T2 (mc can export symbols to a `.so` and receive
        a variadic call) and T3 (a real extension function runs on our zval).

D3. Web shape. The runtime ships an HTTP server (the `mc-forkka` fork-per-connection shape from
    mc's bench) that fills the superglobals; no CGI/FCGI, no `url/file.php`. Later.

## 4. The test grid (probes, before the compiler)

| id | question | measured how | exit number |
|---|---|---|---|
| T0 | how far is 0 from N | php-src cloned, `probes/phpt-run.sh` runs `php` and `mc-php` | green/total |
| T1 | how big is the Zend shim | `phpize` on `ext/ctype` and `ext/pdo_sqlite`, `nm -u` on the `.so` | imported symbols per `.so` |
| T2 | can an mc binary export a symbol to a `.so` and take a variadic call | `[linker]` with `-export_dynamic`, `dlopen`, a callback; a C caller of a variadic mc callee | yes/no per host |
| T3 | does a real extension run on our zval | zval/`zend_string`/HashTable at `zend_types.h` offsets in mc, `ctype_digit` from `ctype.so` | yes/no |
| T4 | does Tier 3 take PHP's grammar | lexer/parser for `<?php echo 1+2;`, functions, arrays, strings -> `--dump-ast` | gaps list |
| T5 | does the runtime agree with php | zval, ordered array, string, refcount; first ~100 `.phpt` of `Zend/tests` + `ext/standard/tests/strings` | green/total |

Gate for the compiler proper: T2 + T3 decide `.so` reuse (D2b); T4 decides that the grammar fits
Tier 3 with no mc change. Nothing in this grid touches mc's `src/`.

## 5. What mc may need (reported, not worked around)

- `mc --exe` writes imports only (ELF `.dynsym` = JUMP_SLOT; Mach-O has no export trie). A binary
  that `dlopen`s an extension must export the Zend API: the `[linker]` road with
  `-export_dynamic` / `--export-dynamic` does it today; an export table in the exe writers would be
  an additive MINOR on mc's side, asked for only if T2 proves the road is worth it.
- A variadic callee in mc (`zend_parse_parameters("ll", &a, &b)` called BY the extension): Apple
  arm64 passes variadic arguments on the stack, SysV in registers with `al`. T2 measures whether
  mc's parameter reads (`MAXPARAMS` 12, stack parameters since M38) reach them.

## 6. After the corpus is green

Native lowering behind type inference, the web server, multithreading, async. Not before.

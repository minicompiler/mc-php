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

D1. DECIDED (owner, 2026-09-15): there is no interpreter. A binary is whole-program -- every
    `include`/`require` is resolved at compile time (the closure of the entry, literal paths only)
    -- and `eval`, `create_function`, an `include` of a computed path, `$$name` and any call whose
    target is a run-time string that cannot be resolved at compile time are REFUSED with a named
    compile error, one per construct, listed in `docs/refused.md` (not written yet: T4 measured
    the mechanism -- `eval('1')` is refused at its own line with a named error,
    `probes/t4/g/09-eval.php` -- and the list belongs with the compiler, not with a probe). T0's
    corpus breakdown reports how many `.phpt` fall in that class, as a number, not as a claim.

D4. DECIDED (owner, 2026-09-15): variables have a STATIC type. A variable's type is its declared
    type or the type of its first assignment, and it never changes: `$a = "1"; $a = 10;` is a
    compile error naming the variable and both types. Consequences: (a) mc-php accepts a SUBSET of
    PHP -- every program it compiles runs unchanged under `php`, not the reverse; (b) a typed local
    is a native value, not a zval, so the first optimization is free; (c) `mixed` and union types
    exist only where PHP itself declares them (parameters, returns, properties) and a variable of
    such a type is a zval; (d) arrays stay heterogeneous inside (elements are zvals) -- the static
    type is the container's; (e) `null` needs a declared `?T` or a union, never an implicit one.
    The `.phpt` grid gains a third column: green / wrong / refused-by-design.
    **Measured by T6** (`probes/t6/RESULTS.md` § "Where a decision met reality" 1): D4 (c)
    answers three of the four places T5 said the rule had none, because `mixed` is a php type
    and its lowering is a zval. `int / int` is `int|float` and so a zval; an UNTYPED PARAMETER
    is what php declares `mixed` by omission, so it is one too -- which is the refusal T5
    measured as "53 of the first 200" and named as the cheapest move from refused to green;
    and `$x = null` gives `$x` the union's type. The fourth, an UNDEFINED VARIABLE, is
    **answered by T7** (`probes/t7/RESULTS.md` section 1): php warns and yields null, and null is
    a value of `mixed`, which (c) already lowers to a zval -- so the READ is expressible without
    the variable gaining a type at all, and a later `$x = 5` still declares it an int. The
    refusal is retired and the warning is php's own text, with php's own file and line.
    D4 now has an answer everywhere the rule is asked.
    **T8 finished the job on the WRITE side**: every operation that writes a variable does the
    read first (`$u .= "x"`, `$u++`, `$u += 2`, `$u->p = 1`, `unset($u)`), and six sites still
    refused an unbound name by D4. They bind it `mixed` now, holding what php's read of it
    answers -- the warning and the null -- so the six refusals are gone too. `$a = &$b` where
    `$b` does not exist creates it SILENTLY, which is php's rule for that one.

    **Measured by T5** (`probes/t5/RESULTS.md` § "Where a decision met reality"), three places
    where the rule as written had no answer and T5 therefore refused (i) and (ii) are ANSWERED
    by T6, above and (iii) by T7, so all three are closed; kept for the record:
    (i) **`int / int`**. `10/2` is `int(5)` and `7/2` is `float(3.5)`, so the static type of `/`
        over two ints is `int|float` -- (c) sends that to a zval, which T5 does not have, so the
        operator is refused by name and the message names `intdiv()`. It is the commonest
        refusal in ordinary code.
    (ii) **An untyped parameter.** `function f($x)` is the commonest shape in the corpus and has
        no declaration and no first assignment; its type is the CALL SITE's, which D1's
        whole-program closure makes readable and which T5 does not read. 53 of the first 200
        refusals under `tests/lang` + `ext/standard/tests/strings` are this one, and it is the
        cheapest thing that would move refusals back into green.
    (iii) **An undefined variable.** PHP warns and yields null; the rule has nowhere to put it.
        34 of the same 200.
    Also measured, and it is the rule working: reusing one `$v` for two `foreach` element types
    is valid PHP and D4 refuses the second -- it caught the probe's own fixture.

D2. Extensions. Two classes, two answers. **Decided by T1/T2/T3 (2026-09-15, macos/aarch64;
    `probes/`). D2(b) is taken: the shim is real, it is small, and it works.**
    (a) The engine, `ext/standard` and everything the distribution compiles in are not loadable:
        they ARE PHP and must be written in mc. Measured: `ext/json` cannot even be built shared by
        `phpize` in PHP 8, which is the same statement from the other side.
    (b) Third-party `.so` (pecl, pdo_*, gd, intl...) are reused through a Zend-ABI shim, and the
        three probes say what that costs.

        - **T1 -- the size.** **169 symbols**: 157 functions + 12 data globals, the union over
          `ctype`, `pdo_sqlite` and `mbstring`. `ctype` alone needs **7 functions and no data
          global at all**, because since PHP 7 the fast ZPP macros are expanded inline in the
          header and the string path of an internal function calls nothing. The union grows with
          each extension added -- 169 bounds the SHAPE (a few hundred entry points, a quarter of
          them allocator and array helpers), not "all of pecl".
        - **T2 -- the mechanics.** A `.so` built exactly as a php extension resolves symbols an mc
          binary defines, on every link road including `mc --exe`; `-export_dynamic` is an ELF
          habit and is not needed on macOS. A function written in mc can be the callee of a
          variadic C call with **no mc change**: on Apple arm64 every variadic argument is passed
          on the stack at `[sp + 8*n]`, and an mc callee reads parameter 9 at `[x29 + 16]`, which
          IS the caller's `sp`. So variadic argument N is mc parameter 8 + N, capped at **4**
          (`MAXPARAMS` 12, one spent on the format). `zend_parse_parameters` therefore reaches
          `execute_data` + a format + 3 pointers before the cap bites; past that the answer is to
          walk the stack by hand (`ld64(x29 + 16 + 8*n)`), which needs nothing from mc either.
        - **T3 -- the proof.** php-src's own `ctype.so` runs `ctype_digit` on a `zend_execute_data`
          and a `zval` laid out by mc, and `php` agrees on all five inputs; the extension calls
          back into `php_error_docref` **variadically** and reads the right argument. 39 layout
          facts (`zval` 16 B, `zend_string.val` at 24, `ZEND_CALL_ARG(ex,n)` at `ex + 80 + 16*(n-1)`,
          `zend_function_entry` **48** B since 8.4, ...) are checked against the installed headers
          with `offsetof`/`sizeof` on every run.

        What the probes did NOT measure, and what D2(b) is therefore still open on: refcounting,
        `HashTable`, `zend_object` + handlers, exceptions, the allocator -- `pdo_sqlite`'s 73
        imports are the next order of magnitude. And every number here is macos/aarch64; the ELF
        and PE hosts need their own run of `probes/t2/run.sh`.

D5. DECIDED (owner, 2026-09-15), and **measured by T4** (`probes/t4/g/08-require.php`: `require`
    then `require_once` of the same file, the program agrees with `php`). One thing the probe had
    to learn: mc's own `lex_include` does the includer-relative resolution AND the once-only list,
    but it is UNCONDITIONALLY once-only and its list is not the one a `p_push_source` enters, so a
    module cannot use `lex_include` for `_once` and `p_push_source` for the plain form -- the
    second splice then declares everything twice. All four spellings go through one road,
    `path_norm(path_join(includer, rel))` + `read_file` + `p_push_source`, with the once-list the
    module's own. `require`/`require_once`/`include`/`include_once` are sugar over
    mc's `#include` semantics -- the Tier 3 handler resolves the LITERAL path against the including
    file and pushes the source with `p_push_source` (M21: a textual splice at that point, in the
    includer's scope, errors attributed to the included file). All four are compile-time; the one
    distinction kept is `_once`, by normalized path (PHP's own realpath rule). A missing file is a
    compile error in all four (a binary has no "warn and continue"). `$x = include 'f.php';` where
    `f.php` is a single top-level `return EXPR;` splices the expression; an expression-position
    include whose file also runs statements is refused. Declarations (functions, classes) found in
    an included file are hoisted to the program; an include that is conditional or inside a loop
    and carries declarations is refused. A computed path is refused (D1). The real-world case,
    Composer's `spl_autoload_register` + `include $file`, is resolved STATICALLY: the compiler reads
    `vendor/composer/autoload_classmap.php` / the PSR-4 map (literal arrays) and includes the file
    when the class is first referenced -- autoload becomes compile-time resolution.

D6. DECIDED (owner, 2026-09-15): no reflection. A binary carries no run-time type tables, so
    every `Reflection*` class is refused, and with it what needs those tables at run time:
    `get_class_methods`, `get_object_vars`, `get_class_vars`, `property_exists`/`method_exists`
    with a non-literal name, `$obj->$prop`, `$obj->$method()`, `new $class`, `$class::$member`,
    a callable spelled as a string (`'Foo::bar'`, `[$o, 'm']` with a dynamic string),
    `debug_backtrace` (`func_get_args` was here and is not -- see the correction below;
    `...$args` stays). Attributes `#[Attr]` are accepted by
    the grammar and inert (only reflection read them). KEPT, because it is dispatch and not
    introspection: `__get`/`__set`/`__call`/`__callStatic`/`__invoke`, `instanceof` with a
    literal, `get_class($o)`, `$o::class`, typed closures/callables, `is_callable(Closure)`.
    ANSWERED AT COMPILE TIME when the argument is a literal: `class_exists('Foo')`,
    `method_exists($o, 'm')`, `function_exists('f')` fold to constants.
    **Corrected by T8's measurement** (`probes/t8/RESULTS.md` section 5): `func_get_args` is back
    IN. D6's principle is "a binary carries no run-time type tables, and nothing dispatches on a
    string" -- and that one needs neither: the arguments of the currently executing function ARE
    its own parameters, which the compiler has in front of it. T8 already built `func_num_args()`
    and `func_get_arg(k)` out of exactly that (a prologue counter emitted only when the source
    names one of them, plus a choice among the parameters); `func_get_args()` is the same
    mechanism returning an array, so listing it here was a classification mistake, not a choice.
    `debug_backtrace` stays refused -- it needs the call stack's shape at run time, which is the
    table D6 is about. Declared cost: frameworks
    built on reflection-driven DI containers (Laravel, Symfony) are out of scope; the target is
    programs and libraries that do not introspect.

D7. DECIDED (owner, 2026-09-15): no VM and no GC -- "teko already proves automatic arenas work".
    Execution is AOT only (D1 already removed the interpreter). Memory is arenas: Zend's own
    `emalloc` is a per-request allocator reset at request end, so the web shape is one arena per
    request (with the fork-per-connection server the child's exit IS the release), and the CLI
    shape is automatic per-scope arenas in teko's rule (what escapes a scope is copied up). There
    is no refcount-driven free and no cycle collector. Consequence for D2b: the refcount fields
    stay in the layouts (extensions read/write `GC_REFCOUNT` inline), and `zval_ptr_dtor`,
    `zend_string_release`, `_efree` and friends are arena-aware no-ops -- T3 measures that a real
    extension runs on it. The risk is measured, not assumed: a long loop that allocates (string
    concatenation in `while`) grows until its scope ends, so T5 gains a column, peak RSS against
    `php` on the same `.phpt`.
    **Measured by T7** (`probes/t7/arena.py`, which runs on every `sh probes/t7/run.sh`):
    **9 of 1460 sampled `wrong` tests** die with `mc-php: arena exhausted`,
    and **not one of them is an array copy**: four build a very large STRING,
    four allocate without bound on purpose and expect php's own
    `Fatal error: Allowed memory size of %d bytes exhausted`, and one is wrong
    for another reason too. The eager array copy T6 measured (the 48 MiB arena exhausted between 500 and 1000
    copies of a 2000-element array) is therefore NOT what bites the corpus, and copy-on-write --
    which D7 would allow without a refcount, since a compile-time escape question can say the
    writer is the only one that could observe the difference -- is not built. The pressure that
    does exist is string BUILDING, which is the shape D7 already predicted.
    **T8 adds one consequence with a number**: a php `var_dump` marks an array element another
    name holds a reference to (`&int(99)`), and D7 has no refcount, so nothing at run time tells
    the mark from the value. The values agree; the mark is a documented difference
    (`probes/t8/g/42-string-offset-ref.php` compares the values with `echo` and says why).
    **SUPERSEDED on the EXTENSION road (owner, 2026-09-24, batch A).** A module outlives every
    request, so one arena per process -- never freed -- is a program's model and not a module's:
    `examples/decimal` died with `mc-php: arena exhausted` near 29 000 calls in one php. On the
    extension road the runtime now allocates the way a C extension does, through the Zend Memory
    Manager, and D7 stays exactly as written for the PROGRAM road (a standalone binary has no
    Zend). The runtime keeps ONE allocation seam, `php_alloc`, with two implementations chosen by
    road -- the arena, or the Zend chunk an extension call bumps through (`lib/php_ext.mc`) --
    rather than two runtimes. What lives where:
    * **module lifetime** -- what MINIT builds (the class table, top-level constants, the bootstrap
      hierarchy) and every string literal's cache: the module's own static arena, never freed,
      which is `pemalloc`'s role taken by the module's own data;
    * **call lifetime** -- everything a call allocates: a Zend chunk the request reuses, zeroed
      and every extra block `efree`d when the call returns, so a million calls in one request
      keep one chunk (measured below);
    * **request lifetime** -- what a call that WRITES module state kept (a `static`, a `global`, a
      `define()`, a handler, a class, a file): the call PINS itself, its blocks stay until the
      request ends, and RSHUTDOWN puts the state back as MINIT left it -- statics reset, files
      closed, the arena restored from a snapshot -- which is php's own rule for a request.
    A string ARGUMENT is borrowed (the runtime's string IS a `zend_string`, and strings are
    immutable here); a result the call built in a block of its own is handed over, a small one is
    copied once. `docs/php-extension.md` § The memory has the rules and the numbers.

D8. DECIDED (owner, 2026-09-15): every `.php` written in this repository -- fixtures, any part of
    the runtime or standard library written in PHP, examples -- carries TESTS that run in BOTH
    worlds and BENCHMARKS between them. (a) Tests are PHPUnit test classes (`PHPUnit\Framework\
    TestCase`, `assertSame` & co.) run under `php` with the real phpunit; the SAME files run under
    mc-php through `mc-php test`, where a tiny `TestCase` shim provides the assertions and the
    compiler discovers `test*` methods at COMPILE time (D6: no reflection -- phpunit's own runner
    cannot run on mc-php, so discovery is the compiler's job and the generated `main` calls each
    test). Green in both is the gate; a test that passes in one world and not the other is a bug
    named by the test. (b) Benchmarks: `bench/` holds programs timed under `php` (version, opcache
    and JIT settings recorded as the tool prints them) and as an mc-php binary, in the shape of
    mc's bench cell (interleaved repetitions, medians, a committed dated `results.json`); the
    number reported is `php / mc-php` per program, and it is printed on every run, never claimed
    from memory. Nothing written in PHP lands without its test in both worlds and its row in the
    bench table.

    AMENDED (T10, `docs/review-backlog.md` section 3): the rule covers the `.php` under
    `probes/*/g` and `probes/*/r` too, and until T10 they carried neither a PHPUnit class nor a
    bench row. They are EXEMPT, with the reason and the enforcement both written down, because
    the unit D8 governs is the PROGRAM and a differential fixture is not one -- it is already a
    test, and a stronger one. (c) A fixture's test is the differential gate itself
    (`probes/t10/fixtures.sh`): its stdout, its stderr and its exit code are compared BYTE FOR
    BYTE against `php` on the same source, so its oracle is the reference implementation and not
    a value someone typed into an `assertSame`, and it runs in both worlds by construction --
    which is what D8 (a) asks a test to prove. It carries no bench row because a three-line
    program measures process start-up and nothing else (T9 measured it: `php` pays about 38 ms
    before the first statement, against a whole `main.php` of 39.5 ms). (d) A probe cannot waive
    the rule for itself, so the exemption is a SCRIPT and not a paragraph:
    `probes/t10/d8check.py` (`run.sh` step 0) puts every `.php` under the probe into exactly one
    of SIX regimes -- `fixture` (`g/*.php`, graded byte for byte against php on stdout, stderr
    and the exit code), `refusal` (`r/*.php`, which is NOT that pair and cannot be: the point of
    the file is that mc-php declines it, so the pair is php PARSING it under `php -l` and
    mc-php refusing it by name with exit 3), `helper` (a `g/` file another fixture `require`s
    and the gate skips, whose test is every fixture that includes it), `instrument` (the
    `TestCase` shim, the test class, the runner that names the methods: the mechanism of D8 (a),
    which cannot test itself), `library` (required BY the test class AND BY a bench program, so
    exercised in both worlds and timed in both) and `bench` (a row in `bench10.sh`, which
    refuses to time a program until `php` and mc-php print the same answer)
    -- and exits non-zero naming any file in none of them. It found one on its first run:
    `probes/t10/bench/unwind.php`, copied forward from T6 and referenced by nothing, deleted
    here (T6's original is untouched and still reproduces).

    WIDENED (T10, the review of #9): the checker walked `probes/t10` alone, which is narrower
    than the rule -- D8 covers every `.php` in this repository, so an orphan in any other probe
    passed, and one did (`probes/t9/bench/unwind.php`, while t9's own bench script runs
    `probes/t6/bench/unwind.php`; t7's and t8's copies the same). It walks `probes/` now and a
    file is accounted for when a fixture gate runs it, another `.php` requires it, a SCRIPT
    names its path, a bench script names its basename in a `for prog in` list, or it is under
    one of three enumerated pre-D8 directories -- `probes/t0`, `probes/t4` and
    `probes/gap-lexer-ownership`, each with its reason in the script, and the sweep FAILS when
    an exempted directory is gone or has grown a `bench/`, so the list cannot rot. 366 `.php`
    swept; the three orphan copies of `unwind.php` are deleted, T6's original untouched.

    (e) The PHPUnit half of (a) is EXEMPT while its two mechanisms do not exist, and this is
    the exemption rather than an omission: **phpunit is not installed on this host** (the
    check is `class_exists('PHPUnit\Framework\TestCase')`, which is why
    `probes/t10/bench/shim.php` exists at all -- with the DEFAULT autoload, so a host
    that has phpunit behind an autoloader gets the real `TestCase` and not the shim) and **`mc-php test` does not exist** -- (a)
    names it as the mechanism the COMPILER will provide, and no probe has built it. Until one
    does, the test methods are named by hand in `probes/t10/bench/run.php` and the gate proves
    what it can: that the class's `test*` methods are all named by the runner
    (`d8check.py`, statically), that php and mc-php each RUN that many, and that the two
    outputs are byte for byte the same (`run.sh` step 10). What it does NOT prove is that
    `WorkloadTest.php` passes under the real phpunit, and `run.sh` prints that sentence on
    every run rather than leaving the gate looking like it did.

D9. DECIDED (owner, 2026-09-15): the TYPE SYSTEM is PHP's, in full -- the manual's own list
    (`null`, `bool`, `int`, `float`, `string` and numeric strings, `array`, `object`, enums,
    resources, `callable`, `mixed`, `void`, `never`, `self`/`parent`/`static`, `?T`, unions
    (`int|string`), intersections (`A&B`) and DNF, `iterable`, the `true`/`false`/`null` singletons,
    type declarations on parameters/returns/properties/constants, and PHP's juggling and
    coercion rules, strict_types included). A `.php` file spells PHP types and nothing else.
    mc's types are the LOWERING behind them, never the surface: `int` -> `i64`, `float` -> `f64`
    (`<float>`), `bool` -> `u8` with the two values, `string` -> a `zend_string`-shaped handle
    (`uptr`), `array` -> the ordered-hash handle, an object -> its handle, `callable` -> a closure
    record, `mixed`/a union/`?T` -> a zval (D4 (c)); `null` is a value of `?T`/unions only. T4's
    probe mapped three names and refused `float`; that was a measurement, not the design.
    The owner allows the mc names to stay ACCEPTED by the compiler as a lowering hint, but a
    `.php` that uses one no longer runs unchanged under `php` (there `i64 $x` is a class type),
    so it cannot pass D8's php side and is out of every gate -- an escape hatch for probes only.
    **Measured by T5**: the surface is PHP's, and every type word the compiler does not have is
    refused BY NAME rather than mistyped -- `?T` and unions (D9 (e): assigning `null` to a
    variable is refused too, since its type would be `?T`), `mixed`, `iterable`, `callable`,
    `object`, `never`, `self`, `static`. T4's mapping of `bool` to `TY_I64` and its refusal of
    `float` are both gone: `bool` is `u8` and `float` is `<float>`'s `f64`.

D10. DECIDED (owner, 2026-09-15): the lowering table, PHP -> mc.

    | PHP | mc | notes |
    |---|---|---|
    | `bool` | `u8`, the two values 0 and 1 | |
    | `int` | `i64` | PHP_INT_MAX/MIN are i64's; overflow to float is PHP's rule, implemented |
    | `float` | `f64` (`<float>`) | |
    | `string` | a NEW type: `len` as `i64` + the bytes, immutable | PHP strings are BINARY-SAFE byte sequences: `strlen("\xc3\xa9") == 2`, binary data travels in `string`, and the `.phpt` corpus asserts exactly that -- so the type stores bytes and never validates encoding; UTF-8 is the content convention `mb_*` interprets, not a property of the type. Immutable value: a write is a new string (PHP's copy-on-write, arena-friendly, D7). Laid out like `zend_string` (refcount, hash, len, val) so D2(b)'s shim gets it for free |
    | the rest | developed one by one | `array` (ordered hash), objects, enums, `callable`, `iterable`, `mixed`/unions/`?T` (a zval), resources, each with its own `.phpt` slice and its bench row |

    **Built and measured by T5** (`probes/t5/php_rt.txt`): `bool`, `int`, `float` and `string`
    exactly as the table says -- the string is a `type_new(8, 8, TK_INT)` handle to T3's
    `zend_string` layout, and `strlen("\xc3\xa9") == 2` is a fixture (`g/03-binary-safe.php`).
    Two rows the table left open got a T5 answer that is deliberately smaller than the final one
    and says so at the refusal: `array` is a PACKED HOMOGENEOUS vector with the keys 0..n-1 (a
    key or a mixed element is a named error, not a zval), and one union exists -- `int|false`,
    lowered to `i64` with -1 as the false, because `strpos` has it and nothing else would make
    `=== false` right. D7's arena is 48 MiB of `__bss`, never freed; a string literal is built
    once per RUN and cached in a global the compiler emits beside it, because an arena with no
    free cannot afford one copy per loop iteration.

D3. Web shape. The runtime ships an HTTP server (the `mc-forkka` fork-per-connection shape from
    mc's bench) that fills the superglobals; no CGI/FCGI, no `url/file.php`. Later.

## 4. The test grid (probes, before the compiler)

| id | question | measured how | exit number |
|---|---|---|---|
| T0 | how far is 0 from N | php-src cloned, `probes/t0/phpt-run.py` runs `php` and `mc-php` | green/total -- phpt: green 0 / wrong 18109 / refused 0 / skip 2947 / php-fail 339 / total 21056  (21395 tests; sapi/ excluded) (`probes/t0`) |
| T1 | how big is the Zend shim | `phpize` on `ext/ctype` and `ext/pdo_sqlite`, `nm -u` on the `.so` | imported symbols per `.so` -- **measured: 169** (`probes/t1`) |
| T2 | can an mc binary export a symbol to a `.so` and take a variadic call | `[linker]` with `-export_dynamic`, `dlopen`, a callback; a C caller of a variadic mc callee | yes/no per host -- **macos/aarch64: yes, yes** (`probes/t2`) |
| T3 | does a real extension run on our zval | zval/`zend_string`/HashTable at `zend_types.h` offsets in mc, `ctype_digit` from `ctype.so` | yes/no -- **yes** (`probes/t3`) |
| T4 | does Tier 3 take PHP's grammar | lexer/parser for `<?php echo 1+2;`, functions, arrays, strings -> `--dump-ast` | gaps list -- **grammar yes, lexer no** (`probes/t4`) |
| T5 | does the runtime agree with php | the string/array/float runtime of D10 under a compiler for the php subset D4 allows; the whole `.phpt` corpus through `probes/t5/mcphp.sh` | green/total -- **phpt: green 80 / wrong 15367 / refused 2639 / skip 2947 / php-fail 362 / total 21033** (`probes/t5`); per directory `tests/lang` 12, `Zend/tests` 38, `ext/standard/tests/strings` 12 |

| T6 | how far does the wrong-reason table move | T5's table worked in descending value -- arrays, objects, functions, exceptions, constants, the library -- and re-measured | green/total -- **phpt: green 1073 / wrong 13374 / refused 3657 / skip 2947 / php-fail 344 / total 21051** (`probes/t6`); per directory `tests/lang` 74, `Zend/tests` 452, `ext/standard/tests/strings` 180** (`probes/t6`) |

| T7 | php's diagnostics, and the tests that compile and print the wrong thing | the diagnostic channel built (position, text, streams, exit codes) and T6's `(compiled; output differs)` block clustered by `probes/t7/diffgroup.py` and worked in descending order | green/total -- **phpt: green 1218 / wrong 13968 / refused 2917 / skip 2947 / php-fail 345 / total 21050** (`probes/t7`); per directory `tests/lang` 82, `Zend/tests` 539, `ext/standard/tests/strings` 194 |

| T9 | func_get_args, the two blocks T8 inverted, and the generator decision | D6's correction built; the `(compiled; output differs)` and `(does not compile)` blocks re-clustered over a UNIFORM corpus-wide sample and worked in descending value; D8's first non-fixture `.php` with its tests in both worlds and its bench | green/total -- **phpt: green 1637 / wrong 14140 / refused 2309 / skip 2947 / php-fail 362 / total 21033** (`probes/t9`); per directory `tests/lang` 102, `Zend/tests` 709, `ext/standard/tests/strings` 262 |
| T10 | the review backlog (59 Copilot findings across #1..#7) | `docs/review-backlog.md` worked in its own order: the four tools that reported numbers they had not measured, the twenty-two semantics a program can observe, D8 over the fixtures -- and, found by running out of disk, the grid's unbounded tmp | green/total -- **phpt: green 1697 / wrong 14481 / refused 1929 / skip 2947 / php-fail 341 / total 21054** (`probes/t10`); per directory `tests/lang` 104, `Zend/tests` 756, `ext/standard/tests/strings` 263; fixtures 89/89 on each stream and the exit code; `refused` 2309 -> 1929; the grid's tmp peak 1908 KiB over 27728 tests, 2152 KiB on the round-seventeen re-run of the same 27728 |

| T8 | the block that does not compile, and the names it asks for | T7's `(does not compile)` block grouped by `probes/t8/nocompile.py` and worked in descending order; the 288 missing names worked in descending frequency | green/total -- **phpt: green 1450 / wrong 13607 / refused 3026 / skip 2947 / php-fail 365 / total 21030** (`probes/t8`); per directory `tests/lang` 93, `Zend/tests` 635, `ext/standard/tests/strings` 223 |

Gate for the compiler proper: T2 + T3 decide `.so` reuse (D2b); T4 decides that the grammar fits
Tier 3 with no mc change. Nothing in this grid touches mc's `src/`.

T10 is done (2026-09-21, macos/aarch64; `probes/t10/RESULTS.md`), on **mc 1.1.0**: the review
backlog, all three sections (`docs/review-backlog.md`).
`phpt: green 1697 / wrong 14481 / refused 1929 / skip 2947 / php-fail 341 / total 21054`, against T9's
`green 1637`; per directory `tests/lang` **104**, `Zend/tests` **756**,
`ext/standard/tests/strings` **263**; **1664 of the 1689 greens are in T0's "touched by
none" set** (that share was measured on the round-forty-two run of 1689; the +8 since is
round fifty-three's argument-type checks, re-measured against the compiler the pull request
ends with). `refused` fell **2309 -> 1929**. The green moved only +52 because the work was
CORRECTNESS: a `.phpt` that was already green does not become greener for the compiler being
right about short circuit. What the probe is actually worth is the corrected numbers.

**Four tools had been reporting numbers they never measured**, and they are what chose every
block since T5. `why.py` labelled a test `(compiled; output differs)` WITHOUT running the
binary; running them shows that of 781 sampled tests that compile, **757 really differ**, 22
crash, 2 time out and none agrees on both. `arena.py` divided by `len(files)` while
turning every failure into `None`: of T10's 1352-test list only **782 RAN**, so the published
rate understated by 1.7x. `nocompile.py`'s skip list named one compiled outcome of five, so
the block that does not compile was published as 737 and is **539** -- the reviewer of #9
caught that one, in T10's own first draft. `fixtures.sh` merged the streams with `2>&1` and
compared with `$(...)`, which strips trailing newlines. `bench/bench.sh` in t7 and t8 built and timed **t6's**
compiler.

**D8's mc-php half had never run, under any probe.** `run.sh`'s step 10 piped both halves to
`tail -1` with nothing behind them, so "6 ok / 0 failed in BOTH worlds" and the two bench ratios
were php's side alone -- and T9's own compiler refuses T9's own `bench/main.php`. Two compiler
defects were behind it, both now closed by a fixture: `require __DIR__ . "/x.php"` was refused
as a computed path (it is not: both halves are compile-time literals, and it is php-src's own
spelling), and a top-level `return` returned from the generated `main`, skipping `php_shutdown`,
`php_flush` and the exit code -- the program printed nothing and exited with a junk status (54,
82, 94, 142 and 178 on five runs of the same source). Both halves run now: **6 ok / 0 failed in
each**, `main.php` 6.54x and `heavy.php` 1.43x (the committed record).

**And the grid itself has a band.** The backlog says the grid is what is NOT in question; nobody
had run it twice. Two runs of the SAME BINARY over the whole corpus give **green 1676 and 1688 (an earlier binary)**,
the smaller set a strict SUBSET of the larger, and all twelve of the difference are FILESYSTEM
tests -- 9 under `ext/standard/tests/file`, 3 under `ext/standard/tests/dir` -- which `chdir()`
and write files in a shared working directory while six of them run at once. The three directory
numbers do not move: 104 / 749 / 262 came out identical on four separate runs across three compilers, and
263 on the fifth (round ten's sscanf fix). **A per-block move smaller than a dozen tests should be read on the
directories**, and the corpus number is worth quoting with its band -- which no probe has done,
T9's 1637 and T8's 1450 included.

**And T10 published a number of the same kind while removing them.** Its first version reported
**143 tests (18.2%) that print exactly what php prints and exit with a different code** and named
them the next probe's first block. The reviewer of #9 found that `harness.py` imported the grid's
`DEFAULT_INI` without the `-d` prefixes or the `{E_ALL}` substitution, and chasing that found the
cause: `run_pair` handed php a RELATIVE path while running it with `cwd` set to the test's own
directory, so php answered `Could not open input file` for every test in the sample while the
candidate ran anyway. With php actually running there are **zero** such tests. One more rule
follows from it: **a differential tool has to be checked against a case whose answer is known.**

**And the grid had no bound on its disk.** A full-corpus run filled a 460 GiB boot volume at
about 20000 of 21395 tests: `mcphp.sh` EXECs the binary it compiled and cannot delete it, the
sweeper collected a file only once its mtime was a minute old, and the directory carried the pid
so a killed run's was never collected by anyone. The caller -- the process that WAITS -- names
the binary with `MCPHP_OUT` and unlinks it the moment the subprocess returns, and each run sweeps
the dead siblings at startup. **Measured over the same 27728 tests (three directories and the corpus): peak 1908 KiB on the
round-sixteen run and 2152 KiB on the round-seventeen re-run, against 1860 KiB over 6333 tests --
so the cost is bounded by the job count and not by the corpus; `df -h /` identical before and
after every one of them.**

T9 is done (2026-09-20, macos/aarch64; `probes/t9/RESULTS.md`), on **mc 1.1.0**:
D6's correction built, and T8's two blocks worked from a UNIFORM corpus-wide
sample rather than an alphabetical slice:
`phpt: green 1637 / wrong 14140 / refused 2309 / skip 2947 / php-fail 362 / total 21033`
over the whole corpus, against T8's `green 1450` on the same harness. Per
directory `tests/lang` **102** (was 93), `Zend/tests` **709** (was 635),
`ext/standard/tests/strings` **262** (was 223). **1626 of the 1637 greens are
in T0's "touched by none" set.** `refused` fell 3024 -> 2309, and that is one
block: the php type words in a parameter or a return were refusals and are
not any more.

Eleven blocks, one commit each. The biggest by far removed a refusal rather
than adding a feature: **T5's type table refused `array`, `mixed`,
`iterable`, `callable`, `object`, `never`, `self`, `static`, `null`, `?T`,
`T|U`, `A&B` and a class name because T5 had no zval, and T6 built one and
the table was never re-measured** -- D4 (c) and D9 already said every one of
them lowers to a zval. `Zend/tests`'s refused column fell by 229 on that
alone. Then: `#[\Override]` checked rather than ignored (0 -> 28 of the 67
Override tests, and it is not reflection -- php checks it while COMPILING the
class); late static binding (`static::`, `new static`, `get_called_class`);
`readonly` properties; argument unpacking `f(...$args)`; `ext/json` written
in mc (D2 (a)); the three by-reference targets T8 left; `sscanf`, `setlocale`
and five string-function edges that moved `ext/standard/tests/strings` 223 ->
262; the trigonometric family from libm; and `set_error_handler` made real.

**D8 was met for the first time**: nothing in this repository had ever
written a `.php` outside a `.phpt` fixture. `probes/t9/bench/workload.php` is
ordinary PHP (a JSON round trip, a template renderer, a sort-heavy pass), its
PHPUnit `TestCase` runs **6 ok / 0 failed in BOTH worlds**, and
`probes/t9/bench/bench9.sh` reports two ratios because they measure different
things: mc-php wins the whole program (**5.85x** and **1.45x**) because php
pays ~38 ms of start-up, and LOSES the work (php's own work is 1.5 ms of
`heavy.php`'s 39.5 and mc-php takes 27, so the generated code is **8x to 23x
slower than php's VM**). D7 names the cause and T9 does not dispute it.

**The generator decision is recorded with its number and generators are NOT
built**: 252 of the 13623 `wrong` tests use `yield` (1.8%; 260 of 5312 under
`Zend/tests`), and **145 of the 252 use the manual Generator API**. The shape
if it is built is a state machine the compiler makes out of the function body
-- mc has no goto and D7 forbids a VM and a second stack -- which needs a CFG
pass `php.mc` does not have and is the largest single piece of work in the
probe. The cheap shape (inverting a `foreach`-only generator into a callback)
is correct but serves at most 107 of the 252 and would make the other 145 a
trap, so it was refused as a WRONG answer rather than a missing one.

T8 is done (2026-09-20, macos/aarch64; `probes/t8/RESULTS.md`), on **mc 1.1.0**:
the block T7 named -- `(does not compile)`, 878 of 1460 sampled `wrong`
tests -- taken apart group by group, and the 288 missing names worked in
descending frequency:
`phpt: green 1450 / wrong 13607 / refused 3026 / skip 2947 / php-fail 365 / total 21030`
over the whole corpus, against T7's `green 1218` on the same harness. Per
directory `tests/lang` **93** (was 82), `Zend/tests` **635** (was 539),
`ext/standard/tests/strings` **223** (was 194). **1441 of the 1450 greens are
in T0's "touched by none" set.** `refused` rose 2917 -> 3026 and `wrong` fell
13968 -> 13607, which is a test that now COMPILES getting far enough to hit a
design refusal it never reached before. The `php-fail` column is php's OWN
and this run had 365 against the previous run's 346: the machine was loaded,
and five of the nineteen were green in that run and are green again when
re-run with the same binary -- so the tree's number is 1455 and 1450 is what
the loaded run measured.

`probes/t8/nocompile.py` is what made the block workable: `whytable.py`
prints its head as a flat top-22 with no way back to a file, and this reads
the SAME `why.tsv` -- so no compiler run is repeated -- masks the variable
part of each message, groups, and prints the count with three example files
per group. The groups, in the order they were worked: references (83 across
four messages, and the biggest single theme), a method's `: void` (37, and
the cause is that `void` is one of mc's OWN keywords), the lvalue chain (71:
`$a[0]->p`, `$t->x[0][0]`, `$c = &$t->list`), `isset`/`empty` over the same
chain (34), `$f();` as a statement (27), anonymous classes (25), `list()` and
`[$a, $b] =` (21), a compound assignment to an array element (13), the
alternative syntax (all five), `@` on a statement, `$s[9] = "x"`.

The names, in descending frequency: files and streams (the biggest, 40
library rows over a php `resource`, which is a zval of type `IS_RESOURCE`
indexing one table), `pack`/`unpack` (30), output buffering that NESTS,
`get_html_translation_table` with php's own 253 entries, `fprintf`/`vfprintf`
(22), `serialize`/`unserialize`, `func_num_args`/`func_get_arg`, and eleven
more. The library table went 180 rows -> 242.

Four defects the blocks found, none of them in the block being built: the
source scans read BYTES and a comment is not code (one line of the RUNTIME's
own commentary put `$a` in the ref set and silenced a D4 refusal, which
`probes/t8/r/d4-retype.php` caught); the unwinding check was missing on
`return`, so `return f();` inside a `try` left the exception pending; a class
member's default that is an ARRAY literal captured its local before the
literal was built, which came out `array(0)` and, with another array literal
earlier in the file, SEGFAULTED; and `lencheck` did not cover
`php_str_new("...", N)`, where three lengths were wrong -- 97 pairs -> 418.

Two sub-populations moved without being targets: the 4647 tests that assert a
php diagnostic go 71 -> 83 and the 333 that mention `__destruct` go 11 -> 14,
because the tests around them now compile.

T7 is done (2026-09-20, macos/aarch64; `probes/t7/RESULTS.md`), on **mc 1.1.0**:
php's DIAGNOSTIC channel, and T6's `(compiled; output differs)` block taken
apart by a tool that groups it:
`phpt: green 1218 / wrong 13968 / refused 2917 / skip 2947 / php-fail 345 / total 21050`
over the whole corpus, against T6's `green 1073` on the same harness. Per
directory `tests/lang` **82** (was 74), `Zend/tests` **539** (was 452),
`ext/standard/tests/strings` **194** (was 180). **1211 of the 1218 greens are
in T0's "touched by none" set**, the same seven outside it as T6. `refused`
fell 3657 -> 2917, because two named refusals were retired -- an undefined
variable (D4) and `@` (D1).

The two blocks T6 pointed at, each on its own population: the 4657 tests that
assert a php diagnostic go **5 -> 71 green**, and the 333 that mention
`__destruct` go **8 -> 11**.

The diagnostics are the engine and seventeen messages: the position is two
runtime globals the compiler stores into once per statement (a file and a
line threaded through 179 library rows is the alternative, and it is not one),
the file is absolutised the way php resolves it, the two streams are written
in php's own order, and a php COMPILE-TIME `Fatal error:` goes to stdout with
exit 255 from inside the compiler, where php produces it.

`probes/t7/diffgroup.py` is what chose every block after that: it runs php and
the mc-php binary on the same `--FILE--`, finds the FIRST differing line and
groups by its shape, so the largest and least structured bucket T6 left is a
table with counts.

Two of T6's own decisions are re-measured rather than restated:
**__destruct** now runs at the end of the program, in php's own reverse
creation order (D7 has no refcount, so that is the only point php also has),
and **the eager array copy is not what exhausts the arena** -- `probes/t7/arena.py` says 9 of 1460 `wrong` tests exhaust it and not one is an
array copy (four build a huge string, four expect php's own memory_limit
fatal), so copy-on-write is not built.

T6 is done (2026-09-20, macos/aarch64; `probes/t6/RESULTS.md`), on **mc 1.1.0**:
T5's wrong-reason table worked in
descending value, and re-measured:
`phpt: green 1073 / wrong 13374 / refused 3657 / skip 2947 / php-fail 344 / total 21051`
over the whole corpus, against T5's `green 80` on the same harness -- a factor
of **13**. Per directory `tests/lang` **74** (was 12), `Zend/tests` **452**
(was 38), `ext/standard/tests/strings` **180** (was 12). **1066 of the 1073
greens are in T0's "touched by none" set**; the other 7 are the first greens a
decision has an opinion about.

Six blocks, one commit each, each measured before the next was chosen: a zval
and php's ORDERED HASH (keyed, heterogeneous, insertion order, holes -- which
is `mixed`, and `mixed` is what D4 (c) always said a union lowers to);
classes, interfaces, traits, enums and objects, reached BY NAME through a
registry, which is dispatch and not reflection (D6); functions that are
`mixed` by default with defaults, variadics and closures; exceptions over a
pending-exception flag, because mc's five targets include a board with no
libc and there is no setjmp to have; constants, references, `static`/`global`
and the full `printf`; and a LIBRARY TABLE, 173 rows, whose arity invariant
the probe checks.

`probes/t5/` is untouched and still reproduces its own number. `probes/t6/` is
its two files grown -- 2541 + 843 lines to 5477 + 5022 -- and it calls **51**
names from outside itself, 48 of them frozen and the three that are not
`<float>`'s. No mc gap was found that T5 had not already reported, and nothing
was worked around.

T5 is done (2026-09-20, macos/aarch64; `probes/t5/RESULTS.md`), on **mc 1.1.0**: the first
runtime and the first compiler:
`phpt: green 80 / wrong 15367 / refused 2639 / skip 2947 / php-fail 362 / total 21033` over the
whole corpus -- green off zero, and the third column real for the first time. All 80 greens are
in T0's "touched by none" set, the 84.2% of the corpus none of section 3's decisions touches.
Two files and nothing else: `probes/t5/php.mc`
(the compiler, one `syntax("<?php")` plus `syntax_expr("$")`) and `probes/t5/php_rt.txt` (the
runtime: D10's string as a `zend_string`-shaped binary-safe handle, a packed homogeneous array,
`<float>` for `float`, one arena per D7). mc 1.1.0's `p_skip_to` closed three of T4's four lexer
gaps and a fourth T4 had not asked for (`"..."`, which is what gives php's own `\xNN`/`\u{...}`
escapes and an escaped `\$`); **T4's in-place `on_source` rewrite is deleted**, and with it the
`don't` -> `don"t` corruption. One gap is left and it is reported in section 5.

T1, T2, T3 and T4 are done (2026-09-15, macos/aarch64): see `probes/README.md` for the numbers and
`probes/tN/RESULTS.md` for each. **D2(b) is taken.** T4 answers its own gate: the grammar fits
Tier 3 with no mc change -- 14 grammar steps, 10 of them byte for byte what `php` prints -- and
the LEXER does not, which is the gap above.

T0 is done (2026-09-15, macos/aarch64; `probes/t0/RESULTS.md`): every `.phpt` under php-src run
through `php` and through a placeholder executor B that does not implement a compiler yet
(`probes/t0/mcphp-stub.sh`, exits 99, matches nothing) -- phpt: green 0 / wrong 18109 / refused 0 / skip 2947 / php-fail 339 / total 21056  (21395 tests; sapi/ excluded). The number that will move
once mc-php exists is `green`. Also: the corpus breakdown -- how much of it the decisions above
actually touch, with the real tokenizer, not a regex -- 21560 classifiable tests; D1 143 (0.7%), D5 1569 (7.3%), D6 1719 (8.0%), D4-suspect 123 (0.6%); touched by at least one 3409 (15.8%), by none 18151 (84.2%); extension-specific 9028, of which 1899 touched. Cross-checked
against php-src's own `run-tests.php` over `Zend/tests` and `ext/standard/tests/strings`, which
reconciles to the byte once three bugs this cross-check found in the harness itself were fixed
(a stray `--` corrupting `--ARGS--`, `--INI--` leaking a space around `=`, and a hardcoded
`error_reporting` value that was not this PHP build's actual `E_ALL`). T5 is not run.

## 5. What mc may need (reported, not worked around)

### Closed by mc 1.1.0: a module cannot own the LEXING of a source it claims

**Closed (2026-09-20, mc 1.1.0), and measured by T5.** `p_skip_to(uptr q)` -- the one additive
function this section named -- shipped, and it closes items 1, 2 and 3; `syntax_expr("$", &f)`
now makes `$name` lex as the `$` token plus an ordinary identifier, which closes item 4.
`probes/t5/php.mc` owns `'...'`, `#` comments, `#[Attr]`, the inline HTML between `?>` and
`<?php` -- **and `"..."`, which nobody asked for and which turns out to matter most**: the core
lexer decodes ITS escape set before any handler runs, so `\$` and `$` were the same byte and
`\xNN`/`\u{...}`/octal did not exist at all. Owning the double quote gives php's own escapes and
an interpolation that can tell an escaped `$` from a real one. **T4's in-place `on_source`
rewrite is deleted** and the `don't` -> `don"t` corruption with it (`probes/t5/g/09-html.php` has
an apostrophe inside its HTML and comes out byte for byte php's).

Two things worth writing down that `docs/reference/hooks.md` does not say:

* **`p_skip_to` is once per token.** The guard is `cp == tok_start(cur) + tok_len(cur)`, which
  the first skip breaks, so a handler cannot skip twice before the next `p_next()`. A module
  owning several adjacent regions has to decide ONE destination in a single scan.
* **The guard can never hold on a `T_STR`**, because `lex_string` points `tok_start` into the
  arena. A module that owns `'` but not `"` cannot skip a region that follows a double-quoted
  string. T5 does not hit it because it owns both.

The text below is T4's, kept for the record.



Found by T4, reduced to `probes/gap-lexer-ownership/` (`sh probes/gap-lexer-ownership/run.sh`,
exits 0 only while it still reproduces). Measured on mc 1.0.0.

`source_claim` says a source belongs to a module and the six word registrations then apply to it,
but the core lexes every source **before any handler runs** and keeps four things for itself. The
reproducer registers `source_claim` returning 1 for every source and `tok_add`s every lexeme PHP
needs -- the whole of what the surface offers -- and still gets:

```
a-single-quote.php   $a = 'a php string';   -> a-single-quote.php:2: unterminated char literal
b-single-char.php    $a = 'x';              -> 2 3 120      (T_CHAR: silently the integer 120)
c-hash.php           # a php line comment   -> c-hash.php:2: unknown directive
d-attribute.php      #[Attr]                -> d-attribute.php:2: unknown directive
f-rawtext.php        ?> <p>don't</p> <?php  -> f-rawtext.php:2: unterminated char literal
e-dollar.php         return $name;          -> hole $name has no rule binding it
```

Four separate things, in decreasing order of how much they cost:

1. **`'`** is the char-literal rule. `tok_add("'", 1)` does not beat it. A PHP single-quoted string
   of one character is silently an integer; of any other length it is `unterminated char literal`.
2. **`#`** is a directive, and there is no `directive(name, &f)` registration. `#[Attr]` is the
   same byte.
3. **A region of raw bytes cannot be skipped.** Inline HTML between `?>` and `<?php`, and a heredoc
   body, are text PHP does not lex. A handler can READ them -- `p_cp()` is the cursor and
   `p_src_end()` the end, and T4 uses both to lex `0b101`/`0o17`/`1_000` correctly -- but it cannot
   ADVANCE past them: `p_take_lit(q)` only extends a NUMERIC token and `p_resplit_punct(n)` only
   rewinds.
4. **`$name` is a `T_HOLE` and no registration reaches it.** `docs/reference/hooks.md`
   § `syntax_expr` says `$` is claimable, and it is -- for `$"..."`. `$name` is lexed as a hole and
   a registered `syntax_expr("$", &f)` does not fire for it; outside a `#rule` template that is
   `hole $name has no rule binding it`. A handler that owns its grammar position can still read it
   (`p_id() == T_HOLE`, `p_name()` is `"$x"`), so the cost is that a module wanting `$x` inside an
   expression has to own the WHOLE expression grammar. For mc-php that is going to happen anyway
   (PHP's precedence table is not mc's), so this is a cost and not a blocker.

**The workaround T4 used, and what it costs.** `on_source` hands the module `src`/`len` -- the
buffer the lexer is about to read -- and mutating it in place inside the callback reaches the
lexer (measured: `'hello'` rewritten to `"hello"` lexes as a string; `probes/t4/entry/inplace.mc`).
`probes/t4/php.mc` rewrites `'` to `"` and `#` to `//` that way, which is what makes
`g/12-singlequote.php` and `g/13-hash.php` agree with `php`. Two costs, both measured: the rewrite
must be byte for byte or every `err_at` column moves, and it is made by something that does not
know PHP's lexical states -- in `probes/t4/g/14-inline-html.php` it turned `don't` inside an HTML
fragment into `don"t`. `docs/reference/hooks.md` describes `on_source` as an announcement and
documents only that "reading is unrestricted"; writing is undocumented behaviour this repository
is relying on.

**The smallest additive fix, and it is one function.** `void p_skip_to(uptr q)`: move the lexer
cursor of the source being lexed to `q`, under `p_take_lit`'s own guard (`q` at or after `p_cp()`,
not past `p_src_end()`, and only on a token just lexed from the source being read). That is the
generalisation of `p_take_lit`, which already proves the mechanism is sound -- T4 calls it from a
handler that never reaches `parse_primary` and the four PHP integer formats come out agreeing with
`php`. With it, items 1, 2 and 3 all go away: the module's own expression parser, standing on `=`
and seeing `ld8(p_cp()) == '\''`, scans to the closing quote, builds its own `N_STR` and skips the
region. It does not address item 4, whose fix is separate and also one `if`: when a
`syntax_expr("$", &f)` is registered, a `$` outside a `#rule` template lexes as the one-character
`$` instead of as a hole (outside a template a hole is already an error, so nothing an untaught
compiler does can change).

The alternative shape, `syntax_source(&f)` -- `on_source` with a return value, a replacement
buffer, called from `lex_push_mem` before the frame is read -- would make the in-place mutation an
explicit contract instead of an undocumented side effect, but it is strictly weaker: a whole-buffer
rewrite still cannot know PHP's lexical states, which is exactly the `don"t` above.

### Closed by mc 1.1.0: 29 of the 46 `<mc/core>` names a Tier 3 module needs were not frozen

**Closed (2026-09-20).** `tests/golden/surface.txt` in mc 1.1.0 covers them. T5's `php.mc` is
three and a half times T4's and calls **48** names from outside itself: **45 are frozen**, and
the three that are not -- `float_init`, `machine_arm64_float_init`, `machine_x86_64_float_init`
-- are `<float>`'s, which the freeze covers as a bundle name and not as symbols. Nothing to ask
for. The text below is T4's, kept for the record.



Measured by T4 over `probes/t4/php.mc` (`docs/reference/hooks.md` § 8 is the promise,
`tests/golden/surface.txt` is what `make check-freeze` enforces). 17 of the 46 are in the frozen
list -- `syntax`, `source_claim`, `on_source` and fourteen `p_*`. The other 29 are not, and **16 of
them are named in `docs/reference/hooks.md` § 4 as "the parser's public API. Fixed names"**:
`parse_expr`, `parse_stmt`, `parse_block`, `parse_params`, `parse_function`, `top_add`, `def_add`,
`param_new`, `list_append`, `lex_set_libs`, `lex_root_of`, `lex_root_count`, `lex_root_name`,
`lex_root_dir`, `lex_inc_count`, `lex_inc_at`. The remaining 13 are `<mc/core>` facilities a taught
compiler cannot avoid: `node_new`, the `nd_*`/`set_nd_*` accessors, `tok_add`, `word_id`,
`def_find`/`de_at`/`de_val`, `path_join`/`path_norm`, `read_file`, `xalloc`, `xstrdup`, `str_eq`,
`cstrlen`, `err_at`/`err_at2`.

Not a defect and nothing is worked around: it is a coverage question for
`scripts/surface-extract.sh`'s prefix list, and mc-php would like to know which of the 29 it may
depend on for 1.x.

### Settled by T4

- "does `syntax` work keyed on a PUNCTUATION token" -- **yes**. `tok_add("<?php", 5)` is one token
  even though it contains letters, and `syntax("<?php", &f)` fires on it; `word_add` refuses the
  core keyword range and nothing else. T4's whole grammar hangs off that one registration.
- `word_id` answers only for ALPHA-initial lexemes (`te_word`, from `is_alpha` of the first byte),
  so the id of `;` or `(` has to come from `tok_add`, which is idempotent.
  `docs/reference/hooks.md` does not say this; `examples/lang` does it (`tok_add(".", 1)`).
- A `p_push_source` from `user_init` does not replace the entry: `lex_init` has already pushed it,
  so the pushed text is parsed and then the original is too (`main` declared twice, measured).

### Open: `mc --exe` loses its exports once `__bss` reaches one page (macos/aarch64)

Found by T3, reduced to `probes/gap-bss-exports/` (`sh probes/gap-bss-exports/run.sh`, exits 0 only
while it still reproduces). Measured on mc 1.0.0, macOS 26 / arm64:

```
bss=8192  __DATA vmsize=16384 filesize=16384 | __LINKEDIT vmoff=32768 fileoff=32768 -> 42
bss=16000 __DATA vmsize=16384 filesize=16384 | __LINKEDIT vmoff=32768 fileoff=32768 -> 42
bss=16384 __DATA vmsize=32768 filesize=16384 | __LINKEDIT vmoff=49152 fileoff=32768 -> FAIL ... symbol not found in flat namespace '_mc_answer'
bss=65536 __DATA vmsize=81920 filesize=16384 | __LINKEDIT vmoff=98304 fileoff=32768 -> FAIL ...
```

An `mc --exe` Mach-O executable carries no `LC_DYLD_EXPORTS_TRIE` (`export_size 0`), so dyld
resolves a `dlopen`ed bundle's flat-namespace imports out of the classic symbol table
(`LC_SYMTAB` delimited by `LC_DYSYMTAB.iextdefsym`/`nextdefsym`). That works -- T2 proves it, and
patching `nextdefsym` to 0 turns the same binary into `symbol not found in flat namespace`, which
is what identifies the table. It stops working when `__bss` makes `__DATA`'s vmsize exceed its
filesize by a whole 16 KiB page: `__LINKEDIT`'s offset from the mach header **in memory**
(`vmaddr - __TEXT.vmaddr`) then diverges from its offset **in the file** (`fileoff`), the symbol
table is read out of `__DATA`'s zerofill instead, and every symbol the binary exports becomes
invisible. The binary still runs correctly -- only `dlopen` is affected. The control: 16384 bytes of
**initialized** data instead of `__bss` keeps the two offsets equal and works.

Two independent fixes, either one enough, both additive (a MINOR on mc's frozen surface):

1. pad the file so `__LINKEDIT.fileoff` equals its offset in memory (what a zerofill-heavy segment
   costs is one page of zeros in the file), or
2. write an `LC_DYLD_EXPORTS_TRIE`, which makes the symbol-table road moot. `ld` takes road 2,
   which is why the `[linker]` road is immune.

Nothing here is worked around: T3 uses the `[linker]` road and says so. This matters to mc itself
beyond mc-php -- mc's own compiler carries a 32 MiB `heap[]` in `__bss`, so *any* mc binary with an
arena is already past the threshold, and is not usable as a `dlopen` host today.

### Settled by T2, correcting what this section said before

- "`mc --exe` writes imports only ... Mach-O has no export trie" -- the second half is true and
  **does not matter**: dyld falls back to the classic symbol table, and mc fills it correctly (see
  above for the one case where it goes wrong). `mc --exe` is a usable `dlopen` host on macOS.
- "the `[linker]` road with `-export_dynamic` does it today" -- `-export_dynamic` changes nothing on
  macOS; the same link without it behaves identically. It is an ELF habit.
- "a variadic callee in mc" -- **no mc change needed** on Apple arm64. Variadic argument N is mc
  parameter 8 + N, so four of them are reachable directly and any number by walking
  `ld64(x29 + 16 + 8*n)` by hand. SysV passes the first eight variadic arguments in registers
  instead, so on Linux the natural shape is different again and needs its own probe -- neither is
  an mc gap.

### Open: there is no way to own the bytes BEFORE the first token (macos/aarch64)

Found by T5 on mc 1.1.0. `p_skip_to` moves the lexer cursor relative to a token that has already
been lexed, so a source whose FIRST bytes are not lexable by the core has nowhere to hang a
handler. For PHP that is a file opening with inline HTML -- `Hello <?php echo 1; ?>` -- which the
core lexes as stray identifiers before `syntax("<?php")` can fire. `on_source` is handed the
buffer and `source_claim` is asked at push time, but neither can move the cursor, and mutating
the buffer in place is the undocumented workaround T4 used and T5 deleted.

`probes/t5/php.mc` refuses such a file by name (`ph_on_source` reads the first five bytes) rather
than mis-lexing it. **38 of the 21219 `.phpt` with a `--FILE--` section die on it** -- small, and
the honest number. Everything that closes with `?>` and trailing text is fine, because that
region hangs off a token.

The smallest additive fix, in `p_skip_to`'s own shape: let `on_source` return a byte offset at
which lexing should begin (0 meaning the whole buffer), or give `p_push_source` an offset
argument. Either is one parameter and changes nothing for a module that does not use it.

### Confirmed by T9, and still the only one open

T9 is the sixth probe to grow `probes/t*/php.mc` and it found **no new mc
gap**. The one T5 reported is unchanged and T9 hits it exactly as often:
**38 of the 21219 `.phpt` with a `--FILE--` section** open with inline HTML
and are refused by name.

Two things T9 needed from mc that were already there:

* **`p_cp()` past the CURRENT token.** The module has no token lookahead, and
  twice in T9 it needed one: to tell `static function` from `static::`, and
  to tell an intersection type `A&B` from a by-reference parameter `A&$x`.
  Both read the cursor, which sits just past the token the core last lexed --
  the road `ph_number` has taken since T5 for a literal's tail.
* **`type_new(name, 8, 8, TK_INT)`**, which is how the three php handle types
  (`php_str`, `php_arr`, `php_zval`) exist at all.

### Confirmed by T8, and still the only one open

T8 is the fifth probe to grow `probes/t*/php.mc` and it found **no new mc gap**. The one T5
reported is unchanged and T8 hits it exactly as often: **38 of the 21219 `.phpt` with a
`--FILE--` section** open with inline HTML and are refused by name.

Three things T8 needed from mc that were already there, worth naming because they are what a
Tier 3 module reaches for once it grows a standard library:

* **`realpath`**, which `<mc/host>` declares for its own use (`src/host_macos.mc`): php reports
  the path it RESOLVED, symlinks included, so on macOS every diagnostic raised by a script under
  `/tmp` printed the wrong one of `/tmp` and `/private/tmp`. One call, at compile time, and
  `__FILE__`/`__DIR__` went with it.
* **`MAXPARAMS` is 12**, which is a documented mc limit and not a gap -- it is what sizes
  `func_get_arg`'s choice among the callee's parameters (a count, an index and ten of them).
* **A node may appear in an mc AST ONCE.** The arguments of a call are its SIBLING chain, so
  reusing one node in two places makes a cycle, and a cycle is a stack overflow in the walker
  rather than a diagnostic. `docs/reference/hooks.md` does not say so; a module that hoists a
  value and then reads it twice has to make a second reference node.

### Confirmed by T7, and still the only one open

T7 is the fourth probe to grow `probes/t*/php.mc` and it found **no new mc gap**. The one T5
reported is unchanged and T7 hits it exactly as often: **38 of the 21219 `.phpt` with a
`--FILE--` section** open with inline HTML and are refused by name.

Two things T7 needed from mc that were already there and are worth naming, because they are
what a Tier 3 module reaches for once it has to produce a HOST-SHAPED diagnostic:
`host_getcwd()` (to absolutise a file the way php resolves it) and the ordinary libc `write`
and `exit`, which a module may declare `extern` itself -- that is how a php COMPILE-TIME
`Fatal error:` reaches stdout with exit 255 from inside the compiler. `php.mc` now calls **53**
names from outside itself: 48 frozen, 3 `<float>`'s, and those two.

### Open: one unit cannot declare a name `extern` and define it (windows, mc 1.3.0)

Built and graded on both Windows architectures since the windows branch -- the compiler is
compiled ON each Windows runner by that runner's own `mc.exe` and linked with `lld-link`
(`src/mc-php.windows-*.toml`, `tests/winsys.sh`), and `tests/windows.sh` runs the fixture gate
and the extension gate there. What was measured before any of it was written, cross-compiling
on macOS with mc 1.3.0's release binary:

- **The `duplicate #define` half is closed by mc 1.3.0** (mc PR #106: repeating a `#define` with
  the same value is legal). The reproducer that stood here now gets past it:

  ```sh
  printf '#include <mc/host_windows_x86_64>\n#include <mc/core>\n#include <sys_windows_host>\n' > w.mc
  mc --backend=pe-exe-x86_64 w.mc -o w.exe
  # mc 1.1.0: lib/sys_windows.mc:76: duplicate #define
  # mc 1.3.0: lib/sys_windows.mc:94: function declared twice
  ```

- **The second half is real and it is mc's, so the ONE-STEP road stays closed for the
  compiler.** mc's core (`src/arena.mc`) declares `open`, `read`, `write`, `close`, `creat`,
  `_exit` and `mmap` `extern`, and `<sys_windows>` DEFINES `write` (line 94) and the rest. One
  translation unit cannot declare a name `extern` and then define it; a plain prototype followed
  by a definition is fine. Reduced to three lines:

  ```sh
  printf 'extern i64 f(i64 x);\ni64 f(i64 x) { return x; }\ni64 main() { return f(42); }\n' > t.mc
  mc --exe t.mc -o t          # t.mc:2: function declared twice
  printf 'i64 f(i64 x);\ni64 f(i64 x) { return x; }\ni64 main() { return f(42); }\n' > p.mc
  mc --exe p.mc -o p && ./p   # exit 42
  ```

  Without `<sys_windows>` the one-step PE IS written -- `mc --backend=pe-exe-x86_64
  src/mc-php-windows-x86_64.mc` exits 0 -- but it imports `write`, `open`, `mmap`,
  `posix_spawnp` and fourteen more POSIX names from `kernel32.dll`, which exports none of them
  (`llvm-readobj --coff-imports`), so the loader would refuse it before its first instruction
  (mc's `docs/reference/objects.md` § 8c describes exactly that trade-off). The smallest additive
  fix in mc is C's rule: an `extern` declaration followed by a definition with the same
  signature is that definition. **Reported, not worked around**: the object + `lld-link` road is
  what mc builds its own Windows compiler with, it works, and it is the road taken here -- the
  compiler is an object linked next to `mcrt.obj` (`<sys_windows_host>`) and `winstart.obj`
  (`<sys_windows_start>`), both compiled on their own, and a kernel32 import library.

- **A PROGRAM mc-php writes does not meet it**: its translation unit is the runtime and the
  generated code, not `<mc/core>`, so `lib/rt_host_windows.mc` DEFINES the runtime's system calls
  over kernel32 (nothing declares them `extern` first) and windows/x86_64 programs use mc's
  one-step PE writer. Measured: the one-step PE imports only names kernel32.dll and ucrtbase.dll
  export (19 and 18 of them), and it runs -- 94 of 94 fixtures on `windows-latest`.

- **windows/aarch64 has no direct executable in mc** (its exe slot is 0; mc's
  `docs/build.md` § A direct PE, no lld-link: an arm64 PE needs `DYNAMICBASE` and `.reloc`,
  deferred until validated on a real Windows-on-ARM loader). `mc-php --exe` there answers `mc:
  windows/aarch64 requires a linker: there is no direct executable`, so an arm64 program is an
  object linked by `lld-link` with `kernel32.lib` and `ucrtbase.lib` (`tests/mcphp.sh`,
  `MCPHP_WINLINK`). Already known to mc; recorded here because it is what an arm64 user types.

- **Not mc's: php publishes no arm64 Windows build** (windows.php.net's 8.5 release lists
  `nts-vs17-x64`, `ts-vs17-x64` and two x86 builds). On `windows-11-arm` `setup-php` installs the
  x64 php and it runs emulated, and an emulated x64 process loads x64 DLLs -- so the extension
  on a Windows-on-ARM machine is an x64 `.dll`, cross-compiled ACROSS ARCHITECTURES by the arm64
  mc-php (`examples/hello/mcphp.windows.toml` says `arch = "x86_64"` on both hosts).

- **Not mc's either: `_emalloc` is `_emalloc@@8` in php's DLL.** `ZEND_FASTCALL` is
  `__vectorcall` in an MSVC build of php (`Zend/zend_portability.h`), and a vectorcall export
  carries its argument bytes in its name. The convention is the ordinary Win64 one for integer
  arguments, so only the name needed an alias (`_emalloc == _emalloc@@8` in `src/win/php8.def`).
  Measured: without it php refused the module with `The specified procedure could not be found`.

### Open: the TOML reader an extension's project file needs is not frozen

Found by the extension back end (2026-09-23), reported rather than worked around, and it costs
nothing today.

`src/ext.mc` reads `[extension].name`, `[extension].version` and the four `[php]` values out of
the project file with `toml_get` and `toml_int`. Both come free inside `<mc/core_build>`, which
`<mc/core>` includes, so they are present and callable in the compiler -- but **neither is in
`tests/golden/surface.txt`**, and `docs/reference/` does not document either as a callable, so
mc's own § 8 rule says they are not frozen. A minor that renamed one would break every taught
compiler that drives itself from a project file, which is what mc's own `[compiler]` road makes
the normal shape.

What mc-php would like for 1.x is the six-name family `docs/reference/toml.md` already describes
in prose -- `toml_get`, `toml_get_array`, `toml_count`, `toml_int`, `toml_entries`,
`toml_path_at`, `toml_val_at` -- named in the freeze. Nothing is asked for in code; the names
exist and behave.

The alternative, if the answer is no, is a second TOML reader inside mc-php, which
`docs/mcphp-toml.md` argues against in its own second section: the schema was chosen to stay
inside what mc already parses precisely so that no parser has to be written here.

### Open: `&name` of an `extern` cannot be linked into a loadable module (macos/aarch64, linux/aarch64)

Found by batch A (2026-09-24), on **mc 1.1.0** here, and worked around in one line rather than
patched: the runtime's output sink wanted `ph_osink = &php_output_write;`, and `php_output_write`
is resolved from the php binary when the module loads. mc materialises the address of any symbol
with `adrp` + `add` (M10's rule: "an undefined symbol when extern"), and a symbol a shared object
resolves at load time cannot be reached that way -- it needs the GOT. Reduced to three lines:

```mc
extern i64 some_host_fn(i64 x);
uptr fp;
uptr take() { fp = &some_host_fn; return fp; }
```

```
$ mc a.mc -o a.o && ld -bundle -undefined dynamic_lookup -arch arm64 \
      -platform_version macos 13.0 13.0 -syslibroot $(xcrun --show-sdk-path) -lSystem -o a.so a.o
ld: fixup error (kind=arm64_adrp_lo12) at '_take'+0x8 from a.o, target '_some_host_fn' does not have address

$ mc build . --config b.toml          # the same a.mc, [target] linux/aarch64, kind = "obj"
$ ld.lld -shared -Bsymbolic -o a-linux.so a-linux.o
ld.lld: error: relocation R_AARCH64_ADR_PREL_PG_HI21 cannot be used against symbol 'some_host_fn'; recompile with -fPIC
```

A CALL to the same extern links on both (a `bl` goes through a stub the linker makes), which is
the workaround: `lib/php_ext.mc` takes the address of a one-line local function,
`phx_owrite`, that calls `php_output_write`. What would close it in mc: a GOT load
(`ARM64_RELOC_GOT_LOAD_PAGE21`/`PAGEOFF12`, `R_AARCH64_ADR_GOT_PAGE`/`LD64_GOT_LO12_NC`, and the
x86-64 `GOTPCREL` form) for `&name` when `name` is an `extern` and the output is an object.

### Open: under `-O` a leaf function's locals take callee-saved registers, and a constant operand is a register (mc 1.1.0, macos/aarch64)

Found by the decimal-c batch (2026-09-24), measured on the extension build of `examples/decimal`
with `[project].opt = 1`, and reported rather than worked around.

Batch E's reading of the profile was that mc "saves every callee-saved register in each prologue
whether or not the function uses them". **That is not what happens, and the correction is
measured**: over the disassembly (`otool -tV`) of the final module, every function saves exactly
the `x19..x28` registers its body names -- **805 functions, 0 with a saved register the body does
not use** (`php_strpos` saved ten because it used ten). mc's own `docs/reference/machine.md` § What the arm64
allocator does says the same.

What costs is different: **the allocator's only registers are `x19..x28`, so a LEAF function pays a
store and a load per register it allocates** -- where a C compiler would put the same locals in the
caller-saved `x0..x15` for nothing. Reduced to plain mc:

```mc
i64 leaf(uptr p, i64 n) {
    i64 s = 0;
    i64 i = 0;
    loop { if (i >= n) break; s = s + ld8(p + i); i = i + 1; }
    return s;
}
```

```
$ mc --dump-asm --opt=1 leaf.mc
_leaf:
  stp x29, x30, [sp, #-16]!
  mov x29, sp
  sub sp, sp, #32
  str x19, [sp, #24]            <- four callee-saved registers, in a function
  str x20, [sp, #16]               that calls nothing
  str x21, [sp, #8]
  str x22, [sp]
  mov x21, x0
  mov x22, x1
  ...
  movz x10, #1                  <- the step is a register, not `add x19, x19, #1`
  add x19, x19, x10
  ...
  ldr x22, [sp]
  ldr x21, [sp, #8]
  ldr x20, [sp, #16]
  ldr x19, [sp, #24]
```

Eight memory operations and two moves per call that a leaf does not need, and a second
instruction for every constant operand (`mov` + `add`, `mov` + `add` + `ldr` for a field at a
constant offset, where AArch64 has `add #imm` and `ldr [xN, #imm]`). In the runtime of this
repository the leaf string routines are exactly this shape: `php_memcpy` saves 5, `php_str_eq` 4,
`php_itos_b` 5, `php_stoi_b` 7, `php_spn` 10 -- `php_spn` is 92 instructions, 20 of them the saves
and restores. On the final decimal build those routines are 36.6% of the module's time
(the § 7 table), so the saving is a few percent of it, estimated from instruction counts and not
measured: mc cannot emit the other form, so there is nothing to time it against.

What would close it in mc: let the allocator use caller-saved registers in a function that makes
no call (a leaf has `x0..x7` free once its parameters are read, and `x16`/`x17`), and give the
walker immediate forms for `add`/`sub`/`cmp` and a constant offset in `ldr`/`str`.

### Still unmeasured

- The ELF half of everything above: `probes/t2/run.sh` has never run on Linux. What HAS: the
  compiler, the runtime and now the EXTENSION -- `tests/linux.sh` grades all three on
  linux/aarch64 and linux/x86_64, and step 4 of `tests/ext.sh` loads an mc-written `.so` into
  the container's own php on each.
- Windows/PE: the program road and the extension road RUN on `windows-latest` (x86_64) and
  `windows-11-arm` (aarch64), each against the runner's own php 8.5 (`tests/windows.sh`). What
  is not measured there: the `.phpt` grid, and a thread-safe php (`php8ts.dll`, whose import
  library `tests/winsys.sh` writes but no runner loads).

## 6. After the corpus is green

Native lowering behind type inference, the web server, multithreading, async. Not before.

## 7. The extension back end -- what is built and what is next

### The roadmap, in the order the owner set it (2026-09-23)

Each step is gated before the next, and a step is done when its gate is green in CI -- not when
its code is written.

1. **Windows.** DONE on the windows branch: mc-php built natively on `windows-latest` (x86_64)
   and `windows-11-arm` (aarch64) by each runner's own mc, the runtime's kernel32 host layer
   (`lib/rt_host_windows.mc`), the fixture gate and the extension gate graded against the
   runner's own php 8.5 (`tests/windows.sh`), and a release archive per architecture built on
   those runners. What it cost mc-php and what it left open in mc is § 5.
2. **Examples first, and they are the first gates.** **Acceptance (owner, 2026-09-24): an
   example is DONE only when it is compiled from its PHP source AND it is faster than the same
   PHP interpreted (> 1x), and each one has a C TWIN -- the same functions written as an ordinary
   C extension -- measured beside it on the same harness, because the target is to come as close
   as possible to C.** `decimal` has its twin (`examples/decimal/c/`, batch A); `two-extensions`
   and `awaitable` get theirs when they are compiled from PHP. By that rule `decimal` is
   DONE since batch E -- compiled from PHP and faster than interpreted on all five legs, 1.52x to
   2.99x (macos/arm64 2.19x here, the twin 13.8x; § 7 item 1 below has the profile and the
   table) -- and the other two are not. The decimal-c batch took the module from 6.3x the C twin's
   time to 4.1x (1.51 -> 0.98 ms here), § 7 item 1. What already has code moves into
   `examples/`, each with a gate that compiles it and compares it with php. Four of the five parts
   are DONE (the examples branch, 2026-09-23), gated by `tests/ext.sh` and `tests/examples.sh`
   inside `tests/run.sh`, `tests/linux.sh` and `tests/windows.sh`, **green on all five CI legs**
   (macos/arm64, linux/aarch64, linux/x86_64, windows/x86_64, windows/arm64; the hand-written
   halves SKIP by name on the two Windows legs):
   - `hello` -- DONE, the extension gate (`tests/ext.sh`).
   - `decimal` -- DONE, and **compiled from PHP**: `examples/decimal/decimal.php`, six functions
     over strings (`dec_add`, `dec_sub`, `dec_mul`, `dec_div`, `dec_cmp`, `dec_round`), exact,
     no float anywhere, half-even rounding in every function. The differential is 60 lines byte
     for byte on every host; **1219 results agree with bcmath** where the host php has it (macOS
     and both Windows legs; the `php:8.5-alpine` image does not, and the gate says `SKIPPED`); and the bench row --
     three loan schedules, the best of nine, three rounds interleaved -- is **0.51x on
     macos/arm64** (1.72 ms interpreted, 3.41 ms compiled), 0.46x to 0.81x on the CI legs: string work
     is C inside php and mc inside mc-php. `[project].opt = 1` measured once gives 2.4 ms, 0.74x;
     not adopted. **Batch A** (2026-09-24) added the C twin and re-measured all three columns on
     one host (macos/arm64, with another process holding one core, so the absolute numbers are
     higher than above and the ratios are what compare): interpreted 3.29 ms; the module 6.48 ms
     (0.51x) before batch A and **6.41 ms (0.51x)** after; the C twin **0.238 ms (13.8x)**. The
     allocator change did not move the ratio -- the arena was a bump allocator too -- and the soak
     did: a million calls in one request, where the module used to die near 29 000. **Batch E**
     (2026-09-24) took it past php: **6.46 -> 1.51 ms, 0.51x -> 2.19x** on this Mac with the twin
     at 13.8x, and on the pull request's CI run macos/arm64 1.70x (twin 12.2x), linux/aarch64
     1.74x, linux/x86_64 1.52x, windows/x86_64 2.29x, windows/arm64 2.99x -- all from the compiler
     and its runtime, `decimal.php` unchanged (item 1 of the list below).
   - `two-extensions` -- DONE as **hand-written mc**: `extA.mc`/`extB.mc` from `reference/`,
     loaded in both orders and compared byte for byte with `extA.php` + `extB.php` interpreted.
     `extB.php` is refused -- `a php function mc-php does not have: a_add` -- because a call to a
     function the source does not declare is not lowered to a lookup in php's function table at
     call time, and the gate pins that refusal. On Windows the pair SKIPS by name (`dlsym`).
   - `awaitable` -- DONE as **hand-written mc**: `awaitable.mc` from `reference/aw6.mc`, 37 lines
     against `check.expect` (await, forked `parallel` over any callable, libcurl on pthreads under
     a semaphore, the sync primitives), and `awaitable.src.php` refused at its first line, pinned.
     Its README lists the five refusals behind it. POSIX only; Windows SKIPS by name.
   - **NEXT, not in that pull request: a large-volume "mission critical" DATABASE example.** What
     it needs from the compiler, each measured by the examples above:
     * **calling a C library from PHP source** -- sqlite3 or libpq, which is
       `awaitable.src.php`'s `#[Extern('lib')]` with its `variadic:` field: where a C variadic
       argument travels is the ABI's (on the stack after eight registers on Apple arm64, in the
       next register on AAPCS64 and SysV x86-64 -- measured, `awaitable.mc` needs both forms);
     * **a request lifecycle for the arena** -- DONE in batch A: D7 is superseded on the
       extension road (§ 3 D7), a call's memory is Zend's and freed when it returns, and
       RSHUTDOWN restores what a request changed (`docs/php-extension.md` § The memory);
     * **signatures past the scalars**: rows come back as arrays or objects, and a connection is
       a resource or an object the module declares -- today a class the source declares compiles
       and is NOT published, with no refusal (measured on `awaitable.src.php`);
     * **module-private functions** -- DONE in batch A: a leading underscore is not published
       (`docs/php-extension.md` § What is published); a class's methods, which are private, are
       still dispatched by name and typed `mixed`.

   **Found while writing them**, and fixed at the root with a fixture each:
   - a STATIC method with parameters read its first argument out of the receiver slot, because
     it was declared without one and every caller passes one: `C::f($x)` said `Too few arguments`
     (`tests/g/96-static-args.php`);
   - an `elseif` whose condition emitted statements of its own -- a string comparison, a call --
     was DROPPED: its if came back as a statement list and the else branch keeps one node
     (`tests/g/97-elseif-string.php`).

   And one recorded then, **fixed in batch A**: `str_replace` with an ARRAY search was a wrong
   answer -- `Array to string conversion` and the array's text searched for. It takes php's whole
   signature now (`tests/g/100-str-replace-array.php`).
3. **Port ctype.** php-src's `ext/ctype` written in php and compiled by mc-php, graded against
   php's own `ctype.so` (T1 measured it at 7 Zend functions and no data global).
4. **Port bcmath.**
5. **Port json.** `ext/json` cannot be built shared at all (T1), so this port is the only way a
   json extension exists outside php's own binary.
6. **Distribution -- Composer, Packagist, PIE. To be designed with the owner**: the owner stops
   at this step to think it through, so nothing here is a plan yet, only the name of the step.

### What the back end itself still owes, in the order the measurements put it

Built (2026-09-23): `src/ext.mc` and `lib/php_ext.mc`, for plain functions with declared scalar
parameters and a declared scalar return. `docs/php-extension.md` is the page; `docs/php-abi.md`
is every Zend number, with what each was measured against; `tests/ext.sh` is the gate, green on
macos/arm64, linux/aarch64, linux/x86_64, windows/x86_64 and windows/arm64 (the last two load an
x64 `.dll`: § 5).

In the order the measurements put them, each with the number that says why:

1. **The generated code.** PARTLY DONE. `--dump-asm` named two of the three causes and both are
   fixed: a statement announced its position (`php_pos`, T7's) and was followed by the unwinding
   check (`php_thrown`, T6's) whatever it contained, because ph_posstmt's own call set the flag
   that decides it; and `%` by a positive literal went through `php_mod` for a
   DivisionByZeroError that literal has ruled out. The rule now is that a statement announces its
   position only when something in it can raise a diagnostic or throw, and is followed by the
   check only then -- everything that can raise is a runtime call and `ph_call` marks every call
   it builds, so that mark is the test, conservative in the safe direction.

   Measured with `reference/bench-steady.php` (a warm-up and the best of nine, nine processes
   interleaved, because `reference/bench.php` times one cold call each and that carries a 2.5x
   code-alignment band on this host):

   | | interpreted | by hand | mc-php before | mc-php today |
   |---|---|---|---|---|
   | `fib(30)` | 30.4 ms | 2.78 ms (11.0x) | 9.62 ms (3.18x) | **4.82 ms (6.31x)** |
   | `sum(3000000)` | 9.05 ms | 1.65 ms (5.5x) | 10.55 ms (**0.86x**) | **2.26 ms (4.00x)** |

   The third cause is what is LEFT and it is the rest of the original sentence: **every local
   lives in the frame**. The hand-written column keeps its values in registers, and that is the
   whole of the remaining 1.4x on `sum` and most of the 1.7x on `fib`. Two roads to it: mc's own
   register allocator through `[project].opt = 1` -- TAKEN in batch E for every extension this
   repository builds (below) -- and a whole-program "can this function throw" fixpoint, not taken:
   since batch E the position and the unwinding check are written in place, three instructions
   together, so what the fixpoint would remove is no longer a call.

   The unwinding check is also still emitted after ANY runtime call, not only after one that can
   throw (batch E made a short, reviewed list quiet: a literal, `strlen`, the native strspn and
   trim forms, `str_replace` over three strings, `$s[$i] ?? d` -- each a callee that raises
   nothing). Narrowing it needs a per-callee classification of the 179 library rows, which is a
   whitelist whose wrong entry is a silently wrong line, so it is named rather than guessed.
   On a program road that starts 38 ms behind php none of this showed; an extension is called
   from inside a process that is already warm, so it is the whole claim.
   **Batch E (2026-09-24): the string path, measured on `examples/decimal`.** The profile came
   first. `sample` on macos/arm64 over the bench workload in a loop (8 s, 5924 samples on php's
   thread, 99.5% of them inside the module), before any change:

   | where the time went | samples | share |
   |---|---|---|
   | allocation -- `php_alloc` 555, `php_str_alloc` 226, `php_zv_alloc` 98, `phx_zero` (the call's chunk zeroed on return) 282 | 1161 | 19.6% |
   | `php_inset`: strspn's set membership, a CALL per byte of input per byte of the set | 625 | 10.6% |
   | `php_memcpy`: a byte loop | 606 | 10.2% |
   | `php_strpos` (str_replace's two passes, `_dec_sc`) | 435 | 7.3% |
   | zvals built only to call a library row -- strspn/ltrim/trim take `mixed` (`php_zv_type`, `settype`, `zv_str`, `zstr`, `znull`, `zlong`, `span_win`) | 392 | 6.6% |
   | `php_thrown` 218 + `php_pos` 169: a call per checked statement to load one word, and one to store two | 387 | 6.5% |
   | `php_strlen`: a call to load one word | 342 | 5.8% |
   | `php_str_lit`: a call and a cache test per USE of a literal | 128 | 2.2% |

   By php function, inclusive: `_dec_valid` 29.9% (strspn), `_dec_umul` 17.0% (an int array is
   zvals, and every `$a[$i]` built a key zval), `_dec_coef` 15.8% (two `str_replace`, an `ltrim`).
   `$s[$i]`, `ord()` and `.=` were not where the time was; neither was a string built in a loop
   (`php_str_concat` 0.4%: the decimal's strings are one to three limbs long).

   Every change is in the compiler or its runtime -- `decimal.php` is byte for byte what it was.
   Measured one after another with `examples/decimal/bench.php` (best of nine, interleaved, the
   same Mac), the module's column:

   | change | ms |
   |---|---|
   | main | 6.46 |
   | runtime: `php_memcpy` eight bytes a step; `$s[$i]` one of 256 shared one-byte strings (no allocation); strspn/strcspn/trim masks as a 256-bit map; strpos scanning for the first byte | 5.24 |
   | the position and the unwinding check written in place (two stores, one load) instead of `php_pos`/`php_thrown`; `strlen` of a native string loaded in place | 4.96 |
   | strspn/strcspn/trim/ltrim/rtrim over native strings take no zval; a LITERAL set's map built once per run | 4.14 |
   | a literal cannot throw, so it no longer marks its statement (nor gets spilled into a temporary) | 3.70 |
   | every literal built once before the first statement (`ph_lit_init`); a use is one load | 3.36 |
   | `$s[$i] === 'c'` compares the byte in place; `(int) substr(...)` reads the window without building it | 2.92 |
   | an int key reads and writes an array with no key zval; a fresh zval is not copied again when stored | 2.79 |
   | **`[project].opt = 1` in the project file of every extension built from php** (hello, decimal; mc's `-O`, proven on the five targets) | 1.64 |
   | a one-byte `str_replace` scans in place | 1.61 |
   | zval `+ - *` between two ints in place, and the boxes written without two more calls | 1.52 |
   | `$s[$i]` out of range warns again on the native road (it did not; now `tests/g/102`) | 1.53 |
   | a zval against a native int passes the int unboxed | 1.51 |

   `[project].opt = 1` alone, on main's compiler, is 6.46 -> 4.30 ms. **Two wrong answers the new
   fixtures found, fixed**: `-1 * PHP_INT_MIN` through zvals was `int(PHP_INT_MIN)` on arm64 and a
   SIGFPE on x86-64 (its overflow check divided by -1), and `$s[$i]` outside the string was silent
   on the native road where php warns (the zval road warned). **Two found and NOT fixed**, both
   pre-existing on main and left out of the fixtures with the reason in this line: a float whose
   shortest round-trip form has 17 digits prints its last digit one off (`PHP_INT_MIN * 3` is
   `-2.7670116110564327E+19` in php and `...328E+19` here), and `2 * $s` with a non-numeric `$s`
   says `int * string` where php says `string * int` (php swaps a commutative op's constant
   operand).

   On the pull request's CI run, the same bench row on every leg: macos/arm64 2.08 / 1.22 ms
   (1.70x, the twin 12.2x), linux/aarch64 3.08 / 1.77 (1.74x), linux/x86_64 2.10 / 1.39 (1.52x),
   windows/x86_64 4.23 / 1.84 (2.29x), windows/arm64 8.82 / 2.95 (2.99x) -- against 0.49x to
   0.93x after batch A.

   **The grid does not lose a test**, three directories against a snapshot of main measured the
   same day (`tests/grid.sh`), every move accounted for by `comm` over the five lists: `tests/lang`
   104 = 104; `Zend/tests` 763 -> **766** (`str_offset_001`, `str_offset_003`,
   `string_offset_int_min_max`: the offset warning above); `ext/standard/tests/strings` 271 ->
   **272**, and five tests leave `refused` -- `bug26878` for green, `004`, `bug69751`,
   `vfprintf_error4` and `sprintf_rope_optimization_003` for wrong. Those five were FALSE refusals:
   `printf('...%s', 'x')` was refused as "a printf format that is not a literal" because the
   literal after the format marked the call as throwing, so `ph_read_args` spilled the format into
   a temporary and it no longer looked like one. No test moved out of green.

   **What stays between the module (1.51 ms) and the C twin (0.24 ms)**, from a profile of the
   final build (2369 samples): `_dec_umul` is 20.3% inclusive -- its int array is zvals, and
   every intermediate `$r[$i + $j] + $xi * $y[$j] + $carry` is a box; allocation and the chunk
   zeroed on return are 14.5%; the php functions' own bodies are 11.6% self time, much of it mc's
   callee-saved prologue under `-O` (`php_strpos` saves ten registers to scan ten bytes); the
   rest is the runtime calls a string-shaped decimal makes per operation. Each is a feature of its
   own, not a tuning: a typed int array, inlining small php functions, and a "can this function
   throw" fixpoint -- the last now worth little, since the position and the check it would remove
   are three instructions each.

   **The decimal-c batch (2026-09-24): closing on the C twin.** The profile came first again --
   `sample`, 8 s over the bench workload in a loop, on main's build (4262 samples on php's
   thread). Batch E's three causes, checked:

   | batch E's cause | measured | verdict |
   |---|---|---|
   | `_dec_umul`'s int array is zvals | `_dec_umul` 21.7% inclusive, **12.9% of the module in array and zval calls** (`php_f_array_fill` 121, `php_arr_iget_w` 102, `php_arr_push` 77, `php_arr_iset` 59, `php_arr_new` 52, the zval arithmetic and boxes 137) | confirmed |
   | allocation | `php_alloc` 280 + `php_str_alloc` 123 + `phx_zero` 157 = **13.1%** self | confirmed |
   | the php functions' own bodies, "mc saves every callee-saved register whether or not it uses them" | 10.9% self; **but 805 of 805 functions save exactly the registers they use** | the size confirmed, the cause **corrected**: mc saves what it assigns, and what costs is that a LEAF function's registers are callee-saved too, and that a constant operand is a register -- § 5, with a reproducer |

   and what batch E did not name: `str_replace` 11.4% inclusive (`_dec_coef`'s two one-byte
   deletions, 15.2%), `php_memcpy`'s byte tail 8.1%, `$s[$i] === 'c'` as a call 4.4%, `strpos`
   5.1%.

   Every change is in the compiler or its runtime; `decimal.php` is byte for byte what it was.
   The module's column of `examples/decimal/bench.php`, every build re-measured in ONE sitting on
   this Mac (three rounds interleaved with the interpreter and the C twin; rows move by about 2%
   between sittings, which is the band the "str_pad" row falls in):

   | change | ms |
   |---|---|
   | main | 1.516 |
   | **a packed int array** (`src/packed.mc`, below) | 1.371 |
   | a cast binds as tightly as unary minus -- `(int) substr(...) - $borrow` took the subtraction INTO the cast, through zvals (and `(int) "1.9" + 0.5` was int(2)) | 1.298 |
   | one-byte `str_replace` in one pass; `php_memchr` eight bytes a step; a copy's tail one word | 1.258 |
   | a literal set's byte map built with the literals | 1.205 |
   | `str_pad((string) $int, ...)` fused; `===` between strings is lengths-then-words and quiet; strpos of one byte scans | 1.223 |
   | `php_memchr`'s word scan only from sixteen bytes | 1.169 |
   | **`str_replace('a', '', str_replace('b', '', $s))` of single bytes is one pass** (`_dec_coef`) | 1.058 |
   | `php_str_alloc` bumps the chunk itself | 1.056 |
   | `$s[$i] === 'c'` compares the byte in place, the call only outside the string | 1.050 |
   | `strpos($s, 'c')` from the start is `php_strpos1` | 1.017 |
   | a concatenation chain is one string (`php_str_cat3`/`cat4`) | 0.994 |
   | a literal index needs only the upper bound | 0.975 |

   Head to head, main against the final build, five rounds: the module **1.514 -> 0.990 ms and
   1.513 -> 0.977 ms** (twice), php interpreting the same source 3.26-3.34 ms, the C twin 0.239-0.240
   ms. **The three columns: interpreted 3.29 ms, the module 0.98 ms (3.3x), the C twin 0.240 ms
   (13.7x); module/C 6.3 -> 4.1.** `tests/examples.sh`'s own row on the final tree: 3.299 / 0.998
   (3.31x) / 0.237 (13.92x). On the pull request's final CI run, against main's run after batch E
   (the ratio is what compares; runners differ by up to ~40% in absolute time): macos/arm64
   1.68x -> **2.57x** with the twin at 12.1x (module/C 7.3 -> 4.7), linux/aarch64 1.74x -> **2.64x**,
   linux/x86_64 1.36x -> **2.47x**, windows/aarch64 2.98x -> **4.62x**, windows/x86_64 2.77x ->
   **4.35x** (`examples/decimal/README.md` has the milliseconds).

   **The packed int array** (`src/packed.mc`) is a proof and a lowering. Per plain function, a token
   scan of the body before it is compiled proves that a local array holds only ints under keys
   0..n-1 and never leaves the function: its first occurrence is `$x = []`, `array()` or
   `array_fill(0, N, V)` with N and V ints, every later occurrence is in the same block and is one
   of `$x[] = int;`, `$x[int] = int;`, a read `$x[int]` or `count($x)` -- nothing else, so passing
   it to any other function, returning it, storing it, copying it, iterating it, interpolating it,
   capturing it, `isset`/`unset`/`list`/destructuring/`&`/a compound assignment on it, a string
   key, a non-int value, all keep php's array. A body that contains `function`, `fn(`, `class`,
   `yield`, `goto`, `switch`, `eval`, `include`, `compact`, `extract`, `get_defined_vars`, `$$`, a
   heredoc or a backtick proves nothing at all. "An int" is the STATIC type the lowering will give,
   predicted by the scan and checked by the lowering where it builds each call -- a disagreement is
   a compile error naming the file, never a wrong answer. Keys are not proved in range and do not
   need to be: a missing key is php's warning and null, and a key past the end or below zero turns
   the buffer into php's ordered hash in the same handle. An element read is an int beside another
   number (php's null is 0 to every arithmetic operator) and the zval php has anywhere else; a
   variable whose only assignment is `$v = $x[K];` keeps both halves native. The buffer comes from
   `php_alloc`: Zend's chunk on the extension road, the arena on the program road. Gated by
   `tests/g/105` (eight functions the proof accepts, absent and sparse keys, `**` on a checked
   operand and a key that throws included), `tests/g/106` (seventeen ways it must fail) and the end of
   `tests/fixtures.sh`, which reads the lowering back and checks which way each went, and that a
   store whose value overflows is not reached (`try { $x[] = $x[0] * 3; }` leaves `$x` as it was:
   the value is computed and checked before `php_pk_push`/`php_pk_set`, and a key that throws is
   checked before the value is evaluated), and that `PHP_INT_MIN * -1` in either order is the
   named error on every leg (the one product whose division test could trap on x86-64 -- it does
   not: `x == -1` is tested before `r / x`, and `r / PHP_INT_MIN` cannot trap). Afterwards `_dec_umul` is 14.3% inclusive of a smaller whole,
   and its array work 3.5% of the module, from 12.9% (the buffer's own calls 135 samples of 6010,
   an element handed to `_dec_limb` as a zval 78).

   **The grid does not move a test.** The three directories against a snapshot of main measured
   the same day, `comm` over the five lists of each: `tests/lang` 104 = 104, `Zend/tests` 766 = 766,
   `ext/standard/tests/strings` 272 = 272, and every list -- green, wrong, refused, skip, php-fail
   -- identical, 0 tests in and 0 out. (The grid snapshot is the tree before the last row of the
   table, a literal index's bound test, which changes no answer: `tests/g/102` and `108` cover it.)

   **What is left between the module (0.98 ms) and the C twin (0.24 ms)**, from a profile of the
   final build (6010 samples), self time by kind:

   | where | share | why it is still there |
   |---|---|---|
   | scanning and converting digits: strspn, trim, memchr, the one-pass deletion, stoi, itos, `===` | 40.6% | `decimal.php`'s algorithm, the one php interprets: a number is a STRING, so every operation re-validates each operand, re-derives its coefficient and re-parses and re-prints its limbs; the C twin parses each operand once into digits. The byte loops themselves also pay for § 5's mc code (a leaf's callee-saved registers, no immediate operands). |
   | the php functions' own bodies | 17.6% | a call frame for every helper, the position and the unwinding check php's semantics need wherever a warning or an exception can come from, and mc's instruction selection (§ 5) |
   | copying bytes into new strings | 13.8% | a php string is an immutable VALUE: substr, concat and ltrim each make one, where C writes into one buffer; an in-place `.=` needs the string ownership php's own engine tracks with a refcount, which this runtime does not |
   | allocation, and the call's chunk zeroed on return | 13.7% | one allocation per string, for the reason above; `phx_zero` alone is 4.1% -- the runtime's allocations assume zeroed memory, and the 54 `php_str_alloc` sites were not audited to lift that |
   | the extension boundary | 7.7% | argument checks, and the result copied out of the call's chunk into a Zend string (`phx_ret_str`); the C twin allocates its result in Zend memory to begin with |
   | php itself | 3.3% | |
   | arrays and zvals | 2.6% | from 12.9%: what remains is the buffer's own calls and an element passed to a USER function's int parameter (`_dec_limb($r[$i])`), which still goes through a zval because a null there must stay php's TypeError |

   None of these is a tuning of the lowering left undone; each is either php's semantics (an
   immutable string, a position per statement) or a named limit (§ 5 in mc; the chunk's zeroing;
   inlining small php functions, which is not built because it would drop the callee's frame from a
   trace unless restricted to bodies that cannot raise).

   **Algorithmic redundancy in `decimal.php`, reported and not acted on** (the gain has to come from
   the compiler): `_dec_addsub` computes `_dec_sc` of each operand, then `_dec_at` computes it again
   along with the coefficient; `dec_cmp` computes each `_dec_sc` twice. A php author would hoist
   them; the module pays for them exactly as php does.

   **Found on the way and fixed**, each with a fixture: `(int) "1.9" + 0.5` was int(2) and
   `(bool) 0 + 1` bool(true) (the cast took the operator into its operand, `tests/g/107`); and
   `array_fill(0, -1, 0)` returned `[]` where php throws its ValueError (`tests/g/105`).
   **Found and NOT fixed**, pre-existing on main: native int arithmetic WRAPS on overflow
   (`$b = $a * 3` with `$a = PHP_INT_MAX` is `int(9223372036854775805)`, php's
   `float(2.7670116110564327E+19)`) although D10's table above says overflow to float is
   implemented. The packed array's element arithmetic does NOT inherit it silently (the review of
   #21): `+ - *` on an element, and on what such an operation answered in the same expression, is
   php's overflow test and, where php would make a float, a named `ArithmeticError` -- a refusal
   at run time, never a wrapped int (`tests/fixtures.sh` checks the text; no measurable cost,
   0.977 against 0.976 ms); an int VARIABLE assigned from one is the native road's again. And
   `function f(bool $c) { if ($c) { $x = []; } $x[] = 1; }` called with false is a SIGSEGV (an
   array local that was never assigned), measured on main's compiler; and `abs(PHP_INT_MIN)` is
   `int(-9223372036854775808)` where php says `float(9.223372036854776E+18)` (the lowering types
   `abs` of an int as an int; found by the third review of #21, which is why `abs` is not on the
   packed proof's list of int-valued calls). `$a ** $b` on two ints WRAPPED on main
   (`PHP_INT_MAX - 1` squared was `int(4)`): `php_zv_pow` is php's `pow_function_base` now
   (the first product that overflows becomes a float times libm's `pow` of what is left, which
   is php's `safe_pow`), and a checked operand of `**` goes there too (the sixth review of #21,
   `tests/g/105`'s `pk_pow`). Also found and NOT fixed: the float printer is not the shortest
   round trip -- `var_dump(1.0000000000000002E+64)` prints `float(1.0E+64)` while the value
   itself compares unequal to `1.0E+64`, so `10 ** 64` is computed right and printed wrong. And
   an assignment from anything that throws clobbers its target on main: `$t = 7; try { $t = g(); }
   catch (Exception $e) {}` leaves `$t` 0, where php leaves 7 -- the store happens before the
   statement's unwinding check. The packed STORE is fixed here (the seventh review of #21); the
   scalar assignment is the general road's and is not (a `$t = $x[0] * 3` that overflows leaves
   the wrapped int in `$t` behind the ArithmeticError).

2. **A php ternary allocated per evaluation** -- DONE in batch A. `a ? b : c` lowered its value
   through a zval whatever the branches were, so `return $n < 2 ? $n : f($n-1) + f($n-2);`
   exhausted the arena at `f(30)`; the condition is native now and so is the value when both
   branches share a type (`tests/g/98-ternary.php`).
3. **A declared scalar RETURN was not checked** -- DONE in batch A, on both roads, with php's own
   rule and `TypeError` (`tests/g/99-return-type.php`, `tests/ext.sh` step 8), including a
   function that falls off its end (`none returned`) and a bare `return;`, which php refuses
   while compiling (`tests/g/101-return-bare.php`). Methods and closures still lower their
   return as `mixed` and are not checked.
4. **The arena had no request lifecycle** -- DONE in batch A by the owner's decision: the
   extension road allocates through the Zend Memory Manager (§ 3 D7), with RSHUTDOWN
   (`tests/ext.sh` step 10, `examples/decimal/soak.php`).
5. **Output buffering** -- DONE in batch A: one sink, `php_out1`, which is `php_output_write` on
   the extension road (`examples/hello/check.php`'s last two lines).
6. **Two mc-php extensions in one process** both EXPORT every runtime symbol -- but measured
   by `tests/examples.sh` (examples/hello and examples/decimal, both load orders, every host),
   each keeps using its OWN: mc calls and takes addresses with direct `bl`/`adrp`, and the Linux
   link is `-Bsymbolic`, so nothing inside a module goes through the loader. What is left is the
   exported names themselves -- a third module that looked one up would find the first loaded.
   `docs/mcphp-toml.md` § The symbol prefix is the design that answers that.
7. Then the signature: `mixed`, `array`, an object, a class the module declares, a namespace,
   defaults, variadics, by-reference. Each is a named refusal today.

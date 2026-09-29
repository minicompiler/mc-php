# Threads: the runtime's state, per thread

Step 1 of the threads plan. The runtime (`lib/*.mc`) and the code the compiler generates can now
run on several OS threads at once. Nothing here is the public API: step 3 is. This step gives
each thread its own state, and it proves that the single-threaded road costs what it did.

## The inventory

This table lists every piece of mutable global state in the runtime and in a generated module.
Each piece is either **per thread**, which means it is moved into the thread block, or **shared**.
A shared piece has a reason why it is safe to share. The raw list is 122 globals: 30 in
`lib/php_ext.mc`, 91 in `lib/php_rt.mc` and 1 in `lib/rt_host_windows.mc`. It was taken from the
tree at `bac2dcf`.

### Per thread: 94 words in the thread block (`lib/php_tls.mc`)

| what | names |
|---|---|
| the arena | `ph_hbase` `ph_hlim` `ph_top` `ph_tidx` (new: the thread's index, 0 on the booting thread) |
| an extension call's Zend chunk | `ph_zalloc` `ph_zcur` `ph_zpos` `ph_zlim` `ph_pin` |
| the temporaries and escaped strings | `ph_pool` `ph_pn` `ph_pcap` `ph_esc` `ph_en` `ph_ecap` |
| counters (`MCPHP_STATS`) | `ph_rc_inplace` `ph_rc_copied` `ph_rc_built` |
| output and output buffering | `ph_out[4096]` `ph_outn` `ph_osink` `ph_nob` `ph_obx` `ph_obb[]` `ph_obn[]` `ph_obc[]` |
| diagnostics | `ph_dfile` `ph_dline` `ph_erep` `ph_disp` `ph_log` `ph_quiet` `ph_msg[1024]` `ph_msgn` |
| handlers | `ph_ehz` `ph_ehprev` `ph_ehmask` `ph_ehin` `ph_xhz` `ph_xhprev` |
| exceptions and objects | `ph_exc` `ph_lsb` `ph_objid` `ph_dt_ran` `ph_dt_head` `ph_sdfn` `ph_nsdfn` |
| the random sequence | `ph_seed` |
| the file table | `ph_nfh` `ph_fh_fd[]` `ph_fh_eof[]` `ph_fh_own[]` `ph_fh_name[]` `ph_rdbuf[4096]` `ph_mode_rw` `ph_mode_app` `ph_mode_trunc` `ph_mode_create` `ph_mode_excl` `ph_tmpseq` `ph_uniqseq` |
| the parsers' cursors | `ph_tok_s` `ph_tok_i` `ph_sc_p` `ph_sc_s` `ph_sc_n` `ph_pk` `ph_pkn` `ph_pkc` `ph_pk_star` `ph_js_bad` `ph_jd_p` `ph_jd_s` `ph_jd_n` `ph_jd_bad` `ph_jd_assoc` `ph_us_p` `ph_us_s` `ph_us_n` `ph_us_bad` |
| an extension call (`lib/php_ext.mc`) | `phx_cl` `phx_cn` `phx_cc` `phx_keep` `phx_depth` `phx_home` `phx_floor` `phx_efloor` `phx_dirty` `phx_gen` `phx_zmirror` `phx_zexcz[16]` `phx_lz` |

Scalars come first, so that each one is within a load's immediate offset of the block's base.
The buffers follow the scalars. Step 3 appends three words for the thread API: `ph_shared`
(shared mode), `ph_troot` (the block of the program or request a thread belongs to) and `ph_tret`
(that root's list of kept arenas). The block is 12344 bytes, 12464 in a ZTS build.

### Shared, and why

| names | why it is safe |
|---|---|
| `ph_heap` | the booting thread's arena. Every other thread has its own (`ph_hbase`). |
| `ph_classes` `ph_ce_stdclass` `ph_ce_closure` | written at bootstrap. `ph_ce_closure` is lazy, so `php_thr_run` makes it on the booting thread before any other thread starts. |
| `ph_str_e` `ph_ch1` `ph_p10_done` | these were lazy. `php_bootstrap` now builds them eagerly: the empty string, all 256 one-byte strings and the powers of ten. |
| `ph_consts` | written by `define()` and read by `constant()`. Shared by every thread since step 3; `php_thr_start` creates the table before the first thread starts, so no two threads race to create it. |
| `ph_globals` `ph_rsl` | the global variable table and a static's reset list. Shared by every thread since step 3, with the races the developer's (§ Step 3). |
| `ph_rcchk` `phx_stats` | process-wide settings, read once from the environment. |
| `ph_eng` `phx_engt` `phx_eg` `phx_pce` `phx_zalloc_fn` `phx_egx` `phx_egx_done` | the engine's addresses and offsets, resolved on the booting thread. Another thread never enters the engine (see "php's engine" below). |
| `phx_me` `phx_fe` `phx_ai` `phx_nfn` `phx_nai` `phx_cfe` `phx_ncm` `phx_cfirst` | the module entry, the function entries, the arginfo and the published class tables. They are built in MINIT and read-only after it. |
| `phx_mark` `phx_snap` | the arena snapshot taken at the end of MINIT. It is restored at request start, on the booting thread. |
| `ph_rsnap` | the request's roots, saved and restored on the booting thread. |
| `ph_boot_done` | written once, by `php_bootstrap`. |
| `rtw_nio` (Windows) | **removed.** It is now a local of `read`/`write`. |
| `ph_tmain` `ph_tcur` `ph_mt` `ph_tkey` | the mechanism itself (below). They are written only by the booting thread, and only while no other thread runs. |
| `ph_tapi` `ph_ttab` `ph_tcap` `ph_tnext` `ph_dfr` `ph_dfrn` `ph_dfrc` | the thread API's handle table and the extension road's deferred frees (§ Step 3). Written under the runtime's lock (`ph_lock`). |

### Generated module globals

| prefix | what | why it is safe |
|---|---|---|
| `phl_` | a string literal's cache | built by `ph_lit_init` before the program's first statement. A literal is immutable and never counted. |
| `phm_` | a byte map built from a literal | built in `ph_lit_init`, after the literals. |
| `ce_` | a class entry | built at bootstrap, and read-only after it. |
| `phf_` | a call site's cache of php's function table | written only through `phx_flook`, which another thread cannot reach. |
| `phst_` | a function `static` | shared by every thread since step 3, as a C `static` is. |

One more shared write is allowed and is benign: the hash that a string caches in its own header.
A literal is shared, and two threads can hash it at the same time. Both threads write the same
8 bytes to one aligned word, so the result is the same whichever write lands last.

## The mechanism

Every runtime function that touches per-thread state starts with this line:

    uptr phT = ph_tcur; if (!phT) phT = ph_tslow();

It then reads the state with `ld64(phT + PHT_x)`. While only the booting thread runs, `ph_tcur`
is that thread's block, `ph_tmain`. The cost is one load and one branch that is not taken. When
another thread starts, `php_thr_run` sets `ph_tcur` to 0. From then on every function asks the
host's thread-local slot:

- POSIX: `ph_tslow` calls `pthread_getspecific`.
- Windows: `ph_tslow` calls `TlsGetValue`.

When the last thread joins, the fast path comes back -- unless the thread API was used: its
detached threads may still run, so the slot stays in use until the process ends.

The generated code names seven of these words: `ph_exc`, `ph_dfile`, `ph_dline`, `ph_pn`,
`ph_pool`, `ph_pcap` and `phx_lz`. The compiler keeps those names through `opt` and `rc`. After
parsing, a pass (`src/tls.mc`) does three things:

- It lowers each of the seven names to a load or store off `phT`.
- It inserts the same first line into each function that needs it.
- It folds the `phT` copies that inlining brings in from runtime bodies into one `phT`.

Each other thread gets the following:

- **An arena.** It grows by chunks: 64 KiB first, then doubling up to 64 MiB a chunk, each
  `mmap`'d (POSIX) or `VirtualAlloc`'d (Windows) when the previous one is full. (Step 1 mapped one
  256 MiB arena, 64 MiB on Windows; step 3 replaced it, because a kept arena of that size per
  thread is not a price a program should pay.)
- **A block.** It inherits these from the starting thread: `error_reporting`, `display_errors`,
  `log_errors`, the error and exception handlers, and the file table. It also gets a random seed
  mixed from the starting thread's seed.
- **No Zend allocator** (`ph_zalloc` = 0). So its strings live in its arena and never touch Zend.

When a thread of `mcphp_threads` ends, its arena and its block are unmapped. A thread of the
API keeps its arena until the program or the request ends (§ Step 3). A thread never pins
(`php_pin` pins only a Zend chunk, which such a thread does not have). The one case where a pin
would matter is a thread storing into module state, and step 1 refuses that. A first version did
pin: it kept the whole arena of any thread that installed a handler, or called `strtok` or
`fopen`. That was 256 MiB (64 MiB on Windows) per thread per call, and it kept memory that nothing
pointed into any more. `tests/c/10-threads-vm.php` measures the process's virtual size around
4 rounds of 8 threads that call those six builtins. Its bound is 256 MiB, and the first version
grew by 8192 MiB. The measurement is `mcphp_vm()`:

- macOS: `task_info`'s `virtual_size`;
- Linux: `/proc/self/statm`;
- Windows: the committed bytes, from `K32GetProcessMemoryInfo`.

`tests/leaks.sh` counts Zend blocks, so it cannot see this kind of leak.

Output from another thread goes to fd 1 directly. On the extension road, this bypasses php's
output layer, because that layer is part of php's engine.

## Module state in step 1 (replaced by step 3)

The approved plan says a module's memory is shared, as a C module's is. A global or a static
that one thread writes is seen by the other threads, and the developer handles the races. That
is step 3's semantics, and these values stay ONE shared copy. They are not moved into the thread
block, now or later.

Step 1 does not yet make a shared write safe. A value that another thread stores lives in that
thread's arena, and the stores are not ordered. So in step 1 another thread gets an Error, not
a crash, when it reaches module state:

- a `global`;
- a `static`;
- `define()`;
- `class_alias()`;
- `register_shutdown_function()`. Only the booting thread's shutdown list runs, so a callback
  that another thread registered would otherwise be dropped with no message.

The message was `mc-php: a global variable is shared by every thread: another thread may not
reach it`. Step 3 lifted it for a global, a static and `define()`; `class_alias()` and
`register_shutdown_function()` still refuse another thread, with
`mc-php: class_alias() runs only on the thread that started the program or the request`.

## php's engine

A php built without ZTS has one executor and one allocator for the whole process. Another thread
must never enter them. Every road into the engine first checks the thread's index:

- a call through php's function table (`phx_flook`, `phx_fcall_do`);
- a php callable (`phx_vcall`);
- a proxy's property or method (`phx_pget`, `phx_pset`, `phx_pcall`, `phx_pis`);
- `new` of a published class (`phx_pnew`).

On another thread, each of them throws the runtime's `Error`:
`mc-php: php's engine called from another thread (this php has one engine for the process)`.

This guard has one consequence that is easy to miss, on the extension road. An error handler that
php installed is a php callable, so calling it goes through `phx_vcall`. A thread inherits the
handler of the thread that started it. So a thread that raises a warning while such a handler is
installed gets the Error instead of the handler's call.

**This guard is interim until step 3,** which gives another thread a road into the engine: a
ZTS context, or a call handed to the thread php runs on.

`tests/ext/threads` proves it: `th\probe` calls a function that only php knows. From the thread
that php runs on, it answers 1002. From 4 other threads, each thread catches the Error.

## The fast path's flip

`ph_tcur` is written only by the booting thread, and only at these two points:

- **It goes to 0 before the first thread is created.** A thread reads `ph_tcur` only after
  `pthread_create` or `CreateThread` has returned, and that call orders the store before the
  new thread.
- **It goes back to `ph_tmain` only after the last join.** The join orders every store of a
  thread before the booting thread goes on.

A thread that starts threads of its own does not touch the flip. It already runs with `ph_tcur`
at 0, and it joins its own threads before it returns. So when the booting thread's joins are
done, every thread is gone. The host's slot (`pthread_key_create`, `TlsAlloc`) is made once and
reused on every run.

Each of these is tested:

- **Before and after.** Every thread checks at its start and at its end that the fast path is
  off. If the flip ran early or late, the check calls `php_die`. `ph_thr_check` runs on every
  thread of every test.
- **Nested.** `tests/c/09-threads.php` has 4 threads that each start 3 threads. There are
  3 rounds, and each round is compared with the booting thread's own `work()`.
- **Reused slot.** `tests/c/09-threads.php` runs 1500 times in a row, one thread each run. That
  is more runs than macOS has keys, 512, so a slot made per run would run out.

## Refcounts: no atomics

In step 1, only immutable values cross threads:

- literals, which are flagged immutable and never counted;
- class entries, which are never counted.

A thread's own values live in its own arena and are counted by that thread alone. The only other
state shared between threads is module state, and module state refuses another thread. No
refcount is ever touched by two threads, so none is atomic. The single-threaded cost of an atomic
refcount is therefore not paid. Step 3's API is where values first cross threads, and it has to
revisit this.

## The cost of each option, measured

These numbers are for one read of one per-thread word, in a microbenchmark on an Apple M4. The
unit is picoseconds per call.

| option | ps / call |
|---|---|
| a plain global (the old code) | ~1000 |
| `pthread_getspecific` on every access | ~1500-1750 |
| raw thread-specific data, read inline | ~1500-1750 |
| **`ph_tcur` fast path, slot only when threaded (chosen)** | ~1000-1250 |

`examples/decimal` measures the same choice on a whole program:

- The main branch, before this work: 0.224 ms (1.78x its C twin).
- A variant that always uses TLS: 0.265 ms (2.11x, +18%).
- The chosen form: the numbers are in the PR. It is within a few percent of main.

A `sample` profile shows where the few percent go. The module's total samples are the same on
both builds. The whole difference is in `f__dec_umul`, whose inner loop is instruction for
instruction identical. So the difference is the loop's alignment, not the new code.

## The test gate (`mcphp_threads`)

`mcphp_threads('f', $n, $arg)` runs the compiled function `f(int $arg, int $i): int` on `$n` OS
threads (1..64) and returns the sum of the results. It returns -1 if a thread ends with an
uncaught throwable. `f` must be a literal that names a function declared above the call. Both the thread
that booted and a thread it started may call it.

This is a test hook, not an API. These tests use it:

- `tests/c/09-threads.php` (the program road);
- `tests/ext/threads` (the extension road, `tests/ext.sh` step 20);
- the threads block of `tests/leaks.sh`.

## ZTS: a module for a thread-safe php (step 2)

`[php].thread_safety = "zts"`, or the ZTS half of `"both"`
([mcphp-toml.md](mcphp-toml.md) § `php.thread_safety`), builds a module that a thread-safe php
loads, and that php may run requests on several of its threads at once -- FrankenPHP does, with a
pool of php threads. The runtime is the NTS one with the text swaps `src/program.mc` lists, plus
`lib/php_zts.mc`, which is pushed for that output alone. The NTS output does not change by one
byte (measured with `cmp`, [php-extension.md](php-extension.md) § Thread safety).

### One block per php thread

The module declares TSRM module globals: `zend_module_entry`'s `globals_size` is the thread
block's size, `globals_id_ptr` the module's resource id, and `globals_ctor`/`globals_dtor` the
module's. php allocates a block for every thread it runs (`ts_allocate_id`), and the module finds
it as `TSRMG_BULK(id)` of the calling thread's `tsrm_get_ls_cache()`. At a thread's first request
the block gets its own arena, its own copy of the module's per-thread words and the file table's
standard streams; when php ends the thread, `globals_dtor` unmaps the arena and the words. The
thread that loaded the module keeps the block MINIT ran on.

The engine's executor globals are read the same way, per thread: the calling thread's TSRM block
plus `executor_globals_offset`, taken on that thread at its first request and never cached from
MINIT. `EG(exception)`'s offset, which the runtime measures by throwing one at a thread's first
call (it is not the headers' 960 on Windows), is a per-thread word too, and so is the flag that
says it was measured: RINIT holds the measurement off by setting the flag in its OWN block, so no
thread ever reads or writes back another thread's value. Each php thread measures once, in its
own engine.

A php that does not export `tsrm_get_ls_cache` or `executor_globals_offset` is not a thread-safe
php this module can serve. The module says so from `get_module`, before php reads its header, as
an `E_CORE_ERROR`: `mc-php: this ZTS extension needs php's tsrm_get_ls_cache, which this php does
not export`. php ends the process on an `E_CORE_ERROR` at startup. `tests/ext.sh` § 2c and
`tests/both.sh` load the ZTS module into an NTS php, which lacks both names, and check the
message.

### What each request starts from

A C extension keeps its per-request state in its module globals and its read-only state in
static memory. The module does the same with what the compiled PHP writes:

| per php thread, and copied from MINIT's at each request | names |
|---|---|
| the global variable table | `ph_globals` |
| the constants | `ph_consts` |
| the class registry, and `Closure` | `ph_classes` `ph_ce_closure` |
| a class's static properties | a table per class (`phz_sp`), copied from the class's own |
| a function's `static`s, and the list that resets them | the `phst_` slots, `ph_rsl` |
| a call site's cache of php's function table | the `phf_` slots |
| the engine's executor globals | `phx_eg` |

The `phst_` and `phf_` slots are module globals the compiler generates. For a ZTS output
`src/tls.mc` moves them into an area of their own, one per php thread (`phz_mod`), and rewrites
every use to read it. At RINIT, `phz_privatize` copies MINIT's arrays and objects into the
thread's arena: arrays and objects deeply, with one identity map per request, so a value two roots
share stays one value and a cycle ends. A string MINIT built is not copied: it is module memory,
interned and never counted. So a request writes only its own copy, and a request on another
thread at the same moment never sees it.

MINIT's own memory is then read by every php thread and written by none. That is measured, not
assumed: with `MCPHP_ZTS_READONLY=1`, MINIT ends by making the module's MINIT memory read-only
(`mprotect`), so a request that wrote it would fault on the spot. `tests/frankenphp.sh` runs with
it on.

### What is not per thread, and why

| what | why, and the measurement |
|---|---|
| strings built at MINIT | immutable (`ZS_MODULE`, interned, never counted). 3 runs of 4000 requests, 32 at a time, on 8 php threads, with MINIT's memory read-only: no fault. |
| the module and function entries, arginfo, published class tables | built in MINIT and read-only after it, as in a C extension. Same measurement. |
| an engine object built at MINIT | there is none: MINIT cannot build one. `new ArrayObject([1])` at a module's top level is `Uncaught Error: Class "ArrayObject" not found`, measured in an NTS php (macOS) and under FrankenPHP (ZTS), so no module state holds one. |
| the module's own worker threads (steps 1 and 3) | inside a php request thread they are OTHER threads that share the REQUEST's globals, statics and constants: their block points at the request's module words (`php_thr_block` in `lib/php_zts.mc`). `class_alias()` and `register_shutdown_function()` still refuse them. |
| an engine call from a worker | unchanged from step 1: a worker still gets an Error when it reaches php's engine. A ZTS php gives each of ITS threads an engine, but a worker has none until someone starts one, and that is step 3b. |

### The gate, and the cost

`tests/frankenphp.sh [aarch64|x86_64]` builds `tests/ext/zts/zts.php` as a ZTS module and loads it
in FrankenPHP (`dunglas/frankenphp:php8.5-alpine`, php 8.5.11 ZTS) with 8 php threads and
`MCPHP_ZTS_READONLY=1`. It sends 400 requests to warm up and then 4000, 32 at a time. Each request
calls a function that writes a global array, a static, a class's static property and an object's
property, defines a constant, throws and catches, makes a closure, calls a PHP function through
php's function table, and echoes into an output buffer the script opened. The gate requires:

- every answer is the formula's -- each request started from MINIT's state and saw only its own
  writes;
- the answers came from at least two php threads;
- with `MCPHP_ZTS_EGX_WRONG=1` every php thread starts from a wrong `EG(exception)` offset (456,
  `EG(function_table)`, never NULL), and the warm-up's 400 requests -- every thread's first ones,
  32 at a time, after a readiness probe that calls nothing in the module -- must all come out
  right, including a callable that throws and one of php's own functions called through a
  variable, which a wrong offset breaks;
- FrankenPHP's resident memory after the 4000 is within 32 MiB of what it was after the warm-up;
- no fault in FrankenPHP's log.

Measured on linux/aarch64 (Lima): 3 runs, every answer right, 5 to 8 php threads, resident
memory +2..3 MiB. CI runs it on the linux/aarch64 and linux/x86_64 legs. The `EG(exception)`
check has teeth: a build whose threads never measure fails all 400 warm-up answers. What it did
NOT reproduce, in 8 runs, is the race the per-thread flag removes (a shared flag one thread's
RINIT could write back as 1 before any thread measured): that fix stands by construction, not
by a failing run. The Windows ZTS legs, where the measured offset is not 960, run the single
threaded extension gates only: there is no threaded SAPI there.

The per-thread road costs a lookup where the NTS module reads a global. `examples/decimal`'s
`bench.php` (best of 9, 5 runs each, linux/aarch64): the NTS module under `php:8.5-alpine` 0.228
ms, the ZTS module under `php:8.5-zts-alpine` 0.269 ms, +18%. The same script interpreted is
2.526 ms and 2.650 ms: php's own ZTS build is 5% slower on its own.

## Step 3: the thread API

Step 3 is two pull requests. **3a is built**: the API, the program road, compiled callables on
the extension road (NTS and ZTS), and shared module state. **3b is not built**: php callables on a
ZTS worker, in a php context of their own. The owner's model is `std::thread`: real OS threads,
memory shared as in C, and races are the developer's. Threads are a goal of their own: they do not
depend on `await` or on http.

### The API

Five builtins, compiled by mc-php on both roads:

```php
$t = mcphp_thread_start(callable $fn, mixed ...$args): int;  // a handle
$r = mcphp_thread_join(int $t): mixed;      // the result; rethrows what $fn threw
mcphp_thread_detach(int $t): void;          // runs on; nobody joins it
$n = mcphp_thread_running(): int;           // threads of this program or request not finished
$c = mcphp_hardware_concurrency(): int;     // logical CPUs, as std::thread's
```

- **Names.** The `mcphp_` prefix is mc-php's own. php has no function with it, and the step 1 and
  step 2 test hooks already use it (`mcphp_threads`, `mcphp_thread`, `mcphp_vm`). ext/parallel
  is classes in the `parallel\` namespace, so it cannot collide either.
- **The primitive layer.** These five are the layer a later, object-shaped API builds on. A
  `Thread` class with `start()`/`join()` can be written on top of them in PHP, or added to the
  runtime later, without changing any of the five.
- **An int handle, not an object.** It is a value, so it crosses nothing and is never counted.
  Joining or detaching a handle twice, or one that is not a thread, throws `Error`:
  `mc-php: thread N is not joinable`.
- **The callable** is a compiled closure or an invokable object. A string callable is refused
  (D6), and so is the first-class callable syntax `f(...)`, which the compiler does not support
  yet: write `fn($x) => f($x)`. At most **five** arguments are passed; they go by value.
- **An exception** that `$fn` does not catch ends the thread. `join` throws a copy of it on the
  joining thread.
- **A thread neither joined nor detached** when the program ends (exe) or the request ends
  (extension) is waited for. The first such thread that ended on an exception is reported: on the
  program road as php reports an uncaught exception (`set_exception_handler` runs, else the fatal
  error), on the extension road as a warning, `mc-php: a thread neither joined nor detached ended
  on an uncaught DomainException: <message>`. This is gentler than `std::terminate`.
- **A detached thread**, as `std::thread::detach`:
  - On the program road, the program's end does NOT wait for it: the process's exit ends it. Its
    memory is not released before the exit, so it may still run while the program's final
    destructors do. A detached thread that touches module state or output at that point is
    undefined behaviour, as in C++. `tests/c/14-thread-detach-exit` detaches a thread that never
    returns, and the program exits at once.
  - On the extension road, RSHUTDOWN waits for it: the request's memory is released while the
    process lives on, so the thread cannot outlive it. A detached thread that never ends
    therefore blocks RSHUTDOWN, and with it the php worker that runs the request.
  - Its exception is not reported: nobody asked for it.
- **Where it can be called.** On the extension road the five builtins are compiled INTO the
  module and are not published: two mc-php modules loaded together would both declare them. A
  module offers threads to its scripts through its own published functions, for example
  `function run_all(callable ...$jobs): array`.

Two more builtins are test hooks, not API: `mcphp_shared_mode()` answers the calling thread's
shared-mode flag, and `mcphp_str_mine($s)` answers whether the runtime would write `$s` in place.

### The memory model: what 3a found, and what replaced frozen publication

The approved design copied every value stored into module state into a shared heap and froze it,
so that a worker's arena could be unmapped at its join. Building it showed two problems:

- **A store is not one place.** A global is written by `$g = v`, `$g[] = v`, `$g['k'] = v`,
  `$g->p = v`, a reference, `extract()`, `foreach` by reference, a static property, and every
  builtin that takes a reference. Each would need its own publish-and-copy, and each missed one
  is a dangling pointer after a join, not an Error.
- **O(n) per write.** A frozen array is copy-on-write, so `$g[] = $x` in a loop copies the whole
  array each time while threads run: quadratic, and step 4's locks do not remove it.

So frozen publication was **withdrawn**, with the owner's approval, and replaced by this model:

1. **A worker's memory is kept.** A thread's arena is not released at its join. Its chunks go on
   the root's list (`ph_tret`: the block of the program, or of the request that started the
   thread) and are released when the request ends (extension, after every thread of it was waited
   for), or never on the program road, where the process's exit releases them. So a value a
   worker stored into a global stays valid after the worker is gone, whichever way it was stored.
2. **Shared mode is sticky.** The first `mcphp_thread_start` sets `ph_shared` in the starting
   block, and every thread's block copies it. From then until the request ends, no string is
   freed and none is written in place. Counts are not atomic and may race, and a string's count
   is the only count that can: objects are never counted (D7) and arrays are copied by value.
   On the extension road a counted Zend string whose count reaches zero goes onto a deferred list
   (`php_str_defer`, under the runtime's lock) and is freed at RSHUTDOWN, once, after every
   thread of the request was waited for. The flag stays set after the last join: a value a
   finished thread stored may still be shared by what reads it.
3. **Shared writes happen in place, as in C.** A global, a static and `define()` are one copy that
   every thread reads and writes. A write stores a pointer; nothing is copied.
4. **Arguments, results and exceptions are deep-copied.** `php_tc_*`: arrays and compiled objects
   are copied, with one identity map per copy (a value two slots share stays one value, and a
   cycle ends). A counted array key is copied, because the other thread's count is not ours. A
   string value is not copied: the arena that holds it is kept, and shared mode stops it being
   freed or written in place. An engine object (a proxy) is not copied; a worker that uses it
   gets the engine guard's Error.

Module state, per kind:

| state | step 3 |
|---|---|
| a `global` | one variable for the program (exe) or the request (extension), seen by every thread |
| a `static` | the same |
| `define()` | allowed from any thread; the constants table is shared |
| `class_alias()` | still refused on another thread: the class table is the program's code, and C has no runtime equivalent |
| `register_shutdown_function()` | still refused on another thread: only the starting thread's list runs |

**Unsafe without a lock** (the locks are step 4; until then this is the developer's
responsibility, as in C). Each of these is undefined behaviour, not merely nondeterminism:
- **A torn value.** A php value is 16 bytes: an 8-byte payload and an 8-byte type. A store is two
  64-bit stores, so a reader racing a writer can see the new type with the old payload, or the
  reverse -- for example an array type over an integer's bits, which crashes when it is read.
  Step 4's locks are the fix. Until then, a variable one thread writes while another reads it is
  a bug in the program.
- Two threads writing the same variable. The last store wins, with no ordering.
- Read-modify-write, such as `$count++`, `$g['a'] += 1` or `$list[] = $x`: updates get lost, and
  an array that one thread grows while another reads it may be read mid-resize.
- `define()` of the same name from two threads at once.

What else to know:
- Output a worker writes goes to fd 1 directly, as in step 1. On the extension road this
  bypasses php's output layer, which is part of php's engine.
- **Destructors, as ext/parallel's copies.** Every copy is a distinct object, and each object is
  destructed once, by the thread that owns it. A worker destructs the objects it created -- its
  copies of the arguments included -- when it ends. The joiner owns its copy of the result and
  destructs it at its own end. One source copied twice (into an argument, then back into a
  result) is two objects, each destructed once. An object a worker stored into module state is
  destructed at that worker's end too, while module state still points at it. (On the extension
  road a request's own objects run no destructor at its end: docs/php-extension.md.)
  `tests/c/13-thread-destruct` and `tests/ext/threads/api.php` count the lines.

### The memory retention ceiling

Kept memory is everything a program's (or a request's) threads ever allocated. It is bounded by
use, not by thread count: the first chunk of a thread's arena is 64 KiB, and it grows only when
the thread needs more. Measured on macOS arm64 with `N` short threads started and joined one
after another, each building a 1000-byte string and two small arrays:

| threads | virtual size grew | maximum resident set |
|---|---|---|
| 100 | 6 MiB | 3.6 MB |
| 1 000 | 62 MiB | 19.6 MB |
| 10 000 | 625 MiB | 180 MB |

That is about 18 KB of resident memory and 64 KiB of reserved address space per thread, against
the 256 MiB per thread a step-1 arena would have kept. A program that starts threads in a loop
for its whole life, or a long request that does, grows by that much per thread.
`ponytail:` the retention is the simplest thing that keeps a stored value valid. The upgrade,
when a long-lived program needs it: release a joined thread's chunks when nothing it built was
stored into shared state (a store barrier on module state), or give each thread free lists.

### Each road

**Program road (exe).** Everything is compiled, so every thread is a native OS thread with no
Zend: step 1's machinery behind the public API. Windows uses `CreateThread`, `TlsGetValue` and an
`SRWLOCK`; POSIX uses pthreads and a mutex. `mcphp_hardware_concurrency` is
`sysconf(_SC_NPROCESSORS_ONLN)` on Linux and macOS, and `GetActiveProcessorCount`
on Windows.

**Extension road, compiled callables (NTS and ZTS).** A closure or function that mc-php compiled
runs natively on the worker, as on the program road. It gets its own arena and never touches
Zend's allocator. The module state it shares is the starting REQUEST's: in ZTS, a thread started
by a request shares that request's globals, statics, constants and class static properties
(its block points at the request's module words), not a new copy of MINIT's. Two FrankenPHP
requests still share nothing, as in step 2.

**Extension road, php callables, NTS: refused.** A php without thread safety has one executor for
the process, so a php closure or function cannot run on another thread. A child process was
rejected: Windows has no fork, a child's writes to module state would be its own copy, and
forking a php worker mid-request duplicates a threaded SAPI's sockets and locks. So
`mcphp_thread_start` with a php callable on an NTS module throws `Error`:
`mc-php: a php callable cannot run on another thread in a php without thread safety; build the
module with thread_safety = "zts", or pass a compiled function`.

**Extension road, php callables, ZTS: refused until 3b**, with `mc-php: a php callable cannot run
on another thread yet: its own php context on the worker is threads step 3b; pass a compiled
function`.

### What changed for code that does not use threads

Shared mode costs one load and a branch on the paths that free a string or write one in place;
nothing else runs until the first `mcphp_thread_start`. The step-1 refusals, the new words in the
block and those branches live in the runtime, so every output's bytes change, NTS modules
included; the NTS inertness `cmp` does not apply to this step.

### The gates (3a)

- `tests/c/11-thread-api.php`: the API on the program road -- a result, a closure's capture,
  arguments copied, a rethrow, `not joinable` twice, what a joined thread stored into three
  globals (a string, an array and an object) read after its join, the same for a detached thread
  polled until `mcphp_thread_running()` is 0, nested threads, and shared mode still set after the
  last join.
- `tests/c/13-thread-destruct.php` and `14-thread-detach-exit.php`: the destructor rule, and a
  detached thread that never returns while the program exits at once (a program that waited
  would be killed by `tests/lim.sh`'s bound). A build that releases a joined thread's arena at the join (step 1's model, with the
  result copied first) crashes on it with SIGSEGV; so does the extension road's
  `tests/ext/threads/api.php` (`tests/ext.sh` § 20b).
- `tests/c/12-thread-unjoined.php`: unjoined threads waited for, and the exception reported
  through `set_exception_handler`.
- `tests/ext/threads`: the API from a module, recorded, with the refusal message per NTS/ZTS, the
  destructor lines, and a detached thread's last line, printed before php ends because RSHUTDOWN
  waited for it.
- `tests/frankenphp.sh`: a request of the ZTS gate starts an API thread that writes the request's
  global and static; the formula checks both.
- `tests/leaks.sh`: the API on the extension road, 0 Zend blocks leaked.
- `examples/threads`: a prime count split over threads, with a C twin (pthreads and Win32) for
  reference and speed.

### 3b: php callables on a ZTS worker (not built)

- The worker thread becomes a php thread. `ts_resource_ex(0, NULL)` gives it its TSRM storage.
  `php_request_startup()` gives it a request, with its own EG, CG, PG, SG and Zend allocator.
  `php_request_shutdown()` and `ts_free_thread()` end both when the callable returns.
  All four are exported by php 8.5 ZTS (measured, `nm -D` of `php:8.5-zts-alpine`).
- The step-1 engine guards (`phx_offthread`) are lifted in that context: it IS a php thread, so
  the engine is its own.
- **INI:** the starting request's current values, re-applied with `zend_alter_ini_entry`.
- **Includes:** none are run again.
- **Functions and classes:** the callable and everything it names must be reachable. A probe
  decides between two options before 3b is built, and its result is reported first:
  - (a) Share the starting request's user functions and classes. php 8 keeps each op_array's
    run-time cache behind `ZEND_MAP_PTR`, per thread, which is how opcache shares op_arrays
    between threads. The starting request outlives the worker, because RSHUTDOWN waits.
  - (b) Copy the callable alone, as ext/parallel does. A callable that names a function or class
    of the script then fails in the worker with php's own "undefined" Error.

  (a) keeps php's meaning and is preferred; (b) is the fallback if op_arrays cannot be shared
  safely.
- **Arguments and results:** copied across the two contexts, engine values with `zval_copy`
  semantics and the same deep-copy rule.
- Gates: a FrankenPHP gate with php closures on threads (Linux), and the Windows ZTS legs.

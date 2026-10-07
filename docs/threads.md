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
(that root's list of kept arenas). The block is 12344 bytes, 12472 in a ZTS build (step 3b adds
`phz_job`, the job a php thread's call runs).

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

Step 3 is two pull requests, both built. **3a**: the API, the program road, compiled callables on
the extension road (NTS and ZTS), and shared module state. **3b**: php callables on a ZTS worker,
each in a php request of its own (§ 3b below). The owner's model is `std::thread`: real OS threads,
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
  On the extension road a module may also be handed a PHP callable (a php closure, a function's
  name, an array callable, an invokable object). A ZTS php runs it as § 3b says, and an NTS php
  refuses it.
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
- **`mcphp_thread_*` are mc-php intrinsics: they exist only in compiled code.** Interpreted php
  never sees them. It calls a wrapper that the module publishes, such as the one
  `tests/ext/threads/threads.php` publishes:

  ```php
  namespace th;
  function prun1(callable $f, mixed $a): mixed { return mcphp_thread_join(mcphp_thread_start($f, $a)); }
  function pstart1(callable $f, mixed $a): int { return mcphp_thread_start($f, $a); }
  function pjoin(int $t): mixed { return mcphp_thread_join($t); }
  ```

  A script then writes `th\prun1(fn($x) => $x * 2, 21)`.

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

**Unsafe without a lock** (step 4's mutex makes each of these safe, § Step 4; without one this
is the developer's responsibility, as in C). Each of these is undefined behaviour, not merely nondeterminism:
- **A torn value.** A php value is 16 bytes: an 8-byte payload and an 8-byte type. A store is two
  64-bit stores, so a reader racing a writer can see the new type with the old payload, or the
  reverse -- for example an array type over an integer's bits, which crashes when it is read.
  Step 4's mutex is the fix. Without it, a variable one thread writes while another reads it is
  a bug in the program.
- Two threads writing the same variable. The last store wins, with no ordering.
- Read-modify-write, such as `$count++`, `$g['a'] += 1` or `$list[] = $x`: updates get lost, and
  an array that one thread grows while another reads it may be read mid-resize.
- `define()` of the same name from two threads at once.

What else to know:
- Output a compiled worker writes goes to fd 1 directly, as in step 1. On the extension road this
  bypasses php's output layer, which is part of php's engine. A php callable's worker (§ 3b)
  has an output buffer of its own, written at its join.
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
Zend: step 1's machinery behind the public API. Windows uses `CreateThread` and `TlsGetValue`;
POSIX uses pthreads and a thread key. The runtime's lock is step 4's word on both (§ Step 4).
`mcphp_hardware_concurrency` is
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

**Extension road, php callables, ZTS: a php request of their own** (§ 3b). Without opcache the
start is refused with `mc-php: a php callable runs on another thread only when opcache caches the
code it can reach: ...`. The message names the first function, class or closure that opcache
does not cache.

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

### 3b: php callables on a thread of their own (ZTS)

The php callable reaches `mcphp_thread_start` through a function the module publishes, because
the builtins exist only in compiled code (§ The API shows the wrapper).

In a ZTS module, `mcphp_thread_start` also takes a **php** callable: a php closure, a function's
name, an array callable, an invokable object. The worker is a new OS thread that becomes a php
thread. `ts_resource_ex` gives it TSRM storage, and `php_request_startup` gives it a **php
request of its own**, with its own EG, CG, PG, SG, Zend heap and output layer. The call runs in
that request. `php_request_shutdown` and `ts_free_thread` end both when it returns. The code of
the starting request is shared with it; everything else crosses as a copy. `lib/php_zts.mc` § 3b
is the implementation; `probes/t3b` (branch `threads-3b-probe`) chose it over a copy of the
callable alone, which can crash the engine (an `INIT_FCALL` to a function the worker does not
have).

An NTS php still refuses a php callable (§ Each road): it has one executor for the process.

#### The two kinds of worker

They look the same from php and they are not. The difference is on purpose, and
`tests/ext/threads/php.php` shows it: the same module global is written by one worker of each
kind and read after the join.

| | a compiled callable (3a, NTS and ZTS) | a php callable (3b, ZTS only) |
|---|---|---|
| what runs | the module's native code, no php engine | a php request of its own, on the worker's php thread |
| module state (the module's globals, statics, constants) | the starting request's, one copy every thread reads and writes; races are the developer's | a **fresh copy of what MINIT left**, made by the worker request's own RINIT. What the worker writes, the starting request never sees, and the worker sees nothing the request wrote |
| php globals and statics | none: there is no php engine on the thread | the worker request's own: its own `$GLOBALS` and superglobals, and a function's `static` starts from its initial value |
| code | the module's compiled functions | the starting request's user functions and classes **as they were at the start**, shared by pointer (opcache required) |
| arguments and results | deep-copied between the two arenas (§ The memory model) | copied through memory neither Zend heap owns: plain values only (below) |
| an uncaught exception | a copy rethrown at the join | its class, message and code, rethrown at the join; a fatal error becomes an `Error` |
| output | written to fd 1 directly, in no order | a buffer of its own, written into the request's output at the join, in join order; for a thread nobody joins, when the request ends |

In `php.php`, a compiled worker's `gset("compiled")` is read back as `compiled` after the join. A
php worker then reads the same global as `unset` and writes `php`. After that join the request
still reads `compiled`.

#### Opcache is required

The code is shared by pointer, and that is safe only for opcache's immutable op_arrays. They keep
their run-time cache and their statics in a per-thread `ZEND_MAP_PTR` slot. The worker extends
its slot table to the starting thread's (`zend_map_ptr_extend`), and the closure gets a
run-time cache of its own (`ZEND_ACC_HEAP_RT_CACHE`). Without opcache, a function's run-time
cache is one pointer into the memory of whichever thread called it first. `probes/t3b` crashed
18 to 20 runs in 20 on that, and FrankenPHP died.

So the start checks the code before anything else. The closure must come from opcache, and so
must every user function and class in the request's tables. If one does not, the start throws
`Error`, naming it:
`mc-php: a php callable runs on another thread only when opcache caches the code it can reach:
enable opcache (opcache.enable=1, and opcache.enable_cli=1 on the command line); not cached:
function f`. The name is a function, a class, or `the callable {closure:FILE:LINE}`.
With opcache off, this is the first thing the first start says. A function from `eval()` is
refused with opcache on too, because opcache does not cache it. There is no fallback to a copy
of the callable.

**On Windows, a class that extends one of php's own classes is not cached immutable.** A
Windows opcache links such a class at run time, in the request's memory, because php's own
classes are not at the same address in every process. Once a request declares one (an
exception class included), every later start is refused, naming it: `not cached: class Ao`.
Linux and macOS cache such a class and are not affected. `php.php` declares one after its last
start, and the gate expects each platform's answer.

#### The code the worker sees: the tables at the start

The starting request's user functions and classes are listed when the thread starts, and added
to the worker's tables. A function or class the request declares **after** the start is not in
the worker. Calling it there is php's own `Error`, `Call to undefined function
declared_late()`, rethrown at the join. `php.php` declares one right after a start.

The worker's tables keep those entries until its request ends. Shutdown leaves an immutable
function and class alone: `destroy_op_array` returns on a NULL refcount, and
`destroy_zend_class` returns on `ZEND_ACC_IMMUTABLE`. Shutdown then frees the worker's own
per-thread statics of them. Taking the entries out before shutdown would leak those statics: a
debug ZTS php reports three blocks for one `static $n` and one static property.

What is not shared:
- **User constants** (`define()`, a top-level `const`): the worker does not have them. A class
  constant is part of its class, and the class is shared.
- **INI**: the worker's values are php's startup values (`php.ini`, `-d`). The request's
  `ini_set()` changes are not re-applied.
- **Autoloaders**: the worker request registers none.

#### What crosses: copied, or refused by name

Arguments, the closure's captured variables (`use`, by value, a reference included) and its
bound `$this`, and the result are copied. The copy is serialized out of one Zend heap into pages
neither heap owns, and rebuilt in the other. The result is copied out of the worker's heap
before its request ends. What can be copied:
- `null`, `bool`, `int`, `float`, `string`;
- an array, with integer and string keys, nested;
- an object of the script's own classes, or a `stdClass`: its class by name, and every property
  (declared, dynamic, private and protected). One object two places share is one object in the
  copy, and a cycle ends.

What cannot be copied is refused with an `Error` naming it, as ext/parallel refuses it:
`mc-php: cannot copy into or out of a php thread: ...`. That is:
- an object of php's own classes (a `Closure`, a `DateTime`, an `ArrayObject`, an exception,
  a generator), which keep state outside their properties;
- an object of a class that extends one of them;
- an enum case, which is one object per request;
- a value nested more than 256 levels deep (a recursive array through a reference).

A resource never reaches `mcphp_thread_start`: the module's own boundary refuses it
(`mc-php: a php resource cannot cross into the module`).

The refusal comes from the start for an argument, a capture or `$this`. It comes from the join,
as that `Error`, for a result.

#### Exceptions, fatal errors, `exit()`

- **An uncaught throwable** ends the call. Its class, message and code are rethrown at the join,
  as an object of the same class made there. Its trace and `previous` do not cross.
- **A fatal error** (a memory limit, for example) ends the worker's call, not the process, and
  php prints it into the worker's output. The join then throws `Error`:
  `mc-php: a php thread ended on a fatal error: <php's message>`. **Not on Windows:** there,
  php's bailout is a `longjmp` that unwinds with SEH, and the module's frames between the
  bailout point and the callable carry no unwind data (mc emits no `.pdata`), so a fatal error
  in a worker ends the process. The same probably holds for a fatal error in any php code the
  module calls on Windows (not measured).
- **`exit()`** ends the call with a `null` result.

**The SAPI on Windows.** php-cli (`php.exe`) and a web server's php module are modules apart
from `php8ts.dll`, each with its own copy of php's per-thread cache. Only threads the SAPI started
ever set that copy. `php_request_shutdown` calls the SAPI's deactivate on every thread, and on a
worker's thread php-cli's reads the unset cache and faults (measured under `cdb` on both Windows
legs). A worker's request never belonged to the SAPI. So on a Windows php the module wraps
`sapi_module.deactivate` once, before the first worker, and skips the SAPI's deactivate on a
worker's thread. Linux and macOS link the SAPI into the same image as the engine, and there the
wrapper is not installed.

The call runs as the worker request's one **shutdown function**, because
`php_call_shutdown_functions` is php's own call site with a bailout point (`zend_try`). An
extension can reach it without `setjmp`, which this runtime does not have (docs/plan.md D7).
What php calls there is a trampoline: an internal function whose handler is the runtime's. So
the callable runs under an internal frame, and an uncaught exception stays in `EG(exception)`
for the trampoline to copy.

#### Output

The worker starts an output buffer of its own before the call. After the call it takes what
the buffer holds. A buffer the callable opened and left open is ended into it first. At the
join, the runtime writes those bytes into the request's output, through the module's own write,
so they keep their place among the joiner's lines. Eight workers that echo at once are
therefore eight blocks in join order, never interleaved (`php.php` joins them in reverse). A
thread nobody joins, detached or forgotten, is waited for when the request ends, and its output
is written then. Its uncaught throwable is reported as a compiled thread's is.

#### The cost, and what is not built

A start costs about 400 us, measured by `probes/t3b` with an empty closure. Most of it is TSRM:
`ts_resource_ex` is about 265 us (every module's globals, copied for a new thread) and
`ts_free_thread` about 57 us. The request itself is about 15 us. **A pool of worker contexts**,
php threads kept between starts, would save the two TSRM costs and is not built. Until then, a
php callable on a thread is worth it for work that takes much longer than a millisecond.

#### The gates (3b)

- `tests/ext.sh` § 20c, ZTS only: `tests/ext/threads/php.php` with opcache on, against its
  recording. It covers:
  - the request's code, a capture, `$this` copied and refused;
  - a string, an array and objects (shared, a cycle) as results;
  - an argument and a result refused;
  - a rethrow, and a function declared after the start;
  - statics per request, and the module global written by a worker of each kind;
  - a fatal error and `exit()` in a worker;
  - eight workers that echo, joined in reverse, and a detached one.

  The same script with opcache off must answer the refusal. § 20b's php-callable line is that
  refusal on a ZTS php.
- `tests/leaks.sh` with `ZTS=1`: the thread modules in a thread-safe debug php, `php.php` and ten
  more rounds of string, array and object results with opcache on, 0 blocks left.
- `tests/frankenphp.sh`: `threads.php` starts two php workers per request from eight php
  threads, and every answer must follow the formula. Memory stays bounded. With
  `opcache.enable=0` the same page answers the refusal.
- The Windows ZTS legs (arm64 and x64) run `tests/ext.sh`, so § 20c runs there too, with
  opcache loaded as a `zend_extension` where the php does not load it by itself.

## Step 4: native sync

Step 3 left every race to the developer. Step 4 gives the developer the tools: a mutex and
atomics, built on the atomic instructions and the operating system's sleep on a word -- `futex`
on Linux, `__ulock_wait` on macOS, `WaitOnAddress` on Windows. No pthread mutex and no
`SRWLOCK` is left anywhere in the runtime: the runtime's own lock moved onto the same word
(4a). A semaphore, a wait group and a condition variable, each with a timeout, are 4b.

### The API (4a)

Ten builtins, compiled by mc-php on both roads:

```php
$m = mcphp_mutex(): int;                         // a handle
mcphp_mutex_lock(int $m): void;                  // sleeps until it is free
$ok = mcphp_mutex_trylock(int $m): bool;         // false when it is held, by anyone
mcphp_mutex_unlock(int $m): void;

$a = mcphp_atomic(int $v = 0): int;              // a handle to one 64-bit value
$v = mcphp_atomic_load(int $a): int;
mcphp_atomic_store(int $a, int $v): void;
$old = mcphp_atomic_add(int $a, int $d): int;    // the value before; wraps as C's does
$ok = mcphp_atomic_cas(int $a, int $e, int $n): bool;   // stores $n when the value is $e
$old = mcphp_atomic_xchg(int $a, int $v): int;   // the value before
```

- **An int handle, for both.** Like a thread's, it is a value: it crosses nothing, is never
  counted, and is copied into a thread's arguments as an int. An atomic is a handle and not a
  variable because a php variable is 16 bytes and two stores; the handle names 8 bytes the
  runtime owns.
- **Named refusals, as `Error`:** a handle that is not a live object (`mc-php: handle N is not a
  live mutex`), one of the other kind (`mc-php: handle N is an atomic, not a mutex`), a lock of a
  mutex the calling thread already holds (`mc-php: mutex N is already held by this thread` -- it
  would sleep for ever), an unlock by a thread that does not hold it (`mc-php: mutex N is held by
  another thread`) or of a mutex nobody holds (`mc-php: mutex N is not locked`).
- **Not recursive.** A thread that locks what it holds is refused, not counted. A recursive mutex
  is out of scope; code that needs one keeps its own count beside the handle.
- **Lifetime.** On the program road an object lives as long as the process. On the extension road
  one made at MINIT lives as long as the process, and one a request makes is freed at the
  request's end, after every thread of the request was waited for. A 3b worker is a request of
  its own, so what it makes is freed when it ends. A freed handle is refused by name, never
  reused silently: a handle is `(generation << 22) | index` into a table of slots, and a freed
  slot's generation moves on.
- **A thread that ends holding a mutex leaves it locked**, as a pthread mutex does.
- **Intrinsics, like `mcphp_thread_*`**: they exist only in compiled code. Interpreted php calls
  a wrapper the module publishes, as `tests/ext/threads/threads.php` does:

  ```php
  namespace th;
  function sy_mutex(): int { return mcphp_mutex(); }
  function sy_lock(int $m): void { mcphp_mutex_lock($m); }
  function sy_unlock(int $m): void { mcphp_mutex_unlock($m); }
  function sy_add(int $a, int $d): int { return mcphp_atomic_add($a, $d); }
  ```

### The memory model: what a lock makes safe

Step 3's list of what is unsafe without a lock is exactly what a lock fixes. **Take the same mutex
around every read and every write of a piece of shared module state -- a global, a static, an
array in one -- and that state is data-race-free:**

- `mcphp_mutex_lock` is an acquire and `mcphp_mutex_unlock` a release, so everything one holder
  wrote before its unlock is visible to the next holder after its lock: no torn 16-byte value,
  no lost update, no array read mid-resize.
- mc keeps only locals in registers, never a global, a static or an array element, so every read
  after the lock is a real load of memory the lock ordered.
- 3a's rules keep what was read under the lock valid after the unlock: a thread's arena is kept
  until the request (or the program) ends, and shared mode frees no string and writes none in
  place, so a value read under the lock does not dangle once another thread overwrites the slot
  it came from.
- The atomics are sequentially consistent: every thread sees their operations in one order.

What stays the developer's, as in C: state touched without the lock, two mutexes taken in two
orders (a deadlock), and a value read under the lock and written back after the unlock.
`tests/c/15-sync.php` is the proof in numbers: eight threads each add 1 twenty thousand times to
a global under a mutex, and the count is exact; without the two lines of locking it lost 18201
of 160000 in a measured run.

### How it is built

- **The atomic words** (`lib/rt_atomic_arm64.mc`, `rt_atomic_x86_64.mc`, `rt_atomic_win64.mc`):
  five functions -- load, store, add, compare-and-swap, exchange -- whose bodies are raw
  instructions (`#opcode`), one file per instruction set and calling convention, chosen by the
  TARGET's architecture (a Windows-on-ARM mc-php builds the x64 extension php loads there).
  AArch64 uses `ldar`/`stlr` and `ldaxr`/`stlxr` loops, each loop inside one function, so nothing
  needs the ARMv8.1 LSE instructions. x86-64 uses `mov`, `xchg`, `lock xadd` and
  `lock cmpxchg`, in the System V registers and in the Windows x64 ones. `tests/sweep_sync.py`
  re-assembles every word with llvm-mc and checks that mc emits exactly those words.
- **The mutex** is Drepper's (Futexes Are Tricky, mutex 3): a word that is 0 free, 1 locked and 2
  locked and maybe waited on. An uncontended lock is one compare-and-swap and an uncontended
  unlock one exchange; a sleeper sleeps while the word is 2, and an unlock that finds 2 wakes one.
  The word needs no initialisation, so the runtime's own lock (`ph_lock`: the thread table, the
  deferred frees, a ZTS module's tables) is the same code over a global word, and works before
  anything else exists.
- **The sleep on a word** is the host layer's `ph_os_wait`/`ph_os_wake`:
  - Linux: `futex(2)`, `FUTEX_WAIT_PRIVATE`/`FUTEX_WAKE_PRIVATE`, through libc's `syscall`.
  - macOS: `__ulock_wait`/`__ulock_wake`, libSystem's private interface -- the one libc++'s
    `std::atomic::wait` is built on. `os_sync_wait_on_address` (public since macOS 14.4) is the
    upgrade once the floor is 14.4, noted as a `ponytail:` in `lib/rt_host_macos.mc`.
  - Windows: `WaitOnAddress`/`WakeByAddressSingle`/`WakeByAddressAll`, imported from the
    synchronization API set, `api-ms-win-core-synch-l1-2-0.dll`. On the object road
    `tests/winsys.sh` puts those three names into `kernel32.lib`, bound to that DLL
    (`src/win/synch.def`), so no link line changed.
- **The table** is 32-byte slots -- a header (generation and kind), the word, the mutex's holder
  (the thread's runtime block) and the request that made it -- in chunks of 1024 behind a fixed
  directory of 4096 chunks: at most 4194303 live objects (a `ponytail:` in `lib/php_rt.mc`). Slots
  never move, so an operation on a handle takes no lock; making one takes the runtime's lock, and
  a freed slot goes on a free list. The end of a request scans the table only when a request owns
  a live object.

### The gates (4a)

- `tests/c/15-sync.php`: the four exact counts under contention (a mutex, an add, a
  compare-and-swap loop, an exchange spin lock), the values the operations answer, trylock, a
  waiter that sees what was written before the unlock, and every refusal by name.
- `tests/c/16-thread-churn.php`: the runtime's lock under contention -- eight starter threads each
  start and join 1250 short threads at once, ten thousand in all, and every one is counted.
- `tests/ext.sh` § 20b: a mutex and an atomic from four compiled threads on the extension road,
  an atomic made at MINIT, and three refusals. § 20c (ZTS): a mutex and an atomic shared by four
  php workers and the request, through the module's wrappers.
- `tests/sweep_sync.py`: the llvm-mc sweep over the atomic words.

### The API (4b)

Eleven more builtins, over the same table and the same host sleep on a word, with a relative
timeout in milliseconds on the three that block (`-1` waits for ever):

```php
$s = mcphp_semaphore(int $permits = 0): int;
$ok = mcphp_semaphore_acquire(int $s, int $timeout_ms = -1): bool;   // false on timeout
mcphp_semaphore_release(int $s): void;

$w = mcphp_waitgroup(): int;
mcphp_waitgroup_add(int $w, int $n): void;
mcphp_waitgroup_done(int $w): void;                                  // add(-1)
$ok = mcphp_waitgroup_wait(int $w, int $timeout_ms = -1): bool;      // false on timeout

$c = mcphp_cond(): int;
$ok = mcphp_cond_wait(int $c, int $m, int $timeout_ms = -1): bool;   // hold $m; false on timeout
mcphp_cond_signal(int $c): void;
mcphp_cond_broadcast(int $c): void;
```

- **The semaphore** is a counting semaphore: `acquire` waits while the permits are 0 and takes
  one, `release` adds one and wakes a waiter. `acquire($s, 0)` never sleeps, so it is a try.
- **The wait group** is Go's: `add` changes the counter, `done` is `add(-1)`, `wait` blocks
  until it is 0. A decrement below 0 is refused by name (`mc-php: waitgroup N counter went
  negative`), the counter put back first -- but that put-back is ordered before the refusal,
  not before visibility, so a concurrent `wait` polling the counter can briefly see the negative
  value and return early, stranding a still-pending, legitimate `add`. This is a consequence of
  the refused misuse (a program that never over-decrements never observes it), not a separate
  bug.
- **The condition variable** is called holding a mutex: `wait` releases it, sleeps until a
  signal, and reacquires it before returning. `wait` of a mutex the calling thread does not hold
  is refused by name. The caller loops on its own predicate, as with `pthread_cond_wait`, so a
  spurious wake and a `broadcast` that wakes several waiters are both handled by the loop.
- **The timeouts** answer `false` when the deadline is reached. The deadline is computed once
  from a monotonic clock (`clock_gettime(CLOCK_MONOTONIC)` on Linux, `clock_gettime_nsec_np` on
  macOS, `GetTickCount64` on Windows) and the remainder is recomputed after every wake, so a
  spurious wake never shortens or lengthens the wait. The wakeup primitive's own relative
  timeout is used each time (`FUTEX_WAIT`, `__ulock_wait`, `WaitOnAddress`).

The five kinds share one 32-byte slot layout: the primary word is the mutex's state, the
atomic's value, the semaphore's count, the wait group's counter or the condition's sequence
number; a wrong handle names its actual kind against the wanted one.

### The gates (4b)

- `tests/c/17-sync-blocking.php`: a wait group barrier, a semaphore handoff and its bound, a
  bounded producer/consumer queue over two condition variables, a broadcast to eight waiters,
  and the three timeouts (each returns false; the semaphore and condition waits take at least
  the timeout, measured with `mcphp_now_ms`, an internal clock gate).
- `tests/ext.sh` § 20b: a wait group and a broadcast across eight compiled threads. § 20c (ZTS):
  a wait group across three php workers, each a request of its own sharing the handle.
- `examples/sync`: the producer/consumer workload on the program road, with a C twin
  (`c/sync.c`, pthreads and C11) it must match byte for byte and a wall-clock ratio.
- `tests/run.sh`: a dump-machine check -- `--dump-asm --machine=x86_64` on an arm64 host must
  dump the x86-64 atomic words, not the arm64 ones (the atomics file follows the selected
  machine in a dump mode).

## Step 5: the event loop and `await` of real I/O (BUILT)

Steps 1-4 give threads and sync. Step 5 adds the other half of concurrency: one thread that
does many I/Os at once, by suspending the php call at an `await` point until the I/O is ready,
without blocking the OS thread. It is the base step 6b builds on (the awaitable example's
non-blocking `file://`/socket fetches). The step-6a `await` in `examples/awaitable` is a
placeholder -- it runs the callable to completion on the calling thread; step 5 makes `await`
really suspend.

### Built (as-built, and what the design under-scoped)

The design below was approved before implementation and is accurate, with the following
decisions the owner ruled during the build (and this is what shipped):

- **The surface is EIGHT intrinsics, not six.** The six listed in § 4 could not *create* a fiber,
  so `ph_ctx_swap` would have been dead code and the mandatory no-migration / stack-exhaustion
  self-tests unreachable. Added as full published intrinsics:
  - **`mcphp_spawn(callable $fn, mixed ...$args): int`** -- run `$fn` on a fresh fiber, returning
    an `SY_FUTURE` that completes with its return value (or fails with its thrown exception). The
    single-thread analog of `mcphp_thread_start`; the fiber entry point.
  - **`mcphp_io_read(int $fd, int $len): string`** -- submit a non-blocking read via
    `ph_io_submit`, suspend until the bytes are in (EOF -> empty string). The I/O trigger step 6b
    extends to `file://`/sockets; step 5's fd is the self-test's own pipe/socket.
- **Fibers are COOPERATIVE on one thread** (one runs at a time, yields at an await), so within a
  thread there is NO data race and NO deep copy of a value crossing an await -- args and results
  pass as ordinary in-arena values. Cross-thread future completion and its deep copy stay in
  step 6b. (This supersedes the "deep-copied (`php_tc_*`)" note in § 4.)
- Files: `lib/rt_fiber_{arm64,x86_64,win64}.mc` (`ph_ctx_swap` + `ph_ctx_bootstrap`, raw words,
  arch-selected in `src/program.mc` like the atomics, swept by `tests/sweep_sync.py`); the loop
  core, futures, timers, fibers and the eight runtime functions in `lib/php_rt.mc`
  (`SY_FUTURE` = 6); the per-OS reactor `ph_ev_create`/`ph_ev_arm`/`ph_ev_wait` and
  `ph_os_map_stack`/`ph_os_pipe` in `lib/rt_host_{macos,linux,windows}.mc`; the builtins in
  `src/builtin.mc` (`ph_bi_async`); one lazy loop per thread in `lib/php_tls.mc` (`PHT_ph_loop`).
- Fiber stacks are **128 KiB**, a guard page below (`PROT_NONE` / `PAGE_NOACCESS`), lazily
  committed; the ceiling is **1024** outstanding awaits per loop (`PH_FIB_MAX`), past which
  `mcphp_spawn` is the named refusal `mc-php: too many outstanding awaits`. Per-await reserved
  cost is the 128 KiB stack plus one guard page; committed (RSS) is only the pages a shallow
  awaiter touches -- measured at **~16.9 KiB per outstanding await** (one 16 KiB page on this
  Apple-Silicon host: 1024 live fibers moved max RSS from 1.67 MiB to 18.97 MiB). The upgrade for
  a server holding tens of thousands of connections is a pooled or segmented stack (a `ponytail:`
  note in the fiber record).
- The self-test is `tests/c/18-await.php` (a timer, a future completed/failed, fibers that await a
  timer, a pipe read awaited on a fiber), `tests/c/19-await-migrate.php` (the no-migration abort,
  condition 1) and `tests/c/20-await-exhaust.php` (the ceiling refusal, condition 2); the
  engine-live refusal (condition 3) is exercised on the extension road. `mcphp_pipe` /
  `mcphp_fd_write` / `mcphp_fd_close` / `mcphp_test_migrate` are test scaffolding, not the surface.

Measured facts about the tree it builds on carry a `file:line`.

### What exists to build on, and what does not

- **No suspension machinery of any kind.** `grep` for `kqueue|epoll|iocp|ucontext|swapcontext|
  setjmp|O_NONBLOCK|poll(|select(` over `src/`, `lib/` and `reference/` is empty. There is no
  fiber, no coroutine, no event loop, no non-blocking I/O. The runtime has no `setjmp`
  (docs/plan.md D7; stated at § 3b above). Step 5 writes all of it.
- **A php call is a native call.** mc-php compiles each php function to a native function; a call
  is a `bl`/`call`. There is no VM, no CPS, no state-machine transform. So the compiler stays
  untouched by this step (the suspension lives entirely in the runtime, below).
- **Raw per-arch `#opcode` word functions are the house mechanism for a primitive mc cannot
  express.** `lib/rt_atomic_arm64.mc` (and the x86-64 and win64 halves) are five functions whose
  bodies are assembled words, selected by the target architecture in `src/program.mc`, gated by
  an llvm-mc sweep (`tests/sweep_sync.py`). The context switch step 5 needs is written exactly
  this way.
- **Native threads, the host sleep, and the monotonic clock are done.** `ph_thr_create`
  (`lib/rt_host_linux.mc:168`, pthread/CreateThread), `ph_os_wait`/`ph_os_wake` (futex /
  `__ulock` / `WaitOnAddress`, `lib/rt_host_linux.mc:104`), `ph_os_wait_ms` relative timeout and
  `ph_os_now_ms` monotonic (`lib/rt_host_linux.mc:116`). Step 4b's timer rule -- a deadline from
  the monotonic clock, the remainder recomputed after every wake (§ Step 4) -- is reused verbatim.
- **The sync handle table is the model for every handle step 5 adds.** 32-byte slots, kinds
  `SY_FREE`..`SY_COND` (`lib/php_rt.mc:11468`), `(generation << ...) | index` handles that are
  never reused silently, named refusals, a request-scoped lifetime (§ Step 4). A future and a
  timer are new kinds in this table, not a new table.
- **I/O today is one blocking `read`.** `php_f_file_get_contents` (`lib/php_rt.mc:8636`) calls
  `php_read_whole`, a blocking `read(2)`. There is no socket layer. Step 5 adds the non-blocking
  path the loop drives; step 6b wires `file://`/sockets onto it.
- **Intrinsics are compiled-only, with published wrappers.** `mcphp_*` exist only in compiled
  code; interpreted php calls a module-published wrapper (§ The API, § 3b). Step 5's builtins
  follow this to the letter.

### 1. Suspension model: stackful fibers over a context-switch word (the crux)

**DECISION: a stackful coroutine ("fiber") -- its own stack, swapped by a per-arch `#opcode`
context-switch primitive -- is what `await` suspends.** Not a compiler transform, not threads.

Weighed:

| option | verdict |
|---|---|
| **stackful fiber + `ph_ctx_swap` word (chosen)** | no compiler change; `await` works at any call depth because the whole native stack is parked; no `setjmp`; reuses the arena, the handle table and the host map already built; the switch is 3 small files of raw words, gated like the atomics. Cost: one stack per outstanding await. |
| php Fibers (8.1), compiled | a php `Fiber` IS a stackful coroutine; building it is the same switch primitive plus a class. Step 5 does not need the php-visible class, only the primitive. Deferred: publish `Fiber` later as a thin wrapper over the same word, if a consumer asks. |
| stackless state-machine transform | rejected. A deep compiler change (CPS in `src/expr.mc`/`mach.mc`/`program.mc`); and "a function that can transitively reach `await`" is undecidable under php's dynamic dispatch (any `callable` might await), so it colours the whole call graph. Against the grain, large, fragile. |
| thread-per-await | rejected as the model. It is what step 6a's `http_get_many` does today (a worker blocked per fetch, `awaitable.src.php:144`); it does not scale to thousands of in-flight I/Os, which is the loop's whole reason to exist. It stays the baseline the loop must beat. |

**What has to be built (named):**
- `ph_ctx_swap(from, to)` -- save the callee-saved registers, SP and return address into `from`,
  load them from `to`. Three files, raw `#opcode` words: `lib/rt_fiber_arm64.mc`,
  `rt_fiber_x86_64.mc`, `rt_fiber_win64.mc` (the atomics' split and arch selection, exactly:
  AAPCS64 is one file for macOS/Linux/Windows-on-ARM; SysV and Windows x64 are two). Gated by
  `tests/sweep_sync.py` (extended) and the dump-machine check (§ Step 4 gates).
- a **fiber object**: a stack (`ph_os_map`, a guard page, lazily committed), the saved SP, the
  callable and its state. A fiber never migrates threads -- it is created, suspended and resumed
  only by its own thread's loop -- so the `phT` fast-path copy (`uptr phT = ph_tcur; ...`, § The
  mechanism) stays valid across a swap (same OS thread, the thread block does not move). This is
  the one invariant the whole model rests on; the self-test asserts it.
- a **fiber/future handle** in the sync table (`SY_FUTURE`, a new kind), with the step-4 lifetime
  and named refusals.

Ponytail: the stack-per-await is the simplest thing that suspends an arbitrary call chain. Its
ceiling (memory per outstanding await) is the one real cost vs a stackless transform; it is named
under § 6 and § risks. A `ponytail:` in the fiber file will record the default stack size and the
upgrade (a segmented or pooled stack) when a server holds tens of thousands of connections.

### 2. Reactor vs proactor: a completion-shaped surface, readiness backends emulate it

kqueue/epoll are readiness-based (tell me when the fd is readable; then I read). IOCP is
completion-based (I post the read; you tell me when the bytes are in my buffer). These do not
compose unless the common surface is chosen with care.

**DECISION: the loop's internal I/O surface is completion-shaped --
`ph_io_submit(fd, op, buf, len) -> resume with n`, not `await_readable(fd)`.** IOCP is then
native. A reactor EMULATES it: arm the readiness interest (`EV_ADD` / `EPOLL_CTL_ADD`), and when
the fd is ready the loop itself does the `read`/`write`/`accept` and resumes the fiber with the
result. Rationale: readiness -> completion emulation is a few lines and one extra syscall on
POSIX; completion -> readiness emulation is **impossible** on IOCP (it never reports mere
readiness). Choosing the completion shape puts the unavoidable asymmetry on the cheaper side.
This is the step's central design risk and this is its resolution.

Three host functions, one loop core (in `lib/php_rt.mc`) written against them:
- `ph_ev_create()` -- kqueue / epoll_create1 / CreateIoCompletionPort.
- `ph_ev_arm(ev, fd, op, ud)` -- register interest (POSIX) or post the overlapped op (Windows).
- `ph_ev_wait(ev, out, max, ms)` -- kevent / epoll_wait / GetQueuedCompletionStatus, with the
  timeout the timer list computes. It returns the ready/completed events, each carrying its
  user-data (`ud` = the fiber to resume).

The per-OS bodies live in `lib/rt_host_{macos,linux,windows}.mc` beside `ph_os_wait`. The loop
core never names a backend.

### 3. Loop ownership and threads: one loop per thread, lazy

**DECISION: one event loop per thread, created the first time that thread awaits, stored in the
thread block (`lib/php_tls.mc`).** Not a dedicated loop thread.

- A dedicated loop thread would marshal every I/O across threads and fight step 3's
  shared-nothing model. Per-thread keeps each loop's I/O on its own thread.
- **Lazy, so a program that never awaits pays nothing** -- no loop, no fiber stacks -- as the
  step-1 fast path and the inertness bar require.
- **A worker can await.** A compiled worker (§ 3a) gets its own loop on first await, like any
  thread. A php worker (§ 3b) runs in a php request; `await` there is subject to the engine rule
  below.
- **Interaction with step 4.** A fiber that calls `mcphp_mutex_lock`/`_semaphore_acquire`/
  `_cond_wait` blocks its whole OS thread, and therefore its loop. That is the developer's call
  and is documented: `await` is for I/O, the sync primitives are for thread coordination. Mixing
  them (await inside a held mutex) is legal and the developer's responsibility, as in C.
- **Cross-thread wakeup is deferred to 6b.** In step 5 a future is completed only by its own
  loop's I/O or timers, so the loop never needs waking from outside. Completing a future from
  another thread (e.g. a worker finished) needs the loop woken out of `ph_ev_wait` -- an
  eventfd/self-pipe registered in the loop (POSIX) or `PostQueuedCompletionStatus` (Windows).
  Step 5 builds the hook but 6b is where a cross-thread completion is first used and gated.

### 4. The await surface

The php-visible builtins, compiled-only intrinsics in the `mcphp_` family, each a slot of kind
`SY_FUTURE` in the step-4 table (generation+index handle, named refusals, request-scoped
lifetime):

```php
$f = mcphp_future(): int;                        // a handle, kind FUTURE, not yet done
mcphp_future_complete(int $f, mixed $v): void;   // mark done with a value
mcphp_future_fail(int $f, \Throwable $e): void;  // mark done with a throwable
$v = mcphp_await(int $f): mixed;                 // suspend until $f is done; rethrow on fail
$t = mcphp_timer(int $ms): int;                  // a future the loop completes after $ms
mcphp_loop_run(): void;                          // drive the loop until nothing is pending
```

- `mcphp_await($f)`: if the caller runs on a fiber, record "resume me when `$f` is done" and
  `ph_ctx_swap` back to the loop; the loop resumes the fiber (on completion or timer) and
  `await` returns the value, or rethrows `$f`'s throwable. **If there is no current fiber (a
  top-level await, as `examples/awaitable` calls it from the request thread), run a nested loop
  until `$f` is done** -- the drive-to-completion bridge every php userland loop uses. `$f`'s
  value crosses as a value in the slot, deep-copied (`php_tc_*`, § 3a) if it came from another
  thread.
- The future reuses the sync slot's words: the primary word is the done-state (0 pending, 1 done,
  2 failed), another holds the value or throwable, another the fiber to resume. A wrong handle
  names its kind against `future` (`mc-php: handle N is a mutex, not a future`), as step 4 does.
- The minimal set is deliberate. `mcphp_future_complete`/`_fail` are one line each and 6b needs
  them (an application completes a future when its thread finishes). A php-visible `Fiber` class
  is NOT published here -- skipped, add when a consumer asks (ponytail). The awaitable example's
  `Intent`-returning `await(callable, ...)` stays userland and 6b wires it onto `mcphp_await`.

### 5. Timers: step-4b monotonic deadlines in the loop

**DECISION: reuse § Step 4b's deadline rule verbatim.** A timer is an `SY_FUTURE` plus a deadline
`ph_os_now_ms() + ms` on the loop's sorted timer list. Each turn the loop computes the next
timeout as `min(deadlines) - now` and passes it to `ph_ev_wait`; on wake it completes every
expired timer's future (resuming its awaiting fibers) and recomputes the remainder for the rest
-- the "a spurious wake never shortens the wait" rule (§ Step 4b). No new clock. kqueue's
`EVFILT_TIMER` is not used: the sorted-list-plus-wait-timeout form is one implementation for all
three backends.

### 6. Both roads, five targets

- **Program road (exe):** fibers and loop fully native, no Zend. All five targets.
- **Extension road (NTS and ZTS):** a fiber runs compiled code with no engine, so a compiled
  worker can await file/socket I/O. **`await` is refused when php's engine is live on the current
  fiber's stack** -- suspending with an `EG` frame open would corrupt the executor on resume (the
  same reason § 3b runs a php callable in a request of its own). The refusal is by name:
  `mc-php: await cannot suspend while php's engine is on the stack`. Step 5's self-test touches
  no engine, so this does not bite it; 6b respects it.
- **Targets:** the context-switch word needs arm64 + x86-64-SysV + x86-64-Windows (3 files, the
  atomics' split). The reactor needs kqueue (macos/arm64), epoll (linux aarch64 + x86_64) and
  IOCP (windows x64 + arm64). Every one of the five CI legs has a backend, so each backend is
  exercised on its own leg.
- **What a target cannot do:** nothing fundamental. On Windows a fatal error inside a fiber has
  the same no-`.pdata` unwind limit as § 3b (`docs/threads.md` § 3b, "Not on Windows"): a php
  fatal error reached through a fiber may end the process. Step 5's compiled-only self-test does
  not raise one.

### 7. Scope: step 5 vs step 6b

**Step 5 (this milestone) -- buildable and testable on its own:**
- `ph_ctx_swap` (3 arch files) + the llvm-mc sweep and dump-machine gates.
- the loop core + the three host backend functions (kqueue/epoll/IOCP) + the timer list.
- `mcphp_future`, `_complete`, `_fail`, `mcphp_await`, `mcphp_timer`, `mcphp_loop_run`
  intrinsics, as an `SY_FUTURE` kind in the step-4 table.
- a self-contained test with a C twin: **await a timer** (the deadline is met, within a
  tolerance) and **await a pipe/socket read** (the loop resumes the fiber when the pipe has
  bytes). No http, no php engine. `tests/c/18-await.php` on the program road; `tests/ext.sh`
  exercises the compiled-worker await on the extension road.

**Step 6b (BUILT) -- wiring onto the loop:** the non-blocking socket surface, the userland
`await()` over the primitive, and cross-thread future completion. See **§ Step 6b (BUILT)** below.

### 8. Gates (for when it is built)

- **C twin for the loop.** `tests/c/18-await`'s twin is the same timer + pipe-read workload on
  raw kqueue/epoll/IOCP and a context switch (`ucontext` or the twin's own swap): byte-for-byte
  output and a wall-clock ratio, as `examples/sync` compares against `c/sync.c`.
- **llvm-mc sweep** over the `ph_ctx_swap` words (extend `tests/sweep_sync.py`), and the
  dump-machine check (`--dump-asm --machine=x86_64` on an arm64 host dumps the x86-64 switch, as
  for the atomics, `tests/run.sh`).
- **Each backend on its own leg.** kqueue on macos/arm64, epoll on linux aarch64 + x86_64, IOCP
  on windows x64 + arm64 -- `tests/c/18-await.php` runs on all five, so a backend that is wrong is
  red on its leg.
- **Leaks and ZTS.** `tests/leaks.sh` (0 Zend blocks, fiber stacks unmapped at the end),
  `tests/frankenphp.sh` for a compiled worker that awaits inside a ZTS request.
- **The inert / 2% bar.** A program that never awaits allocates no loop and no fiber: measure
  `examples/decimal` unchanged. The step adds runtime bytes (like step 3), so the NTS `cmp`
  inertness does not apply, but the perf bar does.

### The hardest open risks

1. **Fiber stack count and size.** One stack per outstanding await; a server with N in-flight
   connections holds N stacks. This is the real scaling cost a stackless transform would not
   have. Mitigation: a small lazily-committed stack with a guard page, a documented ceiling, and
   a `ponytail:` upgrade path (pooled or segmented stacks). Sized and measured in step 6b, where
   many awaits are first live at once.
2. **await inside php's engine (extension road).** Suspending with an `EG` frame open corrupts
   the executor. Step 5 refuses it by name (§ 6); the risk is a path that reaches `await` through
   the engine without tripping the guard. The guard is a flag set around every engine entry
   (`phx_*`), checked by `mcphp_await`.
3. **Cross-thread completion wakeup.** A future completed by thread B while thread A's loop sleeps
   in `ph_ev_wait` needs A woken (eventfd/self-pipe / `PostQueuedCompletionStatus`). Step 5
   confines completion to the loop's own I/O and timers and builds only the hook; 6b is where it
   is first used, and where a race between "complete" and "the loop decides to sleep" must be got
   right.
4. **IOCP's connect/accept path.** The completion-shaped surface (§ 2) covers read/write cleanly;
   `connect` on IOCP needs `ConnectEx` on an already-bound socket and `accept` needs `AcceptEx`,
   which differ enough from the POSIX arm-and-go that 6b (not step 5) must design them. Step 5's
   pipe-read test avoids them.
5. **`phT` across a swap.** The whole model assumes a fiber never migrates threads, so the
   `phT` fast-path copy stays valid across `ph_ctx_swap` (same OS thread, the block does not
   move). `src/tls.mc` folds `phT` copies within a function; an `await` is an opaque call, so
   `phT` held across it is still this thread's block -- but the no-migration invariant must be
   enforced (a fiber is resumed only by its creating thread's loop) and asserted by the
   self-test, because a violation is a silent wrong-arena bug, not a crash.

## Step 6b (BUILT)

Step 5 built the loop, fibers, futures and timers. Step 6b wires onto them: a non-blocking
socket surface, the userland `await()` over the primitive, and cross-thread completion. The
loop runs where there is no php engine (the program road and compiled workers); under a live
engine `await` is still refused (§ 6), so the demonstrations and gates are on the program road
and in compiled-worker threads.

### 1. The socket surface (`mcphp_connect`)

**`mcphp_connect(int $ip, int $port): int`** opens a socket and suspends on the loop until it
connects, returning the connected fd; the caller then awaits `mcphp_io_read` on it. Both are loop
I/O. A connect is a new `FUT_CONNECT` slot the loop completes:
- **kqueue / epoll:** a non-blocking `connect` (EINPROGRESS) armed for WRITABLE; on readiness the
  loop checks `SO_ERROR` (0 = connected, else the future fails). `ph_ev_arm_w` / `ph_os_connect`
  / `ph_os_sockerr` in `lib/rt_host_{macos,linux}.mc`.
- **IOCP (Windows):** a **blocking** loopback connect on an overlapped socket (a loopback connects
  at once), whose completion `ph_ev_arm_connect` posts to the port with
  `PostQueuedCompletionStatus`, so the loop resumes the awaiter; the read is the step-5 IOCP
  arm-and-go. WinSock is resolved at runtime through `GetProcAddress` (ws2_32 loaded, its names
  bound by pointer), so no program's link line gains a ws2_32 import library -- only
  `kernel32.def` gains `LoadLibraryA` and `PostQueuedCompletionStatus`.
  **Deviation (risk 4):** the async `ConnectEx` form (a ws2 extension pointer via `WSAIoctl`) is
  the documented upgrade; it is not needed for a loopback self-test and is left out to keep the
  Windows connect testable through CI rather than an untested extension-pointer path. The read --
  the loop I/O every target shares -- is IOCP on Windows.

`mcphp_tcp_listen(int $port): int` (a blocking loopback listener, `listen_fd << 32 | the port`)
and `mcphp_tcp_accept_send(int $lfd, string $data): void` (accept one, send, close) are test
scaffolding, so a self-test's connect has a peer with no network.

**`mcphp_io_read` is for sockets and pipes, not regular files.** A regular file is always
"ready", and epoll refuses `EPOLL_CTL_ADD` on one (`EPERM`), so a file fd cannot be a uniform
reactor arm across backends -- `mcphp_io_read` on a regular file throws `cannot submit the read`
(it unconditionally arms). The loop's suspend/resume I/O is sockets and pipes; a file's bytes are
read synchronously by the runtime (`file_get_contents`, as `awaitable\_read` does), never through
the loop. A direct-read fast path for regular files is a possible future upgrade, not a feature
today.

### 2. The userland `await()` (`examples/awaitable`)

`await()` is wired onto the primitive: where the loop may suspend
(**`mcphp_can_suspend()`** -- no php engine on the stack, the program road or a compiled worker)
it runs the callable on a fresh fiber and awaits the future through `mcphp_spawn` /
`mcphp_await`; under a live engine it runs the callable inline, as step 6a did. The engine-live
refusal (§ 6) is never tripped, and the `Intent` is the same either way. Verified byte for byte
against `examples/awaitable/check.expect` on a real ZTS php (`php:8.5-zts-alpine`, opcache on).

The example is an extension: its php callables always run under a live engine, so its own
`await()` takes the inline branch. The loop's "many I/Os on one thread" shape -- a fiber per
fetch, one `mcphp_loop_run`, replacing 6a's thread per fetch -- is demonstrated and gated on the
program road by `tests/c/23-http.php` (N fibers each connect+read on one thread, every connect
outstanding at once).

### 3. Cross-thread future completion

A future created on one thread can be completed (or failed) from another. `mcphp_future_complete`
/ `_fail`, when the completing thread is not the future's creator (`FUT_OWNER`), route the
completion to the creator's per-thread queue (`PHT_ph_xqh`/`xqt`) under the runtime lock, and wake
the creator's loop out of `ph_ev_wait` over a **per-loop self-wake** -- a persistently-armed
self-pipe on kqueue/epoll, `PostQueuedCompletionStatus` on IOCP (`LOOP_WAKE`). The creator's loop
drains the queue at the top of every turn and **deep-copies** the value into its own arena with
`php_tc_*`, exactly as a thread join copies a result; the producer's arena stays valid because the
retention model keeps a worker's memory until the request/process ends (§ The memory retention
ceiling).

The **"complete vs the loop decides to sleep" race (risk 3)** is handled by draining the queue at
the top of every turn (so a completion that arrived before the sleep is caught) and by blocking,
not deadlocking, on a bare awaited future (one that may be completed cross-thread). The **step-5
no-migration abort (risk 5)** is unchanged: a fiber is resumed only by its creating thread's loop,
or the process aborts by name. `tests/c/21-xthread.php` (program road, every leg): a worker
completes/fails the main thread's future and a nested array crosses the boundary.

### 4. Fiber stack sizing (risk 1), measured

Many awaits live at once is the N-connection server shape. Measured on macOS arm64 with a program
that spawns N fibers all suspended on a timer at the same time (max RSS, `/usr/bin/time -l`):

| outstanding awaits | max RSS |
|---|---|
| 0 | 1.61 MiB |
| 1024 | 18.59 MiB |

**~17.0 KiB committed per outstanding await** -- one 16 KiB page the shallow awaiter touches, the
rest of the 128 KiB stack reserved but never committed (`MAP_NORESERVE` / a guard page). This
matches the step-5 figure; the lazy commit is sufficient and the pooled/segmented-stack **ponytail
upgrade is not needed** at the `PH_FIB_MAX` = 1024 ceiling (1024 live awaits cost ~17 MiB). On
Windows the stack is committed up front (128 KiB each; the native idiom is a `PAGE_GUARD` grow
region, the recorded upgrade).

### 5. The gates

- **C twins:** `tests/c/await.c` (step 5: timer + pipe read) and `tests/c/connect.c` (step 6b:
  the loopback connect + read on raw kqueue/epoll + a pthread peer), each byte for byte its
  `.php` and timed (`tests/examples.sh`). POSIX; the Windows legs run the `.php` (IOCP).
- **llvm-mc sweep:** unchanged -- step 6b adds no `ph_ctx_swap` word (sockets are extern/runtime
  calls), so `tests/sweep_sync.py` and the dump-machine check carry over.
- **Per backend on its own leg:** `tests/c/18-await`, `21-xthread`, `22-connect`, `23-http` run
  via the fixture harness on all five legs -- kqueue (macos/arm64), epoll (linux aarch64 +
  x86_64), IOCP (windows x64 + arm64) -- so a wrong backend is red on its leg. Verified locally
  on kqueue (macOS) and epoll (linux/arm64, Docker); the IOCP legs are CI.
- **Leaks + ZTS:** `tests/leaks.sh` and `tests/frankenphp.sh` run `await_io` / `zts_await_io` -- a
  compiled worker that drives the loop (a timer fiber and a pipe read) inside a request, its loop
  torn down and every fiber stack unmapped at the worker's reap.
- **Inert / 2%:** a program that never awaits allocates no loop and no fiber -- `php_fut_new` and
  the loop are never reached, `examples/decimal` is unchanged.

### 6. Known limits (on record)

- **Windows connect is a blocking loopback connect**, not `ConnectEx` (§ 1 deviation); the read is
  IOCP. `ConnectEx` is the async upgrade.
- **A thread started inside a worker** (nested `mcphp_thread_start`) is supported: its record lives
  in its own arena, not the caller's, so the request's free loop (`php_thr_endall`) never releases
  a worker arena while a nested thread's record still points into it. This was once a hazard --
  the record was allocated in the worker's arena and the free loop unmapped it before reading the
  nested record, a use-after-free at shutdown -- fixed by allocating the record in the new thread's
  own arena (`php_thr_start`). Gated by `tests/ext/threads/nest.php` (a worker that starts and
  joins a thread of its own; the request ends clean) on the NTS and ZTS extension legs, and
  cross-thread completion by `tests/c/21-xthread` on the program road.

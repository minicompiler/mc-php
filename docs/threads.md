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
The buffers follow the scalars. The block is 12320 bytes.

### Shared, and why

| names | why it is safe |
|---|---|
| `ph_heap` | the booting thread's arena. Every other thread has its own (`ph_hbase`). |
| `ph_classes` `ph_ce_stdclass` `ph_ce_closure` | written at bootstrap. `ph_ce_closure` is lazy, so `php_thr_run` makes it on the booting thread before any other thread starts. |
| `ph_str_e` `ph_ch1` `ph_p10_done` | these were lazy. `php_bootstrap` now builds them eagerly: the empty string, all 256 one-byte strings and the powers of ten. |
| `ph_consts` | written by `define()` and read by `constant()`. A read from another thread is safe, because the booting thread is blocked in `php_thr_run` while the others run. A write gets an Error, which is **interim until step 3** (see "Module state" below). `php_const_get` no longer creates the table when it reads. |
| `ph_globals` `ph_rsl` | the global variable table and a static's reset list. Another thread gets an Error (`ph_shared_off`). This is **interim until step 3**. |
| `ph_rcchk` `phx_stats` | process-wide settings, read once from the environment. |
| `ph_eng` `phx_engt` `phx_eg` `phx_pce` `phx_zalloc_fn` `phx_egx` `phx_egx_done` | the engine's addresses and offsets, resolved on the booting thread. Another thread never enters the engine (see "php's engine" below). |
| `phx_me` `phx_fe` `phx_ai` `phx_nfn` `phx_nai` `phx_cfe` `phx_ncm` `phx_cfirst` | the module entry, the function entries, the arginfo and the published class tables. They are built in MINIT and read-only after it. |
| `phx_mark` `phx_snap` | the arena snapshot taken at the end of MINIT. It is restored at request start, on the booting thread. |
| `ph_rsnap` | the request's roots, saved and restored on the booting thread. |
| `ph_boot_done` | written once, by `php_bootstrap`. |
| `rtw_nio` (Windows) | **removed.** It is now a local of `read`/`write`. |
| `ph_tmain` `ph_tcur` `ph_mt` `ph_tkey` | the mechanism itself (below). They are written only by the booting thread, and only while no other thread runs. |

### Generated module globals

| prefix | what | why it is safe |
|---|---|---|
| `phl_` | a string literal's cache | built by `ph_lit_init` before the program's first statement. A literal is immutable and never counted. |
| `phm_` | a byte map built from a literal | built in `ph_lit_init`, after the literals. |
| `ce_` | a class entry | built at bootstrap, and read-only after it. |
| `phf_` | a call site's cache of php's function table | written only through `phx_flook`, which another thread cannot reach. |
| `phst_` | a function `static` | `php_static` refuses another thread (`ph_shared_off`). This is **interim until step 3**. |

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

When the last thread joins, the fast path comes back.

The generated code names seven of these words: `ph_exc`, `ph_dfile`, `ph_dline`, `ph_pn`,
`ph_pool`, `ph_pcap` and `phx_lz`. The compiler keeps those names through `opt` and `rc`. After
parsing, a pass (`src/tls.mc`) does three things:

- It lowers each of the seven names to a load or store off `phT`.
- It inserts the same first line into each function that needs it.
- It folds the `phT` copies that inlining brings in from runtime bodies into one `phT`.

Each other thread gets the following:

- **An arena.** POSIX: 256 MiB `mmap`'d and reserved. Windows: 64 MiB, `VirtualAlloc`'d and
  committed.
- **A block.** It inherits these from the starting thread: `error_reporting`, `display_errors`,
  `log_errors`, the error and exception handlers, and the file table. It also gets a random seed
  mixed from the starting thread's seed.
- **No Zend allocator** (`ph_zalloc` = 0). So its strings live in its arena and never touch Zend.

When the thread ends, its arena and its block are always unmapped. A thread never pins
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

## Module state: interim until step 3

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

The message is `mc-php: a global variable is shared by every thread: another thread may not
reach it`. **This is interim until step 3; module globals become shared.**

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

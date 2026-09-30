# T3b -- a php callable on a worker thread: (a) share the request's code, or (b) copy the callable

Threads step 3b (docs/threads.md § 3b) needs a worker thread to become a php thread with a context
of its own and run a php closure that may name the starting request's functions and classes. This
probe measures the two candidates before anything is built. `t3b.c` is a throwaway extension; it
is not mc-php code.

Host: Lima `mc-k7`, Ubuntu 26.04, linux/aarch64, Docker.
- `php:8.5-zts-alpine`: php 8.5.11 ZTS, release.
- `mc-php-t3b-dbg` (`Dockerfile.dbg`): the same php source with `--enable-debug --enable-zts`, so
  assertions are on.
- `dunglas/frankenphp:php8.5-alpine`: php 8.5.11 ZTS under FrankenPHP, 8 php threads. The
  extension is built in `php:8.5-zts-alpine`, which carries the same php build.

## The worker

The worker follows ext/parallel's sequence:
- `ts_resource(0)`, then `php_request_startup()`, then `SG(headers_sent) = 1`;
- the call, under an internal frame, so that an uncaught throwable stays in `EG(exception)`;
- `php_request_shutdown()`, then `ts_free_thread()`.

The closure is re-created in the worker (`zend_create_closure`) from the starting closure's
function. Each mode makes the starting request's code available in a different way:

| mode | what the worker gets |
|---|---|
| 0 | (a) as-is: the starting request's user functions and classes in the worker's tables BY POINTER; the closure shares the starting closure's run-time cache |
| 1 | (a') functions copied shallowly (opcodes and literals shared, a run-time cache and statics of the worker's own); classes by pointer; a private closure cache |
| 2 | (b) the callable alone, with a private cache; nothing of the request registered |
| 3 | (a) opcache-style: functions and classes by pointer, no copies; `zend_map_ptr_extend(starting thread's CG(map_ptr_last))`; a private closure cache |

`test.php` runs two closures, 8 workers at once:
- `$self` names nothing of the request.
- `$named` does `new Pt($i, helper($i))` and calls `$p->sum()` in a loop. `Pt` and `helper` are
  the request's own class and function.

The starting request is either idle (`loops 0`) or runs the same closure 200 times meanwhile
(`loops 200`). `run.sh IMAGE REPS` prints the matrix; `segv.sh`/`segv2.sh` symbolise a crash (gdb
cannot read this VM's SVE registers).

## Results

`run.sh` output, 20 runs per cell on the release build and 10 on the debug build. "crash" means
SIGSEGV, or SIGABRT from an assertion on the debug build.

| opcache | mode | loops 0 | loops 200 |
|---|---|---|---|
| off | 0 share as-is | crash 18/20 (debug 10/10) | ok 20/20 |
| off | 1 copy functions | crash 18/20 (debug 10/10) | ok 20/20 |
| off | 2 callable only | php Error `Class "Pt" not found` 20/20 | same |
| off | 3 opcache-style | crash 20/20 (debug 10/10) | ok 20/20 |
| on | 0 share as-is | crash 20/20 | crash 20/20 |
| on | 1 copy functions | ok 20/20 (debug 10/10) | ok 20/20 |
| on | 2 callable only | php Error `Class "Pt" not found` 20/20 | same |
| on | 3 opcache-style | **ok 20/20 (debug 10/10, no assert)** | **ok 20/20** |

What causes each failure (symbolised; the debug build agrees):

1. **opcache off: a run-time cache is one pointer into the declaring thread's memory.** Without
   opcache, a user function's or a method's `run_time_cache` is a plain pointer. It is allocated
   lazily in the arena of whichever thread calls it first. When a worker calls first, the cache
   lives in that worker's arena; the arena is freed at the worker's request shutdown, and the next
   thread reads freed memory. The crash is in `ZEND_FETCH_OBJ_R` for `$this->x` inside `Pt::sum`.
   When the starting request has called first (`loops 200`), every thread then shares ONE cache
   and writes into it concurrently. That did not crash in 20 runs, but it is a data race, and a
   function's `static` variables are shared the same way. Copying functions (mode 1) is not enough,
   because methods are op_arrays too: the whole class table would have to be copied.
2. **opcache on, mode 0: the shared closure cache.** Immutable op_arrays keep their run-time cache
   and statics in a per-thread `ZEND_MAP_PTR` slot. Two things still break:
   - A Closure object's cache is a plain pointer. Eight workers sharing it tear its two-word
     entries (class, then function or offset); the crash is `addr=0` in `ZEND_FETCH_OBJ_R`.
   - A slot the starting thread allocated after the worker's table was sized is past the end of
     that table: with 180 slots in the starting thread and 171 in a fresh worker, `sum`'s slot is
     173. `zend_map_ptr_extend` fixes that. Mode 3 = extend + a private closure cache.
3. **(b) is not only a missing name: it can crash the engine.** A call to a function declared
   earlier in the same file compiles to `INIT_FCALL`, which assumes the function exists. In a
   worker that does not have it:
   - the release build gives SIGSEGV;
   - the debug build fails the assertion `func != NULL && "Function existence must be checked at
     compile time"` (`zend_vm_execute.h`, `ZEND_INIT_FCALL_SPEC_CONST_HANDLER`).

   `big.php` shows it. `test.php` only gives the Error because `new Pt` fails first. So (b) needs
   an opcode walk that refuses, or rewrites, every `INIT_FCALL` and class reference to the request
   -- ext/parallel's approach.

### FrankenPHP

`fp.sh MODE OPCACHE REQS PAR LOOPS`: 8 php threads, 2000 requests 16 at a time, each request
starting 2 workers on `$named`.

| mode | opcache | loops | result | FrankenPHP afterwards |
|---|---|---|---|---|
| 3 | on | 20 | 2000/2000 right | alive |
| 3 | on | 0 | 2000/2000 right | alive |
| 3 | off | 20 | 2000/2000 right (the shared caches the request warmed) | alive |
| 3 | off | 0 | 5/2000 right | **dead** (crashed) |
| 2 | on and off | 20 | 2000/2000 `Class "Pt" not found` | alive |
| 0 | on | 20 | 0/2000 | **dead** |
| 1 | off | 20 | 2000/2000 right | alive |

A worker's `echo` under FrankenPHP arrived in the starting request's response, 3 of 3 times
(`fp/echo.php`). Two workers writing at once go through one response writer; that is not measured
for ordering.

### Cost per start

`cost.sh`, release build, 300 starts one after another, best of 3. An empty closure costs about
**400 us** per start. `T3B_TIME` splits it by phase:

| phase | us per start |
|---|---|
| `ts_resource` (a new thread's copies of every module's globals and CG's tables) | 264-271 |
| `php_request_startup` | 11 |
| share + call (`$named`: 1 function, 1 class) | 10-71 |
| `php_request_shutdown` | 3-4 |
| `ts_free_thread` | 55-59 |

Opcache on or off makes no measurable difference to the start. Sharing costs one hash insert per
user function and class: with 2000 functions and 200 classes (`big.php`, mode 3, opcache on) the
share + call phase is 119 us and the whole start is 514 us. The `$self` closure costs 5.4 us per
call on the starting thread (opcache on) and 7.9 us (off).

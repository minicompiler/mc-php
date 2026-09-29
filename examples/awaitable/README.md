# awaitable -- HAND-WRITTEN mc, not mc-php output: `await`, `parallel`, threads and sync

**`awaitable.mc` is written by hand in mc. mc-php does not produce it.** `awaitable.src.php` is
the PHP source it stands in for -- the source the compiler is working toward -- and mc-php refuses
that file by name today. The example is gated anyway, because what it does is the shape an
mc-php extension with real parallelism will have.

```php
$w = \awaitable\await($callable, ...$args);      // suspends, runs, ALWAYS an Intent
$w->done; $w->failed; $w->exception; $w->data;

$r = \awaitable\parallel($anyCallable, ...$args); // one forked child per argument
$b = \awaitable\http_get_many(...$urls);          // one OS thread per url (libcurl)

$s = new \awaitable\Semaphore(2); $s->bind();     // every thread above passes through it
new \awaitable\WaitGroup(); new \awaitable\Mutex();
```

There is no async, so `await` does what await does: it suspends and runs to completion, and it
always hands back an `Intent` -- the envelope, never narrowed to the callable's own value. The
parallelism lives inside a NATIVE callable: `http_get_many` runs each fetch on a pthread, and
`parallel` forks a child per argument, so ANY php callable -- a closure, a method, an internal
function -- runs off the main line with its body never compiled: the interpreter is not
reentrant, and a child process is a full copy of it. The value comes home through php's own
`serialize` over a pipe. Semaphore and WaitGroup are a mutex and a condition variable each.

## What stands between `awaitable.src.php` and the compiler

Each refusal found by removing the one before it and building again, 2026-09-23, and struck
off as the compiler learns it:

| line | what | mc-php says |
|---|---|---|
| 7 | `namespace awaitable;` | DONE (the awaitable branch, 2026-09-28): namespaces and `use` imports with php's rules, declarations published as `awaitable\...` (`src/ns.mc`, `tests/g/120-namespaces.php`) |
| 30 | `public ?\Throwable $exception` | DONE with it: a fully-qualified name is one token |
| 13-18 | `#[Extern('curl')] function curl_easy_init(): Ptr {}` and five more | DONE (the awaitable-extern branch): a C function declared in php, `#[Extern('lib', variadic: N)]` (`src/extern.mc`, `tests/c/08-extern.php`, `tests/ext.sh` step 16) |
| 23-24 (was) | `#[Extern(host: true, kind: 'data')] function executor_globals(): Ptr {}` and `zend_ce_exception` | REMOVED from the source: calling a php callable, catching what it throws and handing back an object are the compiler's own crossing, so the source never reads the engine's globals |
| 36 | `function await(callable $fn, mixed ...$args): Intent` | DONE (the awaitable-classes branch): a signature beyond the scalars -- `callable`, `mixed ...$args`, a class, `array` -- checked as php's own parameter parsing checks it, and php's arrays and objects inside the module (`lib/php_ext.mc` § engine values, `tests/ext.sh` step 17) |
| 65 | `function parallel(callable $fn, mixed ...$args): array` | DONE with it |
| 26 | `final class Intent` and the three sync classes | DONE (the awaitable-published branch): published, the engine's own classes (`lib/php_ext.mc` § published classes, `tests/ext.sh` step 18) |
| 36 | `await`'s body | DONE (the awaitable-call branch): `$fn(...$args)` calls any php callable -- a name (`'strtoupper'`), an array, a closure, an `__invoke` object -- through php's own `_call_user_function_impl`, and what it throws is kept in the Intent as the engine's object (`lib/php_ext.mc`'s `phx_vcall` and `phx_exc_obj`, `tests/ext.sh` step 19). `check.php` then stopped at line 10: `\awaitable\reset()` |
| 65 | `parallel`'s body, `reset`/`peak`/`completed`/`errors` | DONE (the awaitable-parallel branch): one `fork()` per argument through `#[Extern('c')]`, the child calls `$fn` through php, `serialize()`s the answer down a `pipe()` and `_exit`s; the parent reads each pipe in order, `waitpid()`s and `unserialize()`s, and a child that threw is its message and one more `errors()`. A buffer C writes into -- `pipe()`'s two descriptors, `read()`'s bytes, `waitpid()`'s status -- is a php string of that length, read back with `unpack()`. The counters are module globals and, as in the C twin, count the threads: after `parallel` `completed()` and `peak()` are 0 (a `check.php` line says so). A read or a `waitpid` a signal interrupts is asked again on EINTR and on nothing else, as the C twin does -- the source reads C's `errno` through `#[Extern('c')] function errno(): int {}` -- and `signals.php` runs `parallel` under a SIGCHLD handler with no `SA_RESTART`, under one that reaps any child, and under `SIG_IGN`, against both (the hand-written `awaitable.mc` keeps the gap: it retires with the threads). `check.php` now stops at line 33: `http_get_many`, the threads |

What is left -- `http_get`, `http_get_many`, `wait_all` and the three sync classes' bodies -- needs
what the source cannot say yet: code that runs on another OS thread (pthread_create's worker,
curl's write callback) and native memory for a mutex, a condition variable and a body buffer.
That is the owner's decision still open (a `#[Native]` function); the C library itself is
`#[Extern]`'s, with `variadic:` placing curl's variadic argument.

## How it is checked -- `tests/examples.sh`

| step | macOS, linux/aarch64, linux/x86_64 | windows/x86_64, windows/arm64 |
|---|---|---|
| `awaitable.mc` compiled by plain mc and linked; `check.php` against `check.expect`, byte for byte: 37 lines -- await, a throwing callable, a bad callback, parallel with six children (distinct pids, none of them php's own, the same sums as sequential), closures, methods and internal functions, a throwing child, `await(parallel)`, six `file://` fetches on threads under `Semaphore(2)` (bodies as written, peak concurrency within 2), the sync primitives, and that the native handle is private | yes | SKIPPED, the reason printed: pthreads, `fork`, `pipe` and `dlsym` are POSIX |
| `demo.php` (the owner's `reference/aw6.php`, translated) run, and its `same results: true` line required; its times are printed, not gated | yes | SKIPPED |
| the C twin, `c/awaitable.c` -- the same extension written as an ordinary C extension, awaitable.mc's algorithm function by function (and, unlike awaitable.mc, a Semaphore, WaitGroup or Mutex frees its native handle with the object and cannot be cloned), and the specification the compiled module is measured against -- built with `php-config`, `cc` and libcurl where the host has them, and graded by the same `check.php` against the same `check.expect` | yes, where `php-config` is | SKIPPED: fork, pipe and pthreads |
| the build this example waits for, `mcphp.toml` over `awaitable.src.php`, refused with the first message above that is not DONE | yes | yes |

Nothing touches the network: the threads fetch files the script writes. The module resolves
libcurl from php's own process, so a php without the curl extension skips it by name.

`awaitable.mc` is a TEMPLATE. The gate fills the target php's four module-header values from
`php -i` (`reference/extgen.sh`'s road), `dlsym`'s "every global image" handle -- `(void *)-2` on
macOS, `(void *)0` on Linux -- and where a C variadic argument travels, which is the ABI's: Apple
arm64 puts it on the STACK after the eight argument registers, so the call pads six zeros to get
there; AAPCS64 and SysV x86-64 put it in the next register. The first Linux run of the reference
file, which padded everywhere, measured that: curl answered `URL using bad/illegal format or
missing URL`.

`demo.php` on 2026-09-23, eight calls of four million iterations each:

| host | `parallel` | against sequential |
|---|---|---|
| macos/arm64 | 38 ms | 3.3x |
| linux/aarch64 (container) | 57 ms | 2.7x |

| file | |
|---|---|
| `awaitable.mc` | the extension, hand-written, from `reference/aw6.mc` |
| `awaitable.src.php` | the PHP source it stands for, from `reference/awaitable.src.php` |
| `c/awaitable.c` | the C twin |
| `mcphp.toml` | the build over `awaitable.src.php` that the gate pins |
| `check.php`, `check.expect` | the gate |
| `demo.php` | the timed demonstration |

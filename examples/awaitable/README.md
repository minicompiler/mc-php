# awaitable -- `await`, `parallel`, threads and sync, compiled by mc-php

`awaitable.src.php` is the extension's PHP source; **mc-php compiles it to a ZTS
`.so`/`.dll`** -- no C, no phpize. It is built on native OS threads
([docs/threads.md](../../docs/threads.md) step 3) and native sync (step 4): no
fork, no pipe, no dlsym, no libcurl, no `#[Extern]`. So it builds and runs on
every host mc-php targets, Windows included, wherever a thread-safe php loads it.

```php
$w = \awaitable\await($callable, ...$args);       // suspends, runs, ALWAYS an Intent
$w->done; $w->failed; $w->exception; $w->data;

$r = \awaitable\parallel($anyCallable, ...$args);  // one OS thread per argument
$b = \awaitable\http_get_many(...$urls);           // one OS thread per url

$s = new \awaitable\Semaphore(2); $s->bind();      // caps http_get_many's threads
new \awaitable\WaitGroup(); new \awaitable\Mutex();
```

`await` always hands back an `Intent` -- the envelope, never narrowed to the
callable's own value. Since step 6b it is **wired onto the event loop**: where
the loop may suspend (no php engine on the stack -- the program road or a
compiled worker, `mcphp_can_suspend()`) it runs the callable on a fresh fiber
through `mcphp_spawn`/`mcphp_await`; under a live php engine -- this extension's
own road, where suspending would corrupt the executor
([docs/threads.md](../../docs/threads.md) § 6) -- it runs the callable inline,
as it always did. The `Intent` is the same either way. The loop's "many I/Os on
one thread" shape (a fiber per fetch, replacing a thread per fetch) is
demonstrated and gated on the program road by `tests/c/23-http.php`; the
non-blocking socket surface it drives is `mcphp_connect` + `mcphp_io_read`
(`tests/c/22-connect.php`).

The parallelism is **native OS threads**. `parallel` runs each php callable on a
thread of its own; a thread-safe php runs it as a php request of its own
(docs/threads.md § 3b, which is why this is a ZTS extension and why opcache must
be on). `http_get_many` runs each fetch on a compiled worker thread -- no php
engine, its own arena -- through the runtime's own `file_get_contents`, capped by
the bound `Semaphore`. The threads share this process, so a task's `getmypid()`
is the parent's, not a forked child's. `Semaphore`, `WaitGroup` and `Mutex` are
thin PHP classes over the `mcphp_semaphore*`, `mcphp_waitgroup*` and
`mcphp_mutex*` intrinsics, each holding its native handle in a private property.

## How it is checked -- `tests/examples.sh`

The module compiles from `awaitable.src.php` and `check.php` runs against
`check.expect`, byte for byte, on a **thread-safe (ZTS) php** (`parallel`'s php
callables are § 3b workers, so opcache is on: `-d opcache.enable_cli=1`). macOS
ships an NTS php, so the gate SKIPs there with the reason printed; CI runs it on
the ZTS legs -- macos/arm64, linux/{aarch64,x86_64} (in `php:8.5-zts-alpine`) and
windows/{x86_64,arm64} -- and `tests/frankenphp.sh` runs the ZTS road under a
real threaded SAPI. `demo.php` (the owner's timed demonstration) is run and its
`same results: true` line required; its times are printed, not gated. Nothing
touches the network: the threads read `file://` urls the script writes.

### The C twin -- `c/awaitable.c` + `c/twin.php`

The C twin is the same workload written as an ordinary C extension, on native
pthreads and native sync (a mutex/condvar per Semaphore and WaitGroup, a mutex
per Mutex) -- the specification the compiled module is measured against. A C
extension has no php interpreter per thread, so it does **not** run php callables
on threads (that is the module's § 3b); it mirrors the concurrency STRUCTURE with
the C EQUIVALENT of this example's workload. Its driver `c/twin.php` therefore
names each `parallel` workload -- `heavy`, `bracket`, `shout`, `strrev`, `throw`
-- which the twin's C `parallel` dispatches to a C function on a pthread, and it
prints **check.expect's bytes**: the module's checksum. `await` still takes a
real callable (the twin runs it on the calling thread, which has the
interpreter). It is built with `php-config` and `cc` against the ZTS php's own
headers; POSIX pthreads, so it is not built on Windows, where CI's ZTS legs cover
the module.

### The Semaphore cap, and a compiler bug it caught

`http_get_many`'s line asserts the bound `Semaphore(2)` capped concurrency to at
most 2 (`peak concurrency within the semaphore's 2: true`). This example once
failed that line at `-O` (opt=1) -- not from a runtime race in the sync core, but
from a deterministic mc-php codegen bug: the P11 leaf pass `pm_leaf`
(`src/mach.mc`) did an unguarded parameter-to-argument-register remap that
clobbered the argument of `php_sy_sem`'s `ph_sy_new(SY_SEM, n)` call, so at
opt=1 **every** `mcphp_semaphore($k)` was constructed with 3 permits regardless
of `$k`. Being a compile-time, `-O`-only bug and not a scheduling race, it was
fully reproducible, not intermittent. It is fixed and merged (#49): `pm_leaf`'s
remap now preserves the register, so `mcphp_semaphore($k)` grants exactly `$k`
permits, and this line passes reliably at opt=1.

## Files

| file | |
|---|---|
| `awaitable.src.php` | the extension's PHP source; mc-php compiles it |
| `mcphp.toml`, `mcphp.linux.toml`, `mcphp.windows.toml` | the ZTS build per host |
| `check.php`, `check.expect` | the gate |
| `demo.php` | the timed demonstration |
| `c/awaitable.c`, `c/twin.php` | the C twin and its driver |

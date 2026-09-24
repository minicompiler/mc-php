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

Each refusal found by removing the one before it and building again, 2026-09-23:

| line | what | mc-php says |
|---|---|---|
| 7 | `namespace awaitable;` | `a namespace in an extension source is not implemented yet` -- **pinned by the gate** |
| 30 | `public ?\Throwable $exception` | `a php class member: \ is not implemented yet` (a fully-qualified type in a property) |
| 13-24 | `#[Extern('curl')] function curl_easy_init(): Ptr {}` and seven more | `an exported function whose return type is not a declared scalar: curl_easy_init` -- the attribute means nothing to mc-php yet, so the declaration is read as a function to export |
| 37 | `function await(callable $fn, mixed ...$args): Intent` | `a variadic parameter in an exported function: await` -- and behind it a `callable` parameter and a class return, both outside the scalar signatures |
| 66 | `function parallel(callable $fn, mixed ...$args): array` | the same, and an `array` return |

With those five stubbed out it builds -- and the four classes are compiled and NOT published:
`class_exists('awaitable\Semaphore')` is false in a php that loaded it, with no refusal, because
the back end registers no class yet (`docs/php-extension.md`). Behind the signatures the BODIES
need what no PHP source can say today: a C library called with a C variadic (`#[Extern]`, whose
`variadic:` field is exactly the placement below), a php callable called back from native code,
`fork`, `pipe` and pthreads.

## How it is checked -- `tests/examples.sh`

| step | macOS, linux/aarch64, linux/x86_64 | windows/x86_64, windows/arm64 |
|---|---|---|
| `awaitable.mc` compiled by plain mc and linked; `check.php` against `check.expect`, byte for byte: 37 lines -- await, a throwing callable, a bad callback, parallel with six children (distinct pids, none of them php's own, the same sums as sequential), closures, methods and internal functions, a throwing child, `await(parallel)`, six `file://` fetches on threads under `Semaphore(2)` (bodies as written, peak concurrency within 2), the sync primitives, and that the native handle is private | yes | SKIPPED, the reason printed: pthreads, `fork`, `pipe` and `dlsym` are POSIX |
| `demo.php` (the owner's `reference/aw6.php`, translated) run, and its `same results: true` line required; its times are printed, not gated | yes | SKIPPED |
| the build this example waits for, `mcphp.toml` over `awaitable.src.php`, refused with the first message above | yes | yes |

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
| `mcphp.toml` | the build over `awaitable.src.php` that the gate pins |
| `check.php`, `check.expect` | the gate |
| `demo.php` | the timed demonstration |

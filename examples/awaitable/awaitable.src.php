<?php
// The SOURCE the extension compiler is meant to consume: this file is to
// compile to the awaitable.so that awaitable.mc produces today by hand. No C,
// no phpize. It compiles; README.md lists what its bodies still wait for, and
// tests/examples.sh records how far check.php gets through the compiled
// module (and, on Windows, pins #[Extern]'s refusal).

namespace awaitable;

// --- foreign declarations -------------------------------------------------
// The attribute names the library; the signature is the ABI. `variadic` marks
// a call whose extra argument travels on the stack (curl_easy_setopt), which is
// what the compiler has to know in order to place it.
#[Extern('curl')] function curl_easy_init(): Ptr {}
#[Extern('curl', variadic: 1)] function curl_easy_setopt(Ptr $h, int $opt, mixed $v): int {}
#[Extern('curl')] function curl_easy_perform(Ptr $h): int {}
#[Extern('curl')] function curl_easy_strerror(int $code): Ptr {}
#[Extern('pthread')] function pthread_create(Ptr $tid, Ptr $attr, Ptr $fn, Ptr $arg): int {}
#[Extern('pthread')] function pthread_join(Ptr $tid, Ptr $ret): int {}

// The engine's own state -- executor_globals, zend_ce_exception, which
// awaitable.mc reads through dlsym -- is not declared here: calling a php
// callable, catching what it throws and handing back an object are the
// compiler's own crossing, so the source never touches the engine's globals.

// --- what the extension publishes ----------------------------------------
final class Intent {
    public bool $done = false;
    public bool $failed = false;
    public ?\Throwable $exception = null;
    public mixed $data = null;
}

// There is no async, so await does what await does: it SUSPENDS and RUNS to
// completion. It always hands back an Intent -- the envelope is the wide type,
// never narrowed to the callable's own return value.
function await(callable $fn, mixed ...$args): Intent {
    $i = new Intent();
    try {
        $i->data = $fn(...$args);
    } catch (\Throwable $e) {
        $i->failed = true;
        $i->exception = $e;
    }
    $i->done = true;
    return $i;
}

// The sync primitives are for PARALLELISM AND CONCURRENCY, not for async: they
// coordinate the threads that run underneath, and they are what caps and joins
// them. bind() makes every thread this process starts pass through it.
final class Semaphore {
    public function __construct(int $n = 1) {}
    public function acquire(): void {} public function release(): void {}
    public function bind(): void {}    public function unbind(): void {}
}
final class WaitGroup {
    public function add(int $n = 1): void {}
    public function done(): void {} public function wait(): void {}
}
final class Mutex { public function lock(): void {} public function unlock(): void {} }

// --- where the parallelism lives ------------------------------------------
// There is no #[Thread]: the dev hands over a callable HE already has, and its
// body is never compiled. The interpreter is not reentrant, so an interpreted
// body runs off the main line only in another PROCESS -- a full copy of the
// interpreter, which is why any callable works with no bootstrap and no ZTS.
//
//   $r = parallel($anyCallable, ...$args);   // one child per arg, runs at once
//   $i = await(parallel(...), $fn, ...$a);   // and await still hands an Intent
//
// The value comes home through php's own serialize/unserialize over a pipe,
// and that is also the bound: only what serialize accepts crosses back, and
// nothing the child mutates is shared. On Windows there is no fork, so that
// door becomes CreateProcess + re-exec, or a second interpreter under ZTS.
function parallel(callable $fn, mixed ...$args): array {}
function errors(): int {}

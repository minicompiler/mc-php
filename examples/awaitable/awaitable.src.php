<?php
// awaitable -- a ZTS PHP extension, compiled by mc-php from this file. No C, no
// phpize. It is the redesign onto native OS threads (docs/threads.md § Step 3)
// and native sync (§ Step 4): no fork, no pipe, no dlsym, no #[Extern]. So it
// builds and runs on every host mc-php targets, Windows included, wherever a
// thread-safe php loads it.
//
//   mc-php build examples/awaitable --config examples/awaitable/mcphp.linux.toml
//
// The thread and sync primitives (mcphp_thread_start/join, mcphp_semaphore*,
// mcphp_waitgroup*, mcphp_mutex*, mcphp_atomic*) are mc-php intrinsics: they
// exist only in compiled code, so this file IS the compiler's input and never
// runs under interpreted php. check.php exercises what it publishes.

namespace awaitable;

// --- what the extension publishes ----------------------------------------
final class Intent {
    public bool $done = false;
    public bool $failed = false;
    public ?\Throwable $exception = null;
    public mixed $data = null;
}

// await hands back an Intent -- the envelope is the wide type, never narrowed
// to the callable's own return value. It is WIRED onto the loop (step 6b): where
// the loop may suspend (the program road or a compiled worker -- no php engine),
// it runs $fn on a fresh fiber and awaits the future through mcphp_spawn /
// mcphp_await. Under a live php engine (this extension's own road) the loop may
// not suspend (docs/threads.md § 6), so it runs $fn inline, as step 6a did; the
// Intent is the same either way.
function await(callable $fn, mixed ...$args): Intent {
    $i = new Intent();
    if (\mcphp_can_suspend()) {
        try {
            // spawn one fiber running a closure that does the variadic call, so
            // mcphp_spawn takes a single callable (its own arguments cap is 5)
            $i->data = \mcphp_await(\mcphp_spawn(function () use ($fn, $args) { return $fn(...$args); }));
        } catch (\Throwable $e) {
            $i->failed = true;
            $i->exception = $e;
        }
    } else {
        try {
            $i->data = $fn(...$args);
        } catch (\Throwable $e) {
            $i->failed = true;
            $i->exception = $e;
        }
    }
    $i->done = true;
    return $i;
}

// --- the sync primitives, thin wrappers over the intrinsics ----------------
// Each holds one native handle -- an int the runtime owns -- in a PRIVATE
// property, so the handle is not the caller's to write (docs/threads.md § 4).
// bind() makes the threads http_get_many starts pass through this semaphore.
final class Semaphore {
    private int $__h;
    public function __construct(int $n = 1) { $this->__h = \mcphp_semaphore($n); }
    public function acquire(): void { \mcphp_semaphore_acquire($this->__h); }
    public function release(): void { \mcphp_semaphore_release($this->__h); }
    public function bind(): void { global $bound_sem; $bound_sem = $this->__h; }
    public function unbind(): void { global $bound_sem; $bound_sem = 0; }
}
final class WaitGroup {
    private int $__h;
    public function __construct() { $this->__h = \mcphp_waitgroup(); }
    public function add(int $n = 1): void { \mcphp_waitgroup_add($this->__h, $n); }
    public function done(): void { \mcphp_waitgroup_done($this->__h); }
    public function wait(): void { \mcphp_waitgroup_wait($this->__h); }
}
final class Mutex {
    private int $__h;
    public function __construct() { $this->__h = \mcphp_mutex(); }
    public function lock(): void { \mcphp_mutex_lock($this->__h); }
    public function unlock(): void { \mcphp_mutex_unlock($this->__h); }
}

// --- the counters ----------------------------------------------------------
// Process-wide atomics, so a native worker and the thread that started it read
// and write the same word. Since reset(): peak is the greatest number of tasks
// that ran at once, completed the tasks that returned, errors the ones that
// threw. They count the THREADS -- parallel's and http_get_many's alike, now
// that both ARE threads.
$c_peak = \mcphp_atomic(0);
$c_completed = \mcphp_atomic(0);
$c_errors = \mcphp_atomic(0);
$c_running = \mcphp_atomic(0);
$bound_sem = 0;

function _bump(int $h, int $v): void {
    while (true) {
        $cur = \mcphp_atomic_load($h);
        if ($v <= $cur) return;
        if (\mcphp_atomic_cas($h, $cur, $v)) return;
    }
}

function peak(): int { global $c_peak; return \mcphp_atomic_load($c_peak); }
function completed(): int { global $c_completed; return \mcphp_atomic_load($c_completed); }
function errors(): int { global $c_errors; return \mcphp_atomic_load($c_errors); }
function reset(): void {
    global $c_peak, $c_completed, $c_errors, $c_running;
    \mcphp_atomic_store($c_peak, 0);
    \mcphp_atomic_store($c_completed, 0);
    \mcphp_atomic_store($c_errors, 0);
    \mcphp_atomic_store($c_running, 0);
}

// --- parallel: any php callable, one thread per argument -------------------
// Each argument runs the callable on an OS thread of its own -- a php request
// on a thread-safe php (docs/threads.md § 3b) -- and the threads share this
// process, so a task's getmypid() is the parent's, not a forked child's. The
// handles are joined in submission order, so the results stay ordered.
function parallel(callable $fn, mixed ...$args): array {
    global $c_completed, $c_peak, $c_errors;
    $n = count($args);
    if ($n === 0) throw new \ArgumentCountError('awaitable\parallel() expects at least 2 arguments, 1 given');
    if ($n > 64) throw new \TypeError('awaitable\parallel(): at most 64 jobs');
    $h = [];
    foreach ($args as $i => $arg) $h[$i] = \mcphp_thread_start($fn, $arg);
    // every one is outstanding until the joins begin
    _bump($c_peak, $n);
    $out = [];
    foreach ($h as $i => $handle) {
        try {
            $out[$i] = \mcphp_thread_join($handle);
            \mcphp_atomic_add($c_completed, 1);
        } catch (\Throwable $e) {
            \mcphp_atomic_add($c_errors, 1);
            $out[$i] = $e->getMessage();
        }
    }
    return $out;
}

// --- the threads: native work on OS threads, capped by a semaphore ---------
// http_get_many runs each fetch on a native thread (a compiled worker, no php
// engine, its own arena) through the runtime's own file_get_contents. A bound
// semaphore caps how many run at once, and the peak counter records how many
// actually did.
function http_get_many(...$urls): array {
    global $bound_sem, $c_running, $c_peak, $c_completed;
    $sem = $bound_sem;
    $run = $c_running;
    $pk = $c_peak;
    $cp = $c_completed;
    $h = [];
    foreach ($urls as $i => $url) {
        $h[$i] = \mcphp_thread_start(fn(string $u): string => _http_do($u, $sem, $run, $pk, $cp), $url);
    }
    $out = [];
    foreach ($h as $i => $handle) $out[$i] = \mcphp_thread_join($handle);
    return $out;
}

// one worker: through the semaphore, count itself in and out, and read the file
function _http_do(string $u, int $sem, int $run, int $pk, int $cp): string {
    if ($sem !== 0) \mcphp_semaphore_acquire($sem);
    $n = \mcphp_atomic_add($run, 1) + 1;
    _bump($pk, $n);
    $body = _read($u);
    \mcphp_atomic_add($run, -1);
    \mcphp_atomic_add($cp, 1);
    if ($sem !== 0) \mcphp_semaphore_release($sem);
    return $body;
}

function http_get(string $url): string {
    $b = _read($url);
    if ($b === '') throw new \Exception('awaitable\http_get: cannot read ' . $url);
    return $b;
}

// a file:// url is a path; the runtime's file_get_contents reads it
function _read(string $u): string {
    $p = substr($u, 0, 7) === 'file://' ? substr($u, 7) : $u;
    $b = @file_get_contents($p);
    return $b === false ? '' : $b;
}

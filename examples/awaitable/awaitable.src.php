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
//
// The C library's side of it is declared like curl's. A buffer C writes into
// -- pipe()'s two descriptors, waitpid()'s status, read()'s bytes -- is a php
// string of that length: C sees its bytes, and unpack() reads them back.
#[Extern('c')] function fork(): int {}
#[Extern('c')] function pipe(string $fds): int {}
#[Extern('c')] function waitpid(int $pid, string $status, int $options): int {}
#[Extern('c')] function _exit(int $code): void {}
#[Extern('c', name: 'read')] function c_read(int $fd, string $buf, int $n): int {}
#[Extern('c', name: 'write')] function c_write(int $fd, string $buf, int $n): int {}
#[Extern('c', name: 'close')] function c_close(int $fd): int {}
#[Extern('c', name: 'kill')] function c_kill(int $pid, int $sig): int {}

// since the last reset(): peak and completed count the THREADS (http_get and
// http_get_many, as the C twin does), errors the parallel children that threw
$peak = 0;
$completed = 0;
$errors = 0;

function parallel(callable $fn, mixed ...$args): array {
    global $errors;
    $n = count($args);
    if ($n === 0) throw new \ArgumentCountError('awaitable\parallel() expects at least 2 arguments, 1 given');
    if ($n > 64) throw new \TypeError('awaitable\parallel(): at most 64 jobs');
    $pids = [];
    $fds = [];
    foreach ($args as $i => $arg) {
        // a job that cannot start is -1 in ITS slot, answered as failed
        $pids[$i] = -1;
        $p = str_repeat("\0", 8);
        if (pipe($p) !== 0) continue;
        [$r, $w] = array_values(unpack('l2', $p));
        $k = fork();
        if ($k === 0) {
            c_close($r);
            _child($w, $fn, $arg);
        }
        c_close($w);
        if ($k < 0) { c_close($r); continue; }
        $pids[$i] = $k;
        $fds[$i] = $r;
    }
    $out = [];
    foreach ($args as $i => $arg) {
        $tag = '1';
        $body = '';
        if ($pids[$i] !== -1) {
            $all = _read_all($fds[$i], $pids[$i]);
            c_close($fds[$i]);
            // a signal handler installed without SA_RESTART makes a blocked
            // waitpid() return -1 (EINTR): it is asked again while the child
            // is still there -- running, or a zombie waiting for this call
            while (waitpid($pids[$i], str_repeat("\0", 8), 0) < 0 && c_kill($pids[$i], 0) === 0) {}
            if ($all !== '') { $tag = substr($all, 0, 1); $body = substr($all, 1); }
        }
        if ($tag === '0') {
            $v = $body === '' ? false : @unserialize($body);
            $out[] = $v === false && $body !== 'b:0;' ? null : $v;
        } else {
            $errors++;
            $out[] = $body === '' ? null : $body;
        }
    }
    return $out;
}

// the child: call, serialize, write '0' and the bytes -- or '1' and the message
// of what it threw -- and leave without running php's shutdown
function _child(int $w, callable $fn, mixed $arg): void {
    try {
        $s = '0' . serialize($fn($arg));
    } catch (\Throwable $e) {
        $s = '1' . $e->getMessage();
    }
    _write_all($w, $s);
    _exit(0);
}

function _write_all(int $fd, string $s): void {
    while ($s !== '') {
        $k = c_write($fd, $s, strlen($s));
        if ($k <= 0) return;
        $s = substr($s, $k);
    }
}

// to the end of the pipe: a -1 while the child is still there is a signal
// (EINTR, as above), and the pipe is ours, so nothing else fails there; the
// source has no errno to ask, and this asks the question errno would answer
function _read_all(int $fd, int $pid): string {
    $all = '';
    while (true) {
        $buf = str_repeat("\0", 65536);
        $k = c_read($fd, $buf, 65536);
        if ($k < 0 && c_kill($pid, 0) === 0) continue;
        if ($k <= 0) return $all;
        $all .= substr($buf, 0, $k);
    }
}

function peak(): int { global $peak; return $peak; }
function completed(): int { global $completed; return $completed; }
function errors(): int { global $errors; return $errors; }
function reset(): void { global $peak, $completed, $errors; $peak = 0; $completed = 0; $errors = 0; }

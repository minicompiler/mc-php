<?php
// tests/frankenphp.sh: a ZTS module under a threaded SAPI. Every request calls
// work($n) once and prints what it answered; tests/frankenphp.sh checks each
// answer against the formula below and counts the php threads the load
// landed on. What MINIT builds here -- a global array, an object, a static
// property, a constant -- every request starts from; what a request writes to
// them is its own, and a request on another thread at the same moment must
// never see it (lib/php_zts.mc, docs/threads.md § ZTS).
final class _Box {
    public static int $count = 0;
    public array $items = [];
    public function add(int $x): int { $this->items[] = $x; return count($this->items); }
}

$zts_g = ['a' => 1, 'list' => [1, 2]];
$zts_box = new _Box();
define('ZTS_K', 7);
// a top-level read of a name only a function's `global` creates, at MINIT:
// every request's copy of MINIT's globals carries what it read (7)
function zts_gset(): void { global $zts_only; $zts_only = 5; }
zts_gset();
$zts_top = $zts_only + 2;

// echoed, not returned: it has to pass through php's output layer on every
// php thread, into the ob_start() level index.php opened
function zts_say(int $n): void {
    echo "|", 3 * $n;
}

// a thread of the API (docs/threads.md § Step 3) started by a request shares
// THAT request's module state: it reads the global this request just wrote
function zts_shared(int $x): int { global $zts_g; return $x * 3 + (int) $zts_g['a']; }

// a static that only holds ints is a native slot (src/decl.mc, `phsi`): per
// php thread and put back to MINIT's at each request, like the zval one below
function zts_calls(): int { static $c = 0; $c++; return $c; }

// n|calls|a|list|count|items|K top|s|f|R|helper|boom:rev|api|thread
function work(int $n, callable $boom): string {
    global $zts_g, $zts_box, $zts_top;
    static $calls = 0;
    $calls++;
    // still 1 only when the native static started this request at 0 too
    $calls = $calls * zts_calls();
    $zts_g['a'] += $n;
    $zts_g['list'][] = $n;
    _Box::$count += 1;
    $k = $zts_box->add($n);
    $s = str_repeat(chr(97 + $n % 26), 3) . ":" . json_encode(['n' => $n]);
    try {
        if ($n % 2) throw new RuntimeException("odd $n");
        $s .= "!even";
    } catch (RuntimeException $e) {
        $s .= "!" . $e->getMessage();
    }
    $f = fn(int $x): int => $x * 2;
    if (!defined('ZTS_R')) define('ZTS_R', $n);
    $h = zts_helper($n);
    // php's engine called through a callable -- one that throws, and one of
    // php's own functions that does not: after each the module reads
    // EG(exception) at the offset THIS thread measured, and
    // MCPHP_ZTS_EGX_WRONG makes that offset wrong until the thread measures
    // it (a wrong one reads a pending exception where there is none)
    $rev = 'strrev';
    try { $boom($n); $b = "none"; } catch (LogicException $x) { $b = (string) $x->getMessage(); }
    $b = $b . ":" . (string) $rev("z$n");
    $tv = (int) mcphp_thread_join(mcphp_thread_start(fn(int $x): int => zts_shared($x), $n));
    return $n . "|" . $calls . "|" . $zts_g['a'] . "|" . count($zts_g['list']) . "|" . _Box::$count
        . "|" . $k . "|" . ZTS_K . $zts_top . "|" . $s . "|" . $f($n) . "|" . ZTS_R . "|" . $h . "|" . $b . "|" . $tv . "|" . mcphp_thread();
}
// threads step 3b under a threaded SAPI: a php callable on a thread of its
// own, started and joined by the module (tests/frankenphp.sh, threads.php)
function zts_pstart(callable $f, int $n): int { return mcphp_thread_start($f, $n); }
function zts_pjoin(int $t): mixed { return mcphp_thread_join($t); }
// step 6b: a COMPILED worker drives the event loop inside a request under the
// threaded SAPI (tests/frankenphp.sh, awio.php). The worker has no php engine,
// so it may suspend (docs/threads.md § 6): fibers await a timer and a
// non-blocking pipe read; at the worker's reap the loop is torn down and every
// fiber stack unmapped, so nothing leaks across requests. Returns $n + 7.
function zts_await_io(int $n): int {
    return (int) mcphp_thread_join(mcphp_thread_start(function (int $x): int {
        $f = mcphp_spawn(function (int $y): int { mcphp_await(mcphp_timer(1)); return $y + 1; }, $x);
        $p = mcphp_pipe();
        $rd = mcphp_spawn(function (int $fd): int { return strlen(mcphp_io_read($fd, 16)); }, $p >> 32);
        mcphp_fd_write($p & 0xffffffff, "hello");
        mcphp_loop_run();
        $r = (int) mcphp_await($f) + (int) mcphp_await($rd) + 1;
        mcphp_fd_close($p >> 32);
        mcphp_fd_close($p & 0xffffffff);
        return $r;
    }, $n));
}
// native sync (step 4) under a threaded SAPI (tests/frankenphp.sh, sync.php):
// an atomic made at MINIT is the process's and counts every request; a mutex
// and an atomic a request makes are freed at its end, so their slots are
// reused and the handles' indices stay small however many requests ran
$zts_sy_hits = mcphp_atomic(0);
function zts_sy_bump(int $m, int $a): int {
    mcphp_mutex_lock($m);
    $v = mcphp_atomic_load($a);
    mcphp_atomic_store($a, $v + 1);
    mcphp_mutex_unlock($m);
    return $v;
}
function zts_sync(int $n): string {
    global $zts_sy_hits;
    $m = mcphp_mutex();
    $a = mcphp_atomic($n);
    $t = mcphp_thread_start(fn(int $m, int $a): int => zts_sy_bump($m, $a), $m, $a);
    zts_sy_bump($m, $a);
    mcphp_thread_join($t);
    mcphp_atomic_add($zts_sy_hits, 1);
    return $n . "|" . mcphp_atomic_load($a) . "|" . max($m & 0x3FFFFF, $a & 0x3FFFFF);
}
function zts_sync_hits(): int { global $zts_sy_hits; return mcphp_atomic_load($zts_sy_hits); }

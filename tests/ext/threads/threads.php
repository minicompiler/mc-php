<?php
// tests/ext.sh step 20: a module whose compiled functions run on several OS
// threads at once (lib/php_rt.mc § other threads) -- strings, arrays, an
// object of the module's own class, exceptions thrown and caught inside.
// check.php compares the threads' sum with the same function called by php
// one thread at a time. mcphp_threads() is the runtime's own gate, not the
// public API (docs/threads.md).
namespace th;
final class _Acc {
    public int $n = 0;
    public array $seen = [];
    public function add(string $s): void { $this->n += strlen($s); $this->seen[] = $s; }
}
function work(int $iters, int $id): int {
    $sum = 0;
    for ($i = 0; $i < $iters; $i++) {
        $s = str_repeat(chr(97 + $id % 26), $i % 7 + 1) . ":" . $i;
        $a = [$i, $s, ['k' => $id, 'v' => substr($s, 1)]];
        $sum += count($a) + strlen($a[1]) + (int) $a[2]['k'] + strlen($a[2]['v']);
        $o = new _Acc();
        $o->add($s);
        $o->add(strtoupper($s));
        $sum += (int) $o->n + count($o->seen);
        try {
            if ($i % 5 == 0) throw new \RuntimeException("t$id-$i");
            $sum += 1;
        } catch (\RuntimeException $e) {
            $sum += strlen($e->getMessage());
        }
        $sum += json_encode(['i' => $i, 's' => $s]) === '{"i":' . $i . ',"s":"' . $s . '"}' ? 3 : 0;
    }
    return $sum;
}
function run(int $n, int $iters): int { return mcphp_threads('th\work', $n, $iters); }
// php's engine has one executor without ZTS: a worker that reaches for it --
// here a function only php knows -- gets the runtime's Error, not a crash.
function probe(int $x, int $id): int {
    try { return (int) \th_host($id); }
    catch (\Error $e) { return str_contains($e->getMessage(), 'another thread') ? 1 : 100; }
}
function guard(int $n): int { return mcphp_threads('th\probe', $n, 0); }

// The thread API (docs/threads.md § Step 3) on this road: compiled
// callables on native threads, their values kept after the join, a
// throwable rethrown at the join, and a php callable refused. api.php runs
// these, graded by tests/ext.sh step 20b against its recording.
function api(int $n, int $iters): int {
    $hs = [];
    for ($i = 0; $i < $n; $i++) $hs[] = mcphp_thread_start(fn(int $k, int $id): int => work($k, $id), $iters, $i);
    $sum = 0;
    foreach ($hs as $h) $sum += (int) mcphp_thread_join($h);
    return $sum;
}
$kept_s = "";
$kept_a = [];
$kept_o = new _Acc();
function keep_one(int $k): int {
    global $kept_s, $kept_a, $kept_o;
    $kept_s = str_repeat("k", $k);
    $kept_a = range(1, $k);
    $kept_o = new _Acc();
    $kept_o->add($kept_s);
    return 1;
}
function kept(): string { global $kept_s, $kept_a, $kept_o; return $kept_s . " " . count($kept_a) . " " . $kept_o->n; }
function keep(int $k): string {
    mcphp_thread_join(mcphp_thread_start(fn(int $x): int => keep_one($x), $k));
    return kept();
}
function keep_detached(int $k): string {
    mcphp_thread_detach(mcphp_thread_start(fn(int $x): int => keep_one($x), $k));
    while (mcphp_thread_running() > 0) usleep(1000);
    return kept();
}
function thrower(string $m): int { throw new \LogicException($m); }
function rethrow(): string {
    $h = mcphp_thread_start(fn(string $m): int => thrower($m), "from a thread");
    try {
        mcphp_thread_join($h);
        return "none";
    } catch (\LogicException $e) {
        return "caught " . $e->getMessage();
    }
}
function refuse(callable $f): string {
    try { mcphp_thread_start($f); return "started"; }
    catch (\Error $e) {
        // a ZTS php without opcache: what is not cached is named after the
        // refusal, a closure by its file's path -- cut, so the recording holds
        $m = $e->getMessage();
        $p = strpos($m, "; not cached: ");
        return $p === false ? $m : substr($m, 0, $p);
    }
}
// shared mode: the flag, and whether a fresh string would be written in place
function mode(): string { $s = str_repeat("m", 3); return mcphp_shared_mode() . " " . mcphp_str_mine($s); }
// a copy made for another thread is a distinct object, destructed once by
// the thread that owns it: the worker destructs its copy of the argument and
// what it made when it ends; the request's copies of the results are the
// request's (and a module's request end runs no destructor,
// docs/php-extension.md)
final class _D {
    public function __construct(public int $n) {}
    public function __destruct() { echo "dtor ", $this->n, "\n"; }
}
function d_peek(_D $d): int { return $d->n; }
function d_make(int $n): _D { return new _D($n); }
function d_pass(_D $d): _D { return $d; }
function dtors(): string {
    $a = new _D(1);
    $r1 = mcphp_thread_join(mcphp_thread_start(fn(_D $x): int => d_peek($x), $a));
    $r2 = mcphp_thread_join(mcphp_thread_start(fn(int $n): _D => d_make($n), 2));
    $r3 = mcphp_thread_join(mcphp_thread_start(fn(_D $x): _D => d_pass($x), $a));
    return $r1 . " " . $r2->n . " " . $r3->n . " " . (($r3 === $a) ? "same" : "distinct");
}
// a detached thread the request does not wait for itself: RSHUTDOWN does,
// so its line comes out before php ends
function late(int $ms): int { usleep($ms * 1000); echo "the detached thread finished inside the request\n"; return 1; }
function detach_late(int $ms): string {
    mcphp_thread_detach(mcphp_thread_start(fn(int $m): int => late($m), $ms));
    return "detached, running " . mcphp_thread_running();
}

// Threads step 3b (docs/threads.md § 3b): a PHP callable on a thread, which a
// ZTS php runs as a php request of its own. php.php runs these, graded by
// tests/ext.sh step 20c; an NTS php refuses every one of them.
function prun0(callable $f): mixed { return mcphp_thread_join(mcphp_thread_start($f)); }
function prun1(callable $f, mixed $a): mixed { return mcphp_thread_join(mcphp_thread_start($f, $a)); }
function prun2(callable $f, mixed $a, mixed $b): mixed { return mcphp_thread_join(mcphp_thread_start($f, $a, $b)); }
function pstart1(callable $f, mixed $a): int { return mcphp_thread_start($f, $a); }
function pstart3(callable $f, mixed $a, mixed $b, mixed $c): int { return mcphp_thread_start($f, $a, $b, $c); }
function pjoin(int $t): mixed { return mcphp_thread_join($t); }
function pdetach(int $t): void { mcphp_thread_detach($t); }
// one module global, written by a worker of each kind: a compiled worker
// writes the request's module state, a php worker the copy its own request
// started from
function gset(string $v): string { global $g3b; $g3b = $v; return $v; }
function gget(): string { global $g3b; return $g3b ?? "unset"; }
function gcompiled(string $v): string {
    mcphp_thread_join(mcphp_thread_start(fn(string $x): string => gset($x), $v));
    return gget();
}

// Native sync (docs/threads.md § Step 4). The builtins exist in compiled code
// only, so the module publishes what php calls: a wrapper per operation.
// api.php and php.php use them, graded by tests/ext.sh steps 20b and 20c.
function sy_mutex(): int { return mcphp_mutex(); }
function sy_lock(int $m): void { mcphp_mutex_lock($m); }
function sy_unlock(int $m): void { mcphp_mutex_unlock($m); }
function sy_atomic(int $v): int { return mcphp_atomic($v); }
function sy_add(int $a, int $d): int { return mcphp_atomic_add($a, $d); }
function sy_load(int $a): int { return mcphp_atomic_load($a); }
function sy_store(int $a, int $v): void { mcphp_atomic_store($a, $v); }
// made at MINIT: the process's, never freed; every request adds 1 to it
$sy_proc = mcphp_atomic(0);
function sy_hit(): int { global $sy_proc; return mcphp_atomic_add($sy_proc, 1) + 1; }
// four compiled threads, each adding 1 $n times to a module global under a
// mutex and to an atomic: both exact
$sy_n = 0;
function sy_bump(int $m, int $a, int $n): int {
    global $sy_n;
    for ($i = 0; $i < $n; $i++) {
        mcphp_mutex_lock($m);
        $sy_n = $sy_n + 1;
        mcphp_mutex_unlock($m);
        mcphp_atomic_add($a, 1);
    }
    return $n;
}
function sy_count(int $t, int $n): string {
    global $sy_n;
    $sy_n = 0;
    $m = mcphp_mutex();
    $a = mcphp_atomic(0);
    $hs = [];
    for ($i = 0; $i < $t; $i++) $hs[] = mcphp_thread_start(fn(int $m, int $a, int $n): int => sy_bump($m, $a, $n), $m, $a, $n);
    foreach ($hs as $h) mcphp_thread_join($h);
    return ($sy_n === $t * $n ? "exact" : "LOST") . " " . (mcphp_atomic_load($a) === $t * $n ? "exact" : "LOST");
}

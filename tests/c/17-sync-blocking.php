<?php
// Native sync, the blocking objects (docs/threads.md § Step 4): a semaphore, a
// wait group and a condition variable blocking across threads, and the
// timeouts. Graded by tests/fixtures.sh against 17-sync-blocking.out -- php has
// no such functions (mc-php's own, the C11/Go model). mcphp_now_ms is the
// runtime's monotonic clock, a test gate: usleep is a no-op in a compiled
// program, so a timeout is measured with the same clock it is built on.

// A wait group: main adds N, N workers each add 1 to an atomic and call done;
// main's wait() blocks until the counter reaches 0.
$N = 16;
$w = mcphp_waitgroup();
$a = mcphp_atomic(0);
mcphp_waitgroup_add($w, $N);
$hs = [];
for ($i = 0; $i < $N; $i++) $hs[] = mcphp_thread_start(fn(int $w, int $a): int => (function () use ($w, $a) { mcphp_atomic_add($a, 1); mcphp_waitgroup_done($w); return 0; })(), $w, $a);
$got = mcphp_waitgroup_wait($w);
foreach ($hs as $h) mcphp_thread_join($h);
echo "waitgroup: returned ", var_export($got, true), ", all ", mcphp_atomic_load($a) === $N ? "ran" : "MISSING", "\n";

// A semaphore as a handoff: a worker acquires an empty semaphore and blocks in
// the kernel; the main thread releases, and the worker proceeds. The outcome
// is the same whether the worker blocked first or the release came first, so
// it is deterministic. Then the bound: N permits taken, the next acquire with
// a 0 ms deadline fails.
$s = mcphp_semaphore(0);
$done = mcphp_atomic(0);
$t = mcphp_thread_start(fn(int $s, int $d): int => (function () use ($s, $d) { mcphp_semaphore_acquire($s); mcphp_atomic_store($d, 1); return 0; })(), $s, $done);
mcphp_semaphore_release($s);
mcphp_thread_join($t);
echo "semaphore handoff: worker ", mcphp_atomic_load($done) === 1 ? "ran after the release" : "STUCK", "\n";
$b = mcphp_semaphore(2);
echo "semaphore bound: ", var_export(mcphp_semaphore_acquire($b, 0), true), " ", var_export(mcphp_semaphore_acquire($b, 0), true), " ", var_export(mcphp_semaphore_acquire($b, 0), true), "\n";

// A condition variable: a bounded queue (capacity 4). The producer waits on
// `not full`, the consumer on `not empty`; every item is delivered once.
$qm = mcphp_mutex();
$notEmpty = mcphp_cond();
$notFull = mcphp_cond();
$head = mcphp_atomic(0);
$tail = mcphp_atomic(0);
$sum = mcphp_atomic(0);
$CAP = 4;
$ITEMS = 500;
$prod = function () use ($qm, $notEmpty, $notFull, $head, $tail, $CAP, $ITEMS): int {
    for ($k = 1; $k <= $ITEMS; $k++) {
        mcphp_mutex_lock($qm);
        while (mcphp_atomic_load($head) - mcphp_atomic_load($tail) >= $CAP) mcphp_cond_wait($notFull, $qm);
        mcphp_atomic_add($head, 1);
        mcphp_cond_signal($notEmpty);
        mcphp_mutex_unlock($qm);
    }
    return 0;
};
$cons = function () use ($qm, $notEmpty, $notFull, $head, $tail, $sum, $ITEMS): int {
    for ($k = 0; $k < $ITEMS; $k++) {
        mcphp_mutex_lock($qm);
        while (mcphp_atomic_load($head) - mcphp_atomic_load($tail) <= 0) mcphp_cond_wait($notEmpty, $qm);
        mcphp_atomic_add($tail, 1);
        mcphp_atomic_add($sum, 1);
        mcphp_cond_signal($notFull);
        mcphp_mutex_unlock($qm);
    }
    return 0;
};
$p = mcphp_thread_start($prod);
$c = mcphp_thread_start($cons);
mcphp_thread_join($p);
mcphp_thread_join($c);
echo "condvar: delivered ", mcphp_atomic_load($sum) === $ITEMS ? "all $ITEMS" : "WRONG " . mcphp_atomic_load($sum), ", queue empty ", (mcphp_atomic_load($head) === mcphp_atomic_load($tail)) ? "yes" : "no", "\n";

// A condition variable used to broadcast to many waiters: 8 threads wait for a
// gate flag, one thread sets it and broadcasts, all wake.
$gm = mcphp_mutex();
$gc = mcphp_cond();
$gate = mcphp_atomic(0);
$woke = mcphp_atomic(0);
$waiter = function () use ($gm, $gc, $gate, $woke): int {
    mcphp_mutex_lock($gm);
    while (mcphp_atomic_load($gate) === 0) mcphp_cond_wait($gc, $gm);
    mcphp_mutex_unlock($gm);
    mcphp_atomic_add($woke, 1);
    return 0;
};
$hs = [];
for ($i = 0; $i < 8; $i++) $hs[] = mcphp_thread_start($waiter);
mcphp_mutex_lock($gm);
mcphp_atomic_store($gate, 1);
mcphp_cond_broadcast($gc);
mcphp_mutex_unlock($gm);
foreach ($hs as $h) mcphp_thread_join($h);
echo "broadcast: ", mcphp_atomic_load($woke) === 8 ? "all 8 woke" : "ONLY " . mcphp_atomic_load($woke), "\n";

// The timeouts: an empty semaphore, a condition nobody signals, and a
// waitgroup that never reaches 0 -- each returns false, and the semaphore and
// condition waits take at least the timeout.
$e = mcphp_semaphore(0);
$t0 = mcphp_now_ms();
$r1 = mcphp_semaphore_acquire($e, 0);
$r2 = mcphp_semaphore_acquire($e, 40);
$el = mcphp_now_ms() - $t0;
echo "semaphore timeout: ", var_export($r1, true), " ", var_export($r2, true), ", waited >= 40ms ", $el >= 39 ? "yes" : "no ($el)", "\n";
$wm = mcphp_mutex();
$wc = mcphp_cond();
mcphp_mutex_lock($wm);
$t0 = mcphp_now_ms();
$r = mcphp_cond_wait($wc, $wm, 40);
$el = mcphp_now_ms() - $t0;
mcphp_mutex_unlock($wm);
echo "cond timeout: ", var_export($r, true), ", mutex reacquired, waited >= 40ms ", $el >= 39 ? "yes" : "no ($el)", "\n";
$ew = mcphp_waitgroup();
mcphp_waitgroup_add($ew, 1);
echo "waitgroup timeout: ", var_export(mcphp_waitgroup_wait($ew, 20), true), "\n";
echo "done\n";

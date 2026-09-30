<?php
// examples/sync -- native sync (threads step 4) on the program road: a bounded
// producer/consumer queue guarded by a mutex and two condition variables, the
// producers gated by a semaphore and awaited with a wait group, the checksum
// an atomic. Compiled with `mc-php --exe sync.php -o sync`, it prints one line
// and c/sync.c is the same workload in C (pthreads + C11); tests/examples.sh
// runs both, checks the checksums match and prints the ratio.
//
// The "queue" is a bounded count (head - tail): the i-th item consumed is item
// i, worth i + 1, so the checksum is T*(T+1)/2 for T = PRODUCERS * ITEMS -- a
// number both programs must reach exactly. No data crosses a thread; the
// synchronisation is the whole point.
$PRODUCERS = 4;
$CONSUMERS = 4;
$ITEMS = 100000;
$CAP = 16;
$PERMITS = 2;                 // at most this many producers producing at once
$T = $PRODUCERS * $ITEMS;

$mtx = mcphp_mutex();
$notEmpty = mcphp_cond();
$notFull = mcphp_cond();
$sem = mcphp_semaphore($PERMITS);
$wg = mcphp_waitgroup();
$head = mcphp_atomic(0);      // items pushed
$tail = mcphp_atomic(0);      // items popped
$done = mcphp_atomic(0);      // 1 once every producer has finished
$sum = mcphp_atomic(0);

$producer = function () use ($mtx, $notEmpty, $notFull, $sem, $wg, $head, $tail, $CAP, $ITEMS): int {
    mcphp_semaphore_acquire($sem);
    for ($k = 0; $k < $ITEMS; $k++) {
        mcphp_mutex_lock($mtx);
        while (mcphp_atomic_load($head) - mcphp_atomic_load($tail) >= $CAP) mcphp_cond_wait($notFull, $mtx);
        mcphp_atomic_add($head, 1);
        mcphp_cond_signal($notEmpty);
        mcphp_mutex_unlock($mtx);
    }
    mcphp_semaphore_release($sem);
    mcphp_waitgroup_done($wg);
    return 0;
};
$consumer = function () use ($mtx, $notEmpty, $notFull, $head, $tail, $done, $sum): int {
    for (;;) {
        mcphp_mutex_lock($mtx);
        while (mcphp_atomic_load($head) - mcphp_atomic_load($tail) <= 0 && mcphp_atomic_load($done) === 0) mcphp_cond_wait($notEmpty, $mtx);
        if (mcphp_atomic_load($head) - mcphp_atomic_load($tail) <= 0) { mcphp_mutex_unlock($mtx); break; }
        $i = mcphp_atomic_load($tail);
        mcphp_atomic_add($tail, 1);
        mcphp_cond_signal($notFull);
        mcphp_mutex_unlock($mtx);
        mcphp_atomic_add($sum, $i + 1);
    }
    return 0;
};

mcphp_waitgroup_add($wg, $PRODUCERS);
$ph = [];
for ($i = 0; $i < $PRODUCERS; $i++) $ph[] = mcphp_thread_start($producer);
$ch = [];
for ($i = 0; $i < $CONSUMERS; $i++) $ch[] = mcphp_thread_start($consumer);

// wait for the producers, then tell the consumers no more is coming and wake
// every one of them (some may be asleep on an empty queue)
mcphp_waitgroup_wait($wg);
mcphp_mutex_lock($mtx);
mcphp_atomic_store($done, 1);
mcphp_cond_broadcast($notEmpty);
mcphp_mutex_unlock($mtx);

foreach ($ph as $h) mcphp_thread_join($h);
foreach ($ch as $h) mcphp_thread_join($h);

$expected = intdiv($T * ($T + 1), 2);
echo "checksum ", mcphp_atomic_load($sum), " expected ", $expected, " ", mcphp_atomic_load($sum) === $expected ? "ok" : "MISMATCH", "\n";

<?php
// The runtime's own lock under contention (docs/threads.md § Step 4): since
// step 4 it is a word and the atomic words, not a pthread mutex or an
// SRWLOCK, and the thread table, the records and the kept arenas all go
// through it. Eight starter threads each start and join 1250 short threads
// at once -- ten thousand in all, eight at a time taking the lock to publish,
// join and reap -- and every short thread adds 1 to an atomic. Graded by
// tests/fixtures.sh against 16-thread-churn.out.
function starter(int $a, int $n): int {
    $done = 0;
    for ($i = 0; $i < $n; $i++) {
        $h = mcphp_thread_start(fn(int $a): int => mcphp_atomic_add($a, 1), $a);
        mcphp_thread_join($h);
        $done++;
    }
    return $done;
}
$a = mcphp_atomic();
$hs = [];
for ($t = 0; $t < 8; $t++) $hs[] = mcphp_thread_start(fn(int $a): int => starter($a, 1250), $a);
$joined = 0;
foreach ($hs as $h) $joined += (int) mcphp_thread_join($h);
echo "short threads joined: $joined, counted: ", mcphp_atomic_load($a), "\n";
echo "running at the end: ", mcphp_thread_running(), "\n";

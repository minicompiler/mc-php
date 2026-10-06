<?php
// Step 6b self-test (docs/threads.md § Step 6b): a worker on ANOTHER thread
// completes a future the main thread awaits. The completion is routed to the
// main loop's cross-thread queue, the loop is woken out of ph_ev_wait by its
// self-wake (eventfd/self-pipe on POSIX, PostQueuedCompletionStatus on IOCP),
// and the value is deep-copied across arenas (php_tc_*), since the producer and
// the waiter are different threads with different arenas. Program road, no php
// engine on the fiber. Graded against 21-xthread.out.

// a worker completes the future with a string value
$f = mcphp_future();
$w = mcphp_thread_start(function (int $h): int {
    mcphp_future_complete($h, "from the worker");
    return 0;
}, $f);
echo "xthread value: ", mcphp_await($f), "\n";
mcphp_thread_join($w);

// a worker FAILS the future with a throwable; await rethrows it
$g = mcphp_future();
$w2 = mcphp_thread_start(function (int $h): int {
    mcphp_future_fail($h, new RuntimeException("worker boom"));
    return 0;
}, $g);
try {
    mcphp_await($g);
    echo "no throw\n";
} catch (\Throwable $e) {
    echo "xthread fail caught: ", $e->getMessage(), "\n";
}
mcphp_thread_join($w2);

// a nested array crosses the thread boundary: the deep copy, not an alias
$a = mcphp_future();
$w3 = mcphp_thread_start(function (int $h): int {
    mcphp_future_complete($h, ["a" => 1, "b" => [2, 3]]);
    return 0;
}, $a);
$r = mcphp_await($a);
echo "xthread array: ", $r["a"], " ", $r["b"][0], " ", $r["b"][1], "\n";
mcphp_thread_join($w3);

echo "done\n";

<?php
// Step 5, condition 2 (docs/threads.md § Step 5): outstanding awaits have a
// documented ceiling (PH_FIB_MAX live fiber stacks per loop). Past it, spawn is
// a NAMED refusal, not a crash. Each spawned fiber here parks forever (its
// future is never completed) so the stacks stay live; the ceiling-th+1 spawn
// throws, which this program catches.
$park = function (): int { mcphp_await(mcphp_future()); return 0; };
$n = 0;
try {
    while (true) { mcphp_spawn($park); $n = $n + 1; }
} catch (\Throwable $e) {
    echo "spawned ", $n, ", then: ", $e->getMessage(), "\n";
}

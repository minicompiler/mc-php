<?php
// Native sync (docs/threads.md § Step 4): mcphp_mutex* and mcphp_atomic*,
// int handles into the runtime's table. Graded by tests/fixtures.sh against
// 15-sync.out -- php has no such functions (mc-php's own, the C11 model).
//
// Eight threads each add 1 twenty thousand times, four ways: a global int
// under a mutex (a read, an add and a store that only the lock makes whole),
// an atomic add, a compare-and-swap retry loop, and a spin lock built from
// xchg. Every count must be exact; then every refusal, by name.

$T = 8;
$N = 20000;
$m = mcphp_mutex();
$a = mcphp_atomic();
$c = mcphp_atomic(0);
$spin = mcphp_atomic(0);
$counted = 0;
$spun = 0;

function under_mutex(int $m, int $n): int {
    global $counted;
    for ($i = 0; $i < $n; $i++) {
        mcphp_mutex_lock($m);
        $counted = $counted + 1;
        mcphp_mutex_unlock($m);
    }
    return $n;
}
function by_add(int $a, int $n): int {
    for ($i = 0; $i < $n; $i++) mcphp_atomic_add($a, 1);
    return $n;
}
function by_cas(int $a, int $n): int {
    $retries = 0;
    for ($i = 0; $i < $n; $i++) {
        while (true) {
            $v = mcphp_atomic_load($a);
            if (mcphp_atomic_cas($a, $v, $v + 1)) break;
            $retries++;
        }
    }
    return $retries;
}
function by_spin(int $s, int $n): int {
    global $spun;
    for ($i = 0; $i < $n; $i++) {
        while (mcphp_atomic_xchg($s, 1) !== 0) {}
        $spun = $spun + 1;
        mcphp_atomic_store($s, 0);
    }
    return $n;
}

$hs = [];
for ($t = 0; $t < $T; $t++) {
    $hs[] = mcphp_thread_start(fn(int $m, int $n): int => under_mutex($m, $n), $m, $N);
    $hs[] = mcphp_thread_start(fn(int $a, int $n): int => by_add($a, $n), $a, $N);
    $hs[] = mcphp_thread_start(fn(int $a, int $n): int => by_cas($a, $n), $c, $N);
    $hs[] = mcphp_thread_start(fn(int $s, int $n): int => by_spin($s, $n), $spin, $N);
}
foreach ($hs as $h) mcphp_thread_join($h);
$want = $T * $N;
echo "under a mutex: ", $counted === $want ? "exact" : "LOST " . ($want - $counted), "\n";
echo "atomic add:    ", mcphp_atomic_load($a) === $want ? "exact" : "LOST", "\n";
echo "cas loop:      ", mcphp_atomic_load($c) === $want ? "exact" : "LOST", "\n";
echo "xchg spin:     ", $spun === $want ? "exact" : "LOST", "\n";

// the values: add and xchg answer the value before, cas whether it swapped
$x = mcphp_atomic(40);
echo "add: ", mcphp_atomic_add($x, 2), " then ", mcphp_atomic_load($x), "\n";
echo "cas: ", var_export(mcphp_atomic_cas($x, 42, 7), true), " ", var_export(mcphp_atomic_cas($x, 42, 8), true), " -> ", mcphp_atomic_load($x), "\n";
echo "xchg: ", mcphp_atomic_xchg($x, -5), " then ", mcphp_atomic_load($x), "\n";
mcphp_atomic_store($x, PHP_INT_MAX);
echo "store and wrap: ", mcphp_atomic_add($x, 1) === PHP_INT_MAX && mcphp_atomic_load($x) === PHP_INT_MIN ? "yes" : "no", "\n";

// trylock: false while another thread holds it, false for the holder itself
mcphp_mutex_lock($m);
$t = mcphp_thread_start(fn(int $m): bool => mcphp_mutex_trylock($m), $m);
echo "trylock from another thread while held: ", var_export(mcphp_thread_join($t), true), "\n";
echo "trylock by the holder: ", var_export(mcphp_mutex_trylock($m), true), "\n";
// a waiter sleeps until the holder lets go
$t = mcphp_thread_start(function (int $m, int $a): int { mcphp_mutex_lock($m); $v = mcphp_atomic_load($a); mcphp_mutex_unlock($m); return $v; }, $m, $x);
usleep(20000);
mcphp_atomic_store($x, 1234);
mcphp_mutex_unlock($m);
echo "the waiter saw what was written before the unlock: ", mcphp_thread_join($t), "\n";

// the refusals
function refused(callable $f): void {
    try { $f(); echo "no refusal\n"; } catch (Error $e) { echo get_class($e), ": ", $e->getMessage(), "\n"; }
}
mcphp_mutex_lock($m);
refused(fn() => mcphp_mutex_lock($m));
$t = mcphp_thread_start(fn(int $m): int => mcphp_mutex_unlock($m) ?? 0, $m);
refused(fn() => mcphp_thread_join($t));
mcphp_mutex_unlock($m);
refused(fn() => mcphp_mutex_unlock($m));
refused(fn() => mcphp_atomic_load($m));
refused(fn() => mcphp_mutex_lock($x));
refused(fn() => mcphp_mutex_trylock(0));
refused(fn() => mcphp_atomic_add(999999, 1));
refused(fn() => mcphp_atomic_store(-3, 1));
// a handle with another generation's bits names no live object
refused(fn() => mcphp_atomic_load($x + (1 << 22)));
echo "the mutex still works: ", var_export(mcphp_mutex_trylock($m), true), "\n";
mcphp_mutex_unlock($m);

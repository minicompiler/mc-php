<?php
// The thread API (docs/threads.md § Step 3): mcphp_thread_start with a
// callable and arguments, join returning the result or rethrowing what the
// thread threw, detach, the running count and the hardware concurrency --
// graded by tests/fixtures.sh against 11-thread-api.out: php has no such
// functions (mc-php's own, the std::thread model).
final class Box {
    public array $items = [];
    public function __construct(public int $n) {}
}

function square(int $x): int { return $x * $x; }

// arguments go by value: the thread's array and object are its own copies
function touch(array $a, Box $b): array {
    $a[] = 99;
    $b->n = 1000;
    $b->items[] = 'thread';
    return [count($a), $b->n, count($b->items)];
}

function boom(string $m): void { throw new DomainException($m, 7); }

// module state is ONE copy, as in C: a value a thread stores outlives it
function publish(int $k): int {
    global $gs, $ga, $go;
    $gs = str_repeat('s', $k);
    $ga = ['k' => $k, 'list' => range(1, $k)];
    $go = new Box($k);
    $go->items[] = "from a thread";
    return 1;
}

function nested(int $n): int {
    $hs = [];
    for ($i = 0; $i < $n; $i++) $hs[] = mcphp_thread_start(fn(int $x): int => square($x), $i + 1);
    $sum = 0;
    foreach ($hs as $h) $sum += (int) mcphp_thread_join($h);
    return $sum;
}

// the globals a thread writes, made here first (a top-level variable only
// `global` creates is not bound here yet: a separate, pre-existing gap)
$gs = "";
$ga = [];
$go = new Box(0);

echo "hardware concurrency at least 1: ", mcphp_hardware_concurrency() >= 1 ? "yes" : "no", "\n";
echo "running before any thread: ", mcphp_thread_running(), "\n";
echo "shared mode before any thread: ", mcphp_shared_mode(), "\n";

$t = mcphp_thread_start(fn(int $x): int => square($x), 12);
echo "square(12) on a thread: ", mcphp_thread_join($t), "\n";

$k = 5;
$t = mcphp_thread_start(fn(int $x): int => $x + $k, 37);
echo "a closure's capture: ", mcphp_thread_join($t), "\n";

$a = [1, 2, 3];
$b = new Box(1);
$t = mcphp_thread_start(fn(array $x, Box $y): array => touch($x, $y), $a, $b);
echo "the thread's copies: ", implode(",", mcphp_thread_join($t)), "; ours: ", count($a), " ", $b->n, " ", count($b->items), "\n";

$t = mcphp_thread_start(function (string $m) { boom($m); }, "from the thread");
try {
    mcphp_thread_join($t);
    echo "no exception\n";
} catch (DomainException $e) {
    echo "rethrown at join: ", get_class($e), " ", $e->getMessage(), " ", $e->getCode(), "\n";
}

try { mcphp_thread_join($t); } catch (Error $e) { echo $e->getMessage(), "\n"; }
try { mcphp_thread_join(12345); } catch (Error $e) { echo $e->getMessage(), "\n"; }

$t = mcphp_thread_start(fn(int $k): int => publish($k), 4);
mcphp_thread_join($t);
echo "what a joined thread stored: ", $gs, " ", $ga['k'], " ", count($ga['list']), " ", $go->n, " ", $go->items[0], "\n";

$gs = "";
$t = mcphp_thread_start(fn(int $k): int => publish($k), 6);
mcphp_thread_detach($t);
try { mcphp_thread_join($t); } catch (Error $e) { echo "join after detach: ", $e->getMessage(), "\n"; }
while (mcphp_thread_running() > 0) usleep(1000);
echo "what a detached thread stored: ", $gs, " ", $ga['k'], " ", count($ga['list']), " ", $go->n, "\n";

echo "threads of threads: ", mcphp_thread_join(mcphp_thread_start(fn(int $n): int => nested($n), 4)), "\n";
echo "running at the end: ", mcphp_thread_running(), "\n";
// sticky: counts may have raced, so it stays on after the last join
echo "shared mode after the last join: ", mcphp_shared_mode(), "\n";

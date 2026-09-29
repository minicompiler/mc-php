<?php
// Compiled code on several OS threads at once (lib/php_rt.mc § the thread
// block, § other threads): strings, arrays, objects of the program's own
// class and exceptions thrown and caught inside, each thread in its own
// arena, in rounds. Every thread's answer is checked against the same
// function run on this thread alone. mcphp_threads() is the runtime's own
// gate of its threads, not the public API (docs/threads.md); graded by
// tests/fixtures.sh against 09-threads.out -- php has no such function.
final class Acc {
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
        $o = new Acc();
        $o->add($s);
        $o->add(strtoupper($s));
        $sum += (int) $o->n + count($o->seen);
        try {
            if ($i % 5 == 0) throw new RuntimeException("t$id-$i");
            $sum += 1;
        } catch (RuntimeException $e) {
            $sum += strlen($e->getMessage());
        }
        $sum += json_encode(['i' => $i, 's' => $s]) === '{"i":' . $i . ',"s":"' . $s . '"}' ? 3 : 0;
        $sum += (int) array_sum(array_map(fn($x) => $x * 2, [$i % 3, $id]));
    }
    return $sum;
}

// A `global` or a `static` is the program's state, one table for every
// thread: another thread gets an Error instead of racing it.
function g_in(): int { global $g; return (int) $g; }
function s_in(): int { static $c = 0; $c++; return 7; }
function shared(int $x, int $id): int {
    $k = 0;
    foreach ([1, 2] as $w) {
        try { $k += $w == 1 ? g_in() : s_in(); }
        catch (Error $e) { $k += str_contains($e->getMessage(), 'shared by every thread') ? 1 : 1000; }
    }
    return $k;
}

// A thread that starts threads of its own: its three answer work() as the
// booting thread's would, and the fast path stays off until all are joined
// (lib/php_rt.mc's ph_thr_check dies otherwise).
function nest(int $iters, int $id): int { return mcphp_threads('work', 3, $iters); }
function one(int $x, int $id): int { return $x + $id; }

$g = 5;
$n = 8;
$iters = 400;
$want = 0;
for ($t = 0; $t < $n; $t++) $want += work($iters, $t);
for ($round = 0; $round < 5; $round++) {
    $got = mcphp_threads('work', $n, $iters);
    echo "round $round: ", $got === $want ? "the $n threads agree" : "MISMATCH $got / $want", "\n";
}
echo "and this thread still works: ", work(10, 3) === work(10, 3) ? "yes" : "no", "\n";
echo "module state from this thread: ", shared(0, 0), ", from 4 others: ", mcphp_threads('shared', 4, 0), "\n";
$w3 = work(60, 0) + work(60, 1) + work(60, 2);
for ($round = 0; $round < 3; $round++)
    echo "nested round $round: ", mcphp_threads('nest', 4, 60) === 4 * $w3 ? "4 threads of 3 agree" : "MISMATCH", "\n";
$ok = 0;
for ($i = 0; $i < 1500; $i++) $ok += mcphp_threads('one', 1, $i) === $i ? 1 : 0;
echo "1500 runs one after another: $ok answered\n";
echo "and this thread after them: ", work(10, 3) === work(10, 3) ? "yes" : "no", "\n";

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

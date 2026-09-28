<?php
// The bench row: a call-heavy workload THROUGH B INTO A. One process times
// one of the three -- the function names are the same, so two cannot be in
// one php -- with a warm-up and the best of nine, which is
// examples/decimal/bench.php's shape; tests/examples.sh runs the processes
// interleaved, three times each, and divides the minimums.
//
//     php -d extension=build/extA.so -d extension=build/extB.so bench.php   # compiled
//     php -d extension=a.so -d extension=b.so bench.php c                   # the C twins (c/)
//     php bench.php                                                         # interpreted
//
// Two rows: `b_use` 100 000 times, each one a call from php into B and from B
// into A through php's function table; and `a_add` 100 000 times straight from
// php, which is the same work without the hop. The difference between them is
// what calling a function the module does not link to costs.
declare(strict_types=1);

$mode = $argv[1] ?? 'compiled';
if (!extension_loaded('extA')) { require __DIR__ . '/extA.php'; $mode = 'interpreted'; }
if (!extension_loaded('extB')) { require __DIR__ . '/extB.php'; $mode = 'interpreted'; }

function through_b(int $n): int {
    $s = 0;
    for ($i = 0; $i < $n; $i++) { $s = b_use($s, $i) & 0xffffff; }
    return $s;
}

function direct_a(int $n): int {
    $s = 0;
    for ($i = 0; $i < $n; $i++) { $s = a_add($s, $i) & 0xffffff; }
    return $s;
}

function best(callable $f, int $n): array {
    $answer = $f($n);
    $best = INF;
    for ($i = 0; $i < 9; $i++) {
        $t = hrtime(true);
        $r = $f($n);
        $d = (hrtime(true) - $t) / 1e6;
        if ($r !== $answer) { echo "MISMATCH between runs\n"; exit(1); }
        if ($d < $best) { $best = $d; }
    }
    return [$best, $answer];
}

[$tb, $ab] = best('through_b', 100000);
[$ta, $aa] = best('direct_a', 100000);
printf("%s %.3f %.3f %d %d\n", $mode, $tb, $ta, $ab, $aa);

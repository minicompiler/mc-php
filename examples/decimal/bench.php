<?php
// The bench row: the same workload over decimal.so and over decimal.php.
// One process times ONE of the two -- the function names are the same, so
// both cannot be in one php -- with a warm-up and the best of nine, which is
// reference/bench-steady.php's shape; tests/examples.sh runs the two
// processes interleaved, three times each, and divides the minimums.
//
//     php -d extension=build/decimal.so bench.php     # compiled
//     php -d extension=c-twin.so bench.php c          # the C twin (c/)
//     php bench.php                                   # interpreted
//
// The workload is three ten-year loan schedules: each month's interest is
// rounded to the cent and paid off against a fixed instalment. ~1500 calls a
// run.
declare(strict_types=1);

$mode = $argv[1] ?? 'compiled';
if (!extension_loaded('decimal')) {
    require __DIR__ . '/decimal.php';
    $mode = 'interpreted';
}

function schedule(string $principal, string $yearly, string $pay): string {
    $rate = dec_div($yearly, '1200', 12);
    $bal = $principal;
    $paid = '0';
    for ($m = 0; $m < 120 && dec_cmp($bal, '0') > 0; $m++) {
        $interest = dec_mul($bal, $rate, 2);
        $bal = dec_sub(dec_add($bal, $interest, 2), $pay, 2);
        $paid = dec_add($paid, $interest, 2);
    }
    return "$bal/$paid";
}

function work(): string {
    return schedule('250000.00', '5.25', '2682.24') . ' ' .
           schedule('18000.00', '11.9', '257.99') . ' ' .
           schedule('1000000.00', '3.10', '9767.13');
}

$answer = work();
$best = INF;
for ($i = 0; $i < 9; $i++) {
    $t = hrtime(true);
    $r = work();
    $d = (hrtime(true) - $t) / 1e6;
    if ($r !== $answer) { echo "MISMATCH between runs\n"; exit(1); }
    if ($d < $best) { $best = $d; }
}
printf("%s %.3f %s\n", $mode, $best, $answer);

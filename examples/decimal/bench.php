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
// run. With MCPHP_EACH=1 it instead prints `mode` then one `fn ms` line per
// function (bench_each below).
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

// ---- per-function micro-benches (MCPHP_EACH=1) ------------------------------
// One `fn ms` line per function, the best of nine over 20000 calls each, on
// money-sized inputs like the schedule's -- the per-function steady state the
// README's module/C table is read from (each < 2.0 being the DONE rule), the
// same shape as examples/bcmath/bench.php's.
function bench_each(): void {
    $best = static function (callable $f): float {
        $b = INF;
        for ($r = 0; $r < 9; $r++) {
            $t = hrtime(true);
            $f();
            $d = (hrtime(true) - $t) / 1e6;
            if ($d < $b) { $b = $d; }
        }
        return $b;
    };
    $reps = 20000;
    $fns = [
        'add'   => fn() => dec_add('123456.78', '1093.75', 2),
        'sub'   => fn() => dec_sub('123456.78', '2682.24', 2),
        'mul'   => fn() => dec_mul('123456.78', '0.004375', 2),
        'div'   => fn() => dec_div('5.25', '1200', 12),
        'cmp'   => fn() => dec_cmp('123456.78', '123456.79'),
        'round' => fn() => dec_round('123456.785', 2),
    ];
    foreach ($fns as $name => $op) {
        $ms = $best(function () use ($op, $reps) { for ($i = 0; $i < $reps; $i++) { $op(); } });
        printf("%s %.3f\n", $name, $ms);
    }
}

if (getenv('MCPHP_EACH') === '1') {
    echo "$mode\n";
    bench_each();
    exit(0);
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

<?php
// The bench. The same workload over bcmath_port.so, over bcmath.php and over
// the C twin -- the function names are the same, so each runs in its own
// process. tests/examples.sh runs the three interleaved and divides minimums;
// DONE is module/C < 2.0 (README.md).
//
//     php -d extension=build/bcmath_port.so bench.php     # compiled
//     php -d extension=c-twin.so bench.php c              # the C twin (c/)
//     php bench.php                                       # interpreted
//
// By default it prints one line, `mode total answer`, a mixed workload that
// amortizes every function (a loan schedule in bcmath truncation, plus a few
// powers and roots). With MCPHP_EACH=1 it instead prints `mode` then one
// `fn ms` line per function -- the per-function steady-state numbers the
// README's module/C table is read from, each < 2.0 being the DONE rule.
declare(strict_types=1);

$mode = $argv[1] ?? 'compiled';
if (!extension_loaded('bcmath_port')) {
    require __DIR__ . '/bcmath.php';
    $mode = 'interpreted';
}

// ---- the mixed workload: ~1800 bc calls a run -------------------------------
function schedule(string $principal, string $yearly, string $pay): string {
    $rate = bc_div($yearly, '1200', 10);
    $bal = $principal;
    $paid = '0';
    for ($m = 0; $m < 120 && bc_comp($bal, '0', 2) > 0; $m++) {
        $interest = bc_mul($bal, $rate, 2);
        $bal = bc_sub(bc_add($bal, $interest, 2), $pay, 2);
        $paid = bc_add($paid, $interest, 2);
    }
    return "$bal/$paid";
}

function mixed(): string {
    $s = schedule('250000.00', '5.25', '2682.24') . ' ' .
         schedule('18000.00', '11.9', '257.99') . ' ' .
         schedule('1000000.00', '3.10', '9767.13');
    // a batch of the other operations on the same kind of numbers
    $acc = '0';
    for ($i = 1; $i <= 40; $i++) {
        $n = (string) ($i * 7);
        $acc = bc_add($acc, bc_pow('1.01', (string) ($i % 12), 6), 6);
        $acc = bc_add($acc, bc_mod($n . '.50', '3.1', 2), 2);
        $acc = bc_add($acc, bc_sqrt($n . '.0', 4), 4);
    }
    return "$s $acc";
}

// ---- per-function micro-benches (MCPHP_EACH=1) ------------------------------
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
    // inputs chosen to look like real bcmath use: money-sized decimals
    $reps = 20000;
    $fns = [
        'add'    => fn() => bc_add('123456.78', '1093.75', 2),
        'sub'    => fn() => bc_sub('123456.78', '2682.24', 2),
        'mul'    => fn() => bc_mul('123456.78', '0.004375', 2),
        'div'    => fn() => bc_div('5.25', '1200', 10),
        'mod'    => fn() => bc_mod('123456.78', '3.10', 2),
        'pow'    => fn() => bc_pow('1.01', '12', 6),
        'powmod' => fn() => bc_powmod('1234', '45', '1000000', 0),
        'sqrt'   => fn() => bc_sqrt('152.2756', 4),
        'comp'   => fn() => bc_comp('123456.78', '123456.79', 2),
        'floor'  => fn() => bc_floor('123456.78'),
        'ceil'   => fn() => bc_ceil('123456.78'),
        'round'  => fn() => bc_round('123456.785', 2),
        'scale'  => fn() => bc_scale(2),
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

$answer = mixed();
$best = INF;
for ($i = 0; $i < 9; $i++) {
    $t = hrtime(true);
    $r = mixed();
    $d = (hrtime(true) - $t) / 1e6;
    if ($r !== $answer) { echo "MISMATCH between runs\n"; exit(1); }
    if ($d < $best) { $best = $d; }
}
printf("%s %.3f %s\n", $mode, $best, $answer);

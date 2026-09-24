<?php
// The differential driver: run TWICE -- once with decimal.so loaded, once with
// decimal.php required -- and the two runs must print the same bytes. It must
// not print anything that can tell the two apart for a legitimate reason,
// which is why extension_loaded() guards the require and is never printed.
declare(strict_types=1);

if (!extension_loaded('decimal')) {
    require __DIR__ . '/decimal.php';
}

// the four operations, and a scale that pads or rounds
$pairs = [
    ['1.5', '2.25'], ['-1', '1'], ['0.1', '0.2'], ['-0.001', '0'], ['+7', '-3.5'],
    ['123456789012345678901234567890.123', '987654321.987654321'],
    ['0', '-0.000'], ['99.999', '0.001'], ['-12.5', '-12.5'],
];
foreach ($pairs as [$a, $b]) {
    foreach ([0, 2, 5] as $s) {
        echo "$a $b $s: ", dec_add($a, $b, $s), " ", dec_sub($a, $b, $s), " ",
             dec_mul($a, $b, $s), " ", dec_cmp($a, $b), "\n";
    }
}

// division, rounded half-even: every tie is here, in both signs
foreach ([['1', '3', 10], ['2', '3', 4], ['1', '8', 2], ['3', '8', 2], ['-1', '8', 2],
          ['-3', '8', 2], ['5', '2', 0], ['7', '2', 0], ['-5', '2', 0], ['1', '7', 30],
          ['10', '0.3', 3], ['1.21', '1.1', 1], ['123456789012345678901234567890', '98765432109876543210.5', 10],
          ['0', '-3', 2]] as [$a, $b, $s]) {
    echo "div $a $b $s: ", dec_div($a, $b, $s), "\n";
}

// rounding alone: the tie goes to the even digit, anything past it rounds up
foreach (['0.125', '0.135', '0.1250001', '-2.5', '-3.5', '2.5', '99.995', '-0.005', '0.0049', '1'] as $a) {
    echo "round $a: ", dec_round($a, 0), " ", dec_round($a, 2), " ", dec_round($a, 4), "\n";
}

// a small ledger: exact where a float is not
$total = '0';
foreach (['0.10', '0.20', '0.30', '19.99', '-5.01', '1000000.01'] as $x) { $total = dec_add($total, $x, 2); }
echo "ledger: $total\n";
$fl = 0.0;
foreach ([0.10, 0.20, 0.30] as $x) { $fl += $x; }
echo "float says 0.1+0.2+0.3 == 0.6: ", var_export($fl == 0.6, true), "; decimal says ",
     dec_cmp(dec_add(dec_add('0.1', '0.2', 1), '0.3', 1), '0.6'), "\n";

// what a wrong VALUE says. A wrong TYPE is an internal function's message in
// the module and a userland one interpreted (README.md), so it is not here.
foreach ([fn() => dec_add('1.', '2', 2), fn() => dec_add('1', 'x', 2), fn() => dec_mul('', '2', 2),
          fn() => dec_cmp('1', '--2'), fn() => dec_round('1', -1), fn() => dec_div('1', '0.00', 2),
          fn() => dec_sub('.5', '1', 1)] as $f) {
    try {
        echo $f(), "\n";
    } catch (Throwable $e) {
        echo get_class($e), ": ", $e->getMessage(), "\n";
    }
}

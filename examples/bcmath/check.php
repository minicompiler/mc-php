<?php
// The differential driver: run TWICE -- once with bcmath_port.so loaded, once
// with bcmath.php required -- and the two runs must print the same bytes. It
// must not print anything that can tell the two apart for a legitimate reason,
// which is why extension_loaded() guards the require and is never printed.
//
// Only VALUE errors are exercised (a malformed number, a zero divisor): those
// are thrown by this file's own `throw new ValueError(...)`, so the message is
// identical in both runs. A wrong TYPE is the engine's message -- an internal
// function's in the module, a userland one interpreted -- so it is not here.
declare(strict_types=1);

if (!extension_loaded('bcmath_port')) {
    require __DIR__ . '/bcmath.php';
}

// add / sub / mul / div / mod / comp over a scale that pads or truncates
// every second operand here is nonzero (bc_mod / bc_div are called below);
// zero divisors are in the caught-error section at the end.
$pairs = [
    ['1.5', '2.25'], ['-1', '1'], ['0.1', '0.2'], ['-0.001', '7'], ['+7', '-3.5'],
    ['123456789012345678901234567890.123', '987654321.987654321'],
    ['0', '-3.000'], ['99.999', '0.001'], ['-12.5', '-12.5'], ['10.5', '3'],
    ['-10.5', '3'], ['10.5', '-3'], ['1', '0.3'], ['250000.00', '1.004375'],
];
foreach ($pairs as [$a, $b]) {
    foreach ([0, 2, 5] as $s) {
        echo "$a $b $s: ", bc_add($a, $b, $s), " ", bc_sub($a, $b, $s), " ",
             bc_mul($a, $b, $s), " ", bc_mod($a, $b, $s), " ", bc_comp($a, $b, $s), "\n";
    }
}

// division, truncated toward zero
foreach ([['1', '3', 10], ['2', '3', 4], ['1', '8', 2], ['-1', '8', 2], ['5', '2', 0],
          ['7', '2', 0], ['-5', '2', 0], ['1', '7', 30], ['10', '0.3', 3], ['1.21', '1.1', 1],
          ['123456789012345678901234567890', '98765432109876543210.5', 10], ['0', '-3', 2]] as [$a, $b, $s]) {
    echo "div $a $b $s: ", bc_div($a, $b, $s), "\n";
}

// pow: integer exponents, positive, negative and zero; fractional base
foreach ([['2', '10', 0], ['1.1', '2', 1], ['1.1', '2', 5], ['2', '-2', 4], ['3', '-3', 10],
          ['0', '0', 2], ['5', '0', 3], ['0', '5', 2], ['-2', '3', 0], ['-2', '2', 0],
          ['1.5', '-2', 6], ['2', '2.0', 0], ['7', '5', 3]] as [$a, $e, $s]) {
    echo "pow $a $e $s: ", bc_pow($a, $e, $s), "\n";
}

// powmod: modular exponentiation, integers only
foreach ([['2', '10', '1000', 0], ['2', '10', '1000', 2], ['3', '100', '7', 0], ['5', '0', '7', 0],
          ['2', '10', '1', 0], ['-3', '3', '7', 0], ['7', '256', '13', 0], ['123', '45', '1000000', 0]] as [$a, $e, $m, $s]) {
    echo "powmod $a $e $m $s: ", bc_powmod($a, $e, $m, $s), "\n";
}

// sqrt: at several scales, perfect and not, and below one
foreach ([['2', 10], ['0', 5], ['1', 5], ['152.2756', 4], ['2', 0], ['0.25', 5], ['9', 0],
          ['10', 0], ['1000000', 4], ['99999999999999999999', 0], ['0.0001', 8]] as [$a, $s]) {
    echo "sqrt $a $s: ", bc_sqrt($a, $s), "\n";
}

// floor / ceil / round (HalfAwayFromZero, negative precision too)
foreach (['4.3', '-4.3', '4.0', '-4.0', '4', '0', '-0', '0.001', '-0.001', '4.9', '-4.9', '-0.5', '123.0001'] as $a) {
    echo "fc $a: ", bc_floor($a), " ", bc_ceil($a), "\n";
}
foreach (['2.5', '3.5', '-2.5', '1.95583', '0.125', '0.135', '9.995', '-0.5', '0.4', '0.5', '99.9', '1.0', '12.'] as $a) {
    echo "round $a: ", bc_round($a, 0), " ", bc_round($a, 2), " ", bc_round($a, 4), "\n";
}
foreach (['1241757', '1234', '5', '45', '0.5', '0.001'] as $a) {
    echo "roundn $a: ", bc_round($a, -1), " ", bc_round($a, -3), "\n";
}
// the ends of the precision range: -PHP_INT_MIN overflows a C integer
foreach (['1', '-999.5', '9999999999999999999.99'] as $a) {
    echo "roundx $a: ", bc_round($a, PHP_INT_MIN), " ", bc_round($a, PHP_INT_MIN + 1), " ", bc_round($a, -2147483648), "\n";
}

// the request default scale (bcscale)
echo "scale: ", bc_scale(), " ";
bc_scale(4);
echo bc_scale(), " ", bc_add('1', '3'), " ", bc_div('1', '3'), "\n";
bc_scale(0);

// a small ledger: exact where a float is not
$total = '0';
foreach (['0.10', '0.20', '0.30', '19.99', '-5.01', '1000000.01'] as $x) { $total = bc_add($total, $x, 2); }
echo "ledger: $total\n";

// VALUE errors: a malformed number, a zero divisor, a fractional exponent, a
// negative scale. Each throws from this file, so the message is the same both
// ways.
foreach ([fn() => bc_add('1', 'x', 2), fn() => bc_mul(' 5', '2', 2), fn() => bc_comp('1', '1e3'),
          fn() => bc_div('1', '0.00', 2), fn() => bc_mod('5', '0', 2), fn() => bc_pow('2', '1.5', 0),
          fn() => bc_powmod('2.5', '3', '7', 0), fn() => bc_sqrt('-1', 2), fn() => bc_add('1', '1', -1),
          fn() => bc_round('1', 0) . bc_floor('bad')] as $f) {
    try {
        echo $f(), "\n";
    } catch (Throwable $e) {
        echo get_class($e), ": ", $e->getMessage(), "\n";
    }
}

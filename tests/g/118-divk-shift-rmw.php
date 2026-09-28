<?php
// decimal-2x's second round, each against php: a division and a remainder by
// a constant (src/mach.mc's P12, a multiply-high, and its shifts by an
// immediate, P13), php's own shifts by a constant beside them, and a FIXED
// array's `$a[K] = $a[K] + E` (src/lvalue.mc's ph_addm64) whose element address
// is an add of a shifted operand (P13) and whose byte read's constants are
// the load's offset (src/opt.mc's ph_ac_walk).
function divs(int $n): string {
    return intdiv($n, 10) . ' ' . ($n % 10) . ' ' . intdiv($n, 7) . ' ' . ($n % 7) . ' '
        . intdiv($n, 2) . ' ' . ($n % 2) . ' ' . intdiv($n, 65535) . ' ' . ($n % 1000) . ' ' . intdiv($n, 3);
}

function shifts(int $n): string {
    return ($n << 3) . ' ' . ($n >> 2) . ' ' . ($n << 63) . ' ' . ($n >> 63) . ' ' . (($n >> 1) + 5);
}

function rmw(string $b, int $m): string {
    $nb = strlen($b);
    $a = array_fill(0, $nb + 2, 0);
    for ($i = 0; $i < 3; $i++) {
        for ($j = 0; $j < $nb; $j++) {
            $a[$i + $j] = $a[$i + $j] + $m * (ord($b[$nb - 1 - $j]) - 48);
        }
    }
    for ($i = 1; $i < $nb + 2; $i++) { $a[$i - 1] = $a[$i - 1] + $a[$i] * 3; }
    $t = '';
    for ($k = 0; $k < $nb + 2; $k++) { $t .= $a[$k] . ','; }
    return $t;
}

foreach ([0, 1, -1, 9, 10, 11, -9, -10, -11, 99, -99, 65535, -65535, 123456789, -123456789,
          PHP_INT_MAX, PHP_INT_MIN, PHP_INT_MAX - 5, PHP_INT_MIN + 5] as $n) {
    echo divs($n), ' | ', shifts($n), "\n";
}
echo rmw('90817', 7), "\n", rmw('0', -3), "\n", rmw('1234567890123', 9), "\n";

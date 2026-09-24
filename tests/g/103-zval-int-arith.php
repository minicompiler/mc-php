<?php
// A zval operator's int-and-int case is computed in place (docs/plan.md § 7),
// overflow included: php promotes to float, and -1 * PHP_INT_MIN is the one
// product whose check is a division that overflows itself (it was an int
// here on arm64 and a SIGFPE on x86-64). An int key reads and writes an array
// with no key zval, and a missing one is php's warning.
$v = [-1, PHP_INT_MIN, PHP_INT_MAX, 2, 0, "7", 2.5, null, true];
foreach ($v as $x) {
    foreach ($v as $y) {
        var_dump($x + $y, $x - $y, $x * $y);
    }
}
$m = [-1, PHP_INT_MIN, 1000000000, 999999999];
var_dump($m[0] * $m[1], $m[1] * $m[0], $m[2] * $m[3], $m[1] - $m[0], $m[1] + $m[0], $m[3] % $m[2]);

$r = array_fill(0, 4, 0);
for ($i = 0; $i < 4; $i++) {
    $j = 3 - $i;
    $r[$i + $j - 3 + $i] = $r[$j] + $i * 10;
    $r[$i] += 1;
}
var_dump($r);
$r[7] ??= 70;
$r[1] ??= 99;
var_dump($r[7], $r[1], $r[5] ?? "none", count($r));
var_dump($r[42]);
$k = 2;
$r[$k]++;
$r[$k] .= "x";
var_dump($r[$k]);

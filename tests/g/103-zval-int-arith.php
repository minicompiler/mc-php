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

// a zval against a NATIVE int, both orders: the box for the int is gone, the
// answers and the messages are the zval operator's
$ints = [1, -1, 0, 2, PHP_INT_MAX, PHP_INT_MIN];
foreach ($v as $x) {
    foreach ($ints as $n) {
        $c = $n;
        var_dump($x + $c, $c + $x, $x - $c, $c - $x, $x * $c, $c * $x);
        if ($c !== 0) { var_dump($x % $c); }
    }
}
try { var_dump($v[5] % 0); } catch (DivisionByZeroError $e) { echo get_class($e), ": ", $e->getMessage(), "\n"; }
$bad = "abc";
$z = [$bad];
try { var_dump($z[0] + 1); } catch (TypeError $e) { echo get_class($e), ": ", $e->getMessage(), "\n"; }
// a bitwise or shift result is a fresh box too: stored without a copy, and
// still a value -- the second variable moves alone
$b = $v[3] | 5;
$b2 = $b;
$b2++;
$s = $v[3] << 3;
$s2 = $s;
$s2 += 1;
var_dump($b, $b2, $s, $s2, $v[3] & 6, $v[3] ^ 1, $v[3] >> 1);
// an int key is native only for the walk that asked: a walk nested inside the
// key (an unset() in a closure) still gets a key zval -- it crashed (SIGSEGV)
// on this branch before the permission was scoped to one walk
$q = [];
$q[(function () { $c = [1, 2, 3]; unset($c[1]); $c[5] = 9; return count($c); })()] = 5;
var_dump($q);

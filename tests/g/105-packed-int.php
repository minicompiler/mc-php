<?php
// The packed int array (src/packed.mc): an array the compiler proves holds
// only ints under keys 0..n-1 and never leaves its function is a native i64
// buffer. Every function here is one the proof ACCEPTS for its $x (the end
// of tests/fixtures.sh checks that it did), and every answer must still be
// php's own -- a key the array does not have included, and a key the dense
// shape cannot hold.

// examples/decimal's _dec_umul: pushes, count, array_fill, element reads in
// arithmetic, a variable holding one element, element stores
function pk_mul(string $a, string $b): string {
    if ($a === '0' || $b === '0') { return '0'; }
    $x = [];
    for ($i = strlen($a); $i > 0; $i -= 4) { $k = min(4, $i); $x[] = (int) substr($a, $i - $k, $k); }
    $y = [];
    for ($j = strlen($b); $j > 0; $j -= 4) { $k = min(4, $j); $y[] = (int) substr($b, $j - $k, $k); }
    $nx = count($x);
    $ny = count($y);
    $r = array_fill(0, $nx + $ny, 0);
    for ($i = 0; $i < $nx; $i++) {
        $carry = 0;
        $xi = $x[$i];
        for ($j = 0; $j < $ny; $j++) {
            $t = $r[$i + $j] + $xi * $y[$j] + $carry;
            $r[$i + $j] = $t % 10000;
            $carry = intdiv($t, 10000);
        }
        $r[$i + $ny] = $carry;
    }
    $out = '';
    for ($i = $nx + $ny - 1; $i >= 0; $i--) { $out .= str_pad((string) $r[$i], 4, '0', STR_PAD_LEFT); }
    return ltrim($out, '0');
}

// a key the array does not have: php's warning, and null wherever null and
// 0 differ -- a comparison, a string, var_dump, a call's argument
function pk_absent(): void {
    $x = [];
    $x[] = 5;
    $x[] = 7;
    var_dump($x[0] + $x[1], $x[9] + 1, $x[9] * 2, -$x[9], $x[9] ** 2, $x[1] / 2, $x[0] + 1.5);
    var_dump($x[9] < -1, $x[9] == 0, $x[9] === 0, "a" . $x[9] . "b", $x[1]);
    var_dump($x[0] === $x[9], $x[9] === $x[8], $x[9] === null, $x[0] !== $x[9]);
    $v = $x[4];
    var_dump($v, $v + 3, $v * 2);
    $w = $x[1];
    var_dump($w, $w * $w);
    echo $x[8], "|", $x[0], "\n";
}

// keys past the end and below zero: the array becomes php's ordered hash in
// the same handle, keys in php's order, and push continues after the largest
function pk_sparse(): void {
    $x = array_fill(0, 3, 1);
    $x[3] = 4;
    $x[10] = 11;
    $x[-2] = 99;
    $x[] = 12;
    $x[0] = 2;
    var_dump(count($x), $x[10], $x[11], $x[-2], $x[0], $x[5] + 0);
    $y = array();
    $y[-1] = 3;
    $y[] = 4;
    var_dump(count($y), $y[-1], $y[0]);
}

// array_fill's own ValueError, from inside a packed initialisation
function pk_fill(int $n): int {
    $x = array_fill(0, $n, 7);
    $x[] = 1;
    return count($x) + $x[0];
}

// a compound assignment of an int variable from an element
function pk_sum(int $n): int {
    $x = [];
    for ($i = 0; $i < $n; $i++) { $x[] = $i * $i; }
    $s = 0;
    for ($i = 0; $i <= $n; $i++) { $s += $x[$i]; }
    return $s;
}

// re-initialised inside a loop, and a growing buffer
function pk_grow(int $n): int {
    $t = 0;
    for ($k = 0; $k < 3; $k++) {
        $x = [];
        for ($i = 0; $i < $n; $i++) { $x[] = $i + $k; }
        $t = $t + count($x) + $x[$n - 1];
    }
    return $t;
}

// `**` on a packed read and on a checked sum: php's pow_function_base, so
// the first product that overflows turns into a float instead of wrapping
function pk_pow(int $n) {
    $x = [];
    $x[] = $n;
    var_dump(($x[0] + 1) ** 2, $x[0] ** 2, -($x[0] + 1) ** 3);
}

echo pk_mul("123456789012345678", "98765432109876543210"), "\n";
echo pk_mul("9999", "9999"), " ", pk_mul("0", "5"), " ", pk_mul("1", "1"), "\n";
pk_absent();
pk_sparse();
echo pk_fill(3), "\n";
try { echo pk_fill(-1), "\n"; } catch (ValueError $e) { echo get_class($e), ": ", $e->getMessage(), "\n"; }
try { echo pk_fill(PHP_INT_MAX), "\n"; } catch (ValueError $e) { echo get_class($e), ": ", $e->getMessage(), "\n"; }
try { echo pk_fill(1 << 31), "\n"; } catch (ValueError $e) { echo get_class($e), ": ", $e->getMessage(), "\n"; }
echo pk_sum(10), "\n";
echo pk_grow(100), "\n";
pk_pow(3);
pk_pow(PHP_INT_MAX - 1);

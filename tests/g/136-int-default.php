<?php
// A plain `int $x = <int literal>` parameter keeps its native int (src/decl.mc):
// a "not passed" flag beside the value, filled with the literal in the
// prologue. Every shape, byte for byte against php: omitted, passed, a value
// the caller only has as a zval, a numeric string coerced (no strict_types
// here), and a null or a non-numeric string refused with php's TypeError.

function rnd(string $s, int $p = 2, int $q = -1): string {
    return "$s:" . ($p * 10 + $q);
}

echo rnd('a'), "\n";            // a:19
echo rnd('b', 5), "\n";         // b:49
echo rnd('c', 5, 7), "\n";      // c:57
echo rnd('d', 0, 0), "\n";      // d:0

// a value the caller holds as a zval (an array element)
$arr = [3, '4'];
echo rnd('e', $arr[0]), "\n";   // e:29
echo rnd('f', $arr[1]), "\n";   // f:39  ("4" coerced)
echo rnd('g', '8'), "\n";       // g:79

// the default reached from a function that forwards its own omitted argument
function fwd(int $p = 6): string { return rnd('h', $p); }
echo fwd(), "\n";               // h:59
echo fwd(1), "\n";              // h:9

// a non-nullable int: null and a non-numeric string are TypeErrors
foreach ([null, 'xyz'] as $bad) {
    try {
        echo rnd('i', $bad), "\n";
    } catch (TypeError $e) {
        echo get_class($e), "\n";
    }
}

// arithmetic on the parameter stays int
function steps(int $n = 3): int {
    $t = 0;
    for ($i = 0; $i < $n; $i++) { $t += $i * $n; }
    return $t;
}
echo steps(), " ", steps(5), "\n";   // 9 50

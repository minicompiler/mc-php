<?php
// A fresh buffer (src/rc.mc): a string the function makes with str_repeat and
// writes byte by byte in place. Two shapes it now covers, byte for byte
// against php: a byte copied from another string's offset (`$q[$i] = $a[$j]`
// is a byte write, src/lvalue.mc), and the buffer read by a `return` whose
// value can throw (src/lvalue.mc's phrt_ temporary then its check). And the
// one it must not: a `return` inside a try whose finally writes the buffer,
// where the returned value has to be the bytes from before the finally.

function rev(string $a): string {
    $n = strlen($a);
    $q = str_repeat('0', $n);
    for ($i = 0; $i < $n; $i++) { $q[$n - 1 - $i] = $a[$i]; }
    if ($n === 0) { return $q . '0'; }
    return $q . substr($a, 0, 1);
}
echo rev('abc'), ' ', rev(''), ' ', rev('7'), "\n";     // cbaa 0 77

// the same buffer read again after a byte copied out of itself
function shift(string $a, int $k): string {
    $n = strlen($a);
    $r = str_repeat(' ', $n);
    for ($i = 0; $i < $n; $i++) { $r[$i] = $a[$i]; }
    for ($i = 0; $i + $k < $n; $i++) { $r[$i] = $r[$i + $k]; }
    return substr($r, 0, $n - $k) . '|';
}
echo shift('abcdef', 2), "\n";                             // cdef|

// `$q . ''` is $q itself: the finally's write must not reach the answer
function fin(string $e): string {
    $q = str_repeat('x', 3);
    try {
        return $q . $e;
    } finally {
        $q[0] = 'y';
    }
}
echo fin(''), ' ', fin('-'), "\n";                          // xxx xxx-

// a buffer handed on before the return is not fresh, and stays correct
function kept(): array {
    $q = str_repeat('a', 2);
    $keep = [$q];
    $q[0] = 'b';
    $keep[] = $q;
    return $keep;
}
echo implode(',', kept()), "\n";                            // aa,ba

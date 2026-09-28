<?php
// A store `$a[K] = ... $a[K] ...` makes $a a FIXED array (src/packed.mc):
// unchecked, because nothing in the statement can change K between the read
// and the store. A call could only do it through a reference -- a
// by-reference argument, a closure over &$i -- and any source that names $i
// that way makes every $i a zval, so no key of a packed array (an int the
// scan proved) is one. Here the three calls leave $a php's array, and the
// store past the end grows it as php does; plain() keeps a call that cannot
// write its key ($p) and is FIXED.
function bump(&$i) { $i = $i + 100; return 1; }

function by_ref(int $n): string {
    $a = array_fill(0, $n, 0);
    for ($j = 0; $j < $n; $j++) { $a[$j] = $a[$j] + 1; }
    $i = 0;
    $a[$i] = $a[$i] + bump($i);
    $t = '';
    for ($k = 0; $k < $n; $k++) { $t .= $a[$k] . ','; }
    return $t . count($a);
}

function by_scanf(int $n): string {
    $a = array_fill(0, $n, 0);
    for ($i = 0; $i < $n; $i++) { $a[$i] = $a[$i] + 1; }
    $i = 0;
    $a[$i] = $a[$i] + sscanf("100", "%d", $i);
    $t = '';
    for ($k = 0; $k < $n; $k++) { $t .= $a[$k] . ','; }
    return $t . count($a);
}

function by_closure(int $n): string {
    $a = array_fill(0, $n, 0);
    $i = 0;
    $g = function () use (&$i) { $i = $i + 100; return 1; };
    for ($j = 0; $j < $n; $j++) { $a[$j] = $a[$j] + 1; }
    $a[$i] = $a[$i] + $g();
    $t = '';
    for ($k = 0; $k < $n; $k++) { $t .= $a[$k] . ','; }
    return $t . count($a);
}

function plain(int $n): string {
    $a = array_fill(0, $n, 0);
    for ($p = 0; $p < $n; $p++) { $a[$p] = $a[$p] + ord('a') - 96; }
    $t = '';
    for ($k = 0; $k < $n; $k++) { $t .= $a[$k] . ','; }
    return $t . count($a);
}

echo plain(3), "\n", by_ref(3), "\n", by_scanf(3), "\n", by_closure(3), "\n";

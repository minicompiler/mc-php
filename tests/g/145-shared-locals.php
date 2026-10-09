<?php
// Two int or bool locals whose ranges do not overlap share one local
// (src/opt.mc, lc_fn): loops one after the other, the two arms of an if, a
// local read before any store (it keeps its own), a local carried round a
// loop, and a continue that makes a loop go round. Each must still print what
// php prints.
function seq(int $n): int {
    $s = 0;
    for ($i = 0; $i < $n; $i++) { $x = $i * 3; $s += $x; }
    for ($k = 0; $k < $n; $k++) { $t = $k + 1; $s += $t * 2; }
    $c = 0;
    for ($j = $n; $j > 0; $j--) { $c = $c + $j; }
    return $s + $c;
}
function arms(int $n): int {
    if ($n > 2) { $a = $n * 2; $r = $a + 1; } else { $b = $n - 1; $r = $b * 5; }
    return $r;
}
function carry(int $n): int {
    $acc = 1;
    $prev = 0;
    for ($i = 0; $i < $n; $i++) {
        $cur = $acc + $prev;
        $prev = $acc;
        $acc = $cur;
    }
    $z = 0;
    for ($i = 0; $i < 3; $i++) { $w = $i; $z += $w; }
    return $acc * 100 + $z;
}
function cont(int $n): int {
    $s = 0;
    $i = 0;
    while (true) {
        $i++;
        if ($i > $n) break;
        $h = $i % 2;
        if ($h) continue;
        $s += $i;
    }
    $q = 7;
    return $s * 10 + $q;
}
function flags(int $n): string {
    $o = '';
    for ($i = 0; $i < $n; $i++) { $even = $i % 2 === 0; $o .= $even ? 'e' : 'o'; }
    for ($i = 0; $i < $n; $i++) { $big = $i > 2; $o .= $big ? 'B' : 's'; }
    return $o;
}
echo seq(5), ' ', arms(4), ' ', arms(1), ' ', carry(10), ' ', cont(9), ' ', flags(5), "\n";

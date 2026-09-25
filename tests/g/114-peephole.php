<?php
// src/mach.mc rewrites what the machine just emitted: a constant as the
// immediate of add/sub/and/cmp, an address add folded into the access, a
// constant or a global stored straight into a local, a branch over a branch
// inverted, and a global's page offset in its access. Every rewrite is on a
// value php can check: sums and masks at the immediate's edges (4095 fits,
// 4096 does not), bytes read at offsets through a string, counters kept in
// globals, loops that exit on each side of a comparison.
function sums(int $n): string {
    $a = 0; $b = 0; $c = 0; $d = 0;
    for ($i = 0; $i < $n; $i++) {
        $a = $a + 4095;
        $b = $b - 4096;
        $c = ($c + $i) & 255;
        $d = ($d + 7) & 65535;
        if ($i > 3000) { break; }
        if ($i == 17) { continue; }
    }
    return "$a $b $c $d";
}
function bytes(string $s): int {
    $h = 0;
    $n = strlen($s);
    $i = 0;
    while ($i < $n) {
        $o = ord($s[$i]);
        if ($o >= 48 && $o <= 57) { $h = $h * 10 + $o - 48; } elseif ($o != 45) { break; }
        $i++;
    }
    return $h;
}
$hits = 0;
$last = "";
function tick(string $x): int {
    global $hits, $last;
    $hits = $hits + 1;
    $last = $x;
    return $hits;
}
echo sums(10), "\n", sums(4000), "\n", sums(0), "\n";
echo bytes("12-34-567x9"), " ", bytes(""), " ", bytes("4095"), "\n";
for ($k = 0; $k < 5; $k++) { tick("t$k"); }
echo $hits, " ", $last, " ", tick("z"), "\n";

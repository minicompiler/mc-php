<?php
// A branch on a && or || branches on its terms (src/mach.mc's P15): each
// shape against php, the short circuit's side effects included, and a public
// function small enough to be copied into its caller.
$calls = 0;
function t(bool $v): bool { global $calls; $calls++; return $v; }

function both(int $a, int $b): string {
    if ($a > 0 && $b > 0) { return 'both'; }
    return 'not';
}

function either(int $a, int $b): string {
    if ($a > 0 || $b > 0) { return 'either'; } else { return 'neither'; }
}

function chain(int $a, int $b, int $c): int {
    $n = 0;
    for ($i = 0; $i < 4 && $a + $i < 9 && ($b > 0 || $c > $i); $i++) { $n = $n + 1; }
    while ($a > 0 && ($b > 0 || $c > 0)) { $a--; $n = $n + 10; }
    return $n;
}

function neg(int $a, int $b): string {
    if (!($a > 0 && $b > 0)) { return 'no'; }
    return 'yes';
}

foreach ([[1, 1], [1, 0], [0, 1], [0, 0], [-3, 7]] as $p) {
    $a = $p[0];
    $b = $p[1];
    echo both($a, $b), ' ', either($a, $b), ' ', neg($a, $b), ' ', chain($a, $b, $a - $b), "\n";
}
$calls = 0;
if (t(false) && t(true)) { echo "x\n"; }
if (t(true) || t(false)) { echo "y\n"; }
if ((t(true) && t(false)) || t(true)) { echo "z\n"; }
echo $calls, "\n";

<?php
// The line a diagnostic names, when the statements around it emit nothing.
//
// A statement announces its position (php_pos) only when something in it can
// raise or throw. Everything here therefore RAISES from a line whose
// neighbours are silent: a plain store, a native comparison, a native `%` by
// a literal. If the announcement were skipped, moved or left stale, the line
// php prints and the line mc-php prints would part company -- and this gate
// is differential, so php is the one that says what is right.

// 1. a raise whose PREVIOUS statement lowers to no call at all
$a = 1;
$b = 2;
echo $undef1;
echo "\n";

// 2. a raise inside a loop whose condition and step are native
for ($i = 0; $i < 2; $i = $i + 1) {
    $q = $i % 3;
    echo $undef2;
}
echo "\n";

// 3. a throw from a native-looking line, caught, with the line in the message
try {
    $z = 0;
    $r = 10 % $z;
} catch (DivisionByZeroError $e) {
    echo $e->getMessage(), " @", $e->getLine(), "\n";
}

// 4. a raise AFTER a call has already moved the position
function silent(int $n): int { return $n + 1; }
$k = silent(3);
echo $undef3;
echo "\n";

// 5. two raises on two different lines, back to back
echo $undef4;
echo $undef5;
echo "\n";

// 6. a raise inside a function, after silent statements in it
function noisy(): void {
    $p = 1;
    $s = $p % 2;
    echo $undef6;
    echo "\n";
}
noisy();

// 7. the line of a throw raised from a deeper frame
function thrower(): int { throw new RuntimeException("deep"); }
try {
    $t = 1;
    $u = thrower();
} catch (RuntimeException $e) {
    echo $e->getMessage(), " @", $e->getLine(), "\n";
}

// 8. a raise from a `for` CONDITION whose initializer and step are silent:
//    each part is checked on its own mark, and the for still has to announce
//    its own line or the warning names the statement above it (the reviewer
//    of #16). A warning, and a caught error asked for its line.
$v = 1;
for ($w = 0; $w < 1 + $undef8; $w = $w + 1) { echo "never\n"; }
echo "\n";
$v = 2;
try {
    for ($w = 0; $w < intdiv(10, 0); $w = $w + 1) { echo "never\n"; }
} catch (DivisionByZeroError $e) {
    echo "intdiv @", $e->getLine(), "\n";
}

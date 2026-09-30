<?php
// A destructuring whose target is a reference: the right-hand side's
// temporaries are built before ANY target is assigned. mc-php built them
// after the targets in front of the reference one, which then read an
// array that did not exist yet (SIGSEGV).
$x = 1;
$r = &$x;
[$b, $r] = [10, 20];
var_dump($b, $x);
function f(): void {
    $y = 0;
    $s = &$y;
    [$s, $c] = [strlen("abc"), [1, 2]];
    var_dump($y, $c);
}
f();

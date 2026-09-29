<?php
// php refuses, at compile time, a closure that captures the name one of its
// parameters uses; mc-php says so in php's words (tests/g/28-compile-fatal.php)
function f(): int {
    $x = 7;
    $g = function ($x) use ($x) { return $x; };
    return $g(3);
}
echo f(), "\n";

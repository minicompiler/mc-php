<?php
// php refuses, at compile time, a use list that names one variable twice
function f(): int {
    $a = 1;
    $g = function () use ($a, $a) { return $a; };
    return $g();
}
echo f(), "\n";

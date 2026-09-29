<?php
// A closure's parameter is the closure's own variable, whatever the enclosing
// scope calls something: an arrow function does not capture a name its
// parameter already uses, and a nested arrow function captures its OUTER
// arrow function's parameter, not the function's variable of that name.
function param_then_nested(): int { $x = 100; $f = fn($x) => fn() => $x * 2; return $f(5)(); }
function nested_param(): int { $x = 999; $g = fn() => fn($x) => $x + 1; return $g()(1); }
function outer_arrow_param(): int { $x = 1; $f = fn($x) => fn($y) => $x + $y; return $f(10)(5); }
function use_other(): int { $x = 5; $y = 1; $f = function ($x) use ($y) { return $x + $y; }; return $f(10) + $x; }
function no_use(): int { $x = 40; $f = function ($x) { return $x + 1; }; return $f(2) + $x; }
// an arrow function in a scope with more than sixteen variables: it captured
// the first sixteen only, and the seventeenth read as undefined
function wide(): int {
    $v1 = 1; $v2 = 2; $v3 = 3; $v4 = 4; $v5 = 5; $v6 = 6; $v7 = 7; $v8 = 8; $v9 = 9;
    $v10 = 10; $v11 = 11; $v12 = 12; $v13 = 13; $v14 = 14; $v15 = 15; $v16 = 16; $v17 = 17;
    $g = fn() => $v17 + $v1;
    return $g();
}
echo wide(), "\n";
echo param_then_nested(), " ", nested_param(), " ", outer_arrow_param(), " ", use_other(), " ", no_use(), "\n";

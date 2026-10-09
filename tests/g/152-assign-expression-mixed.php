<?php
// An assignment used as an expression follows the statement's rules (src/expr.mc):
// a mixed variable takes any value -- its type IS the union -- so `($x = 4)`
// on a mixed $x is no change of type and D4 has nothing to refuse.
function f(): mixed { return 3; }
function g(int $i): mixed { return $i < 2 ? $i : null; }
$x = f();
$z = ($x = 4) + 1;
var_dump($z, $x);
$y = $x ?: ($x = 9);
var_dump($y);
$x .= ($x = "b");
var_dump($x);
$w = f();
if (($w = 10) > 5) { echo "w=$w\n"; }
$i = 0;
$out = [];
while (($row = g($i)) !== null) { $out[] = $row; $i++; }
var_dump($out);
$q = f();
echo ($q = null) === null ? "null\n" : "x\n";
var_dump($q);

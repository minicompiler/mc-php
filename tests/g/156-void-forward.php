<?php
// A void function called AHEAD of its definition: the call was built before
// the declaration was read, to take a value, and php's value is null -- the
// function now answers one (src/decl.mc), where the call used to stop the
// compile with mc's own `value of type void`. Called as a statement, as a
// value, by reference, and from inside another function.
$v = 1;
bump($v);
$r = bump($v);
var_dump($r, $v);
echo json_encode([bump($v), $v]), "\n";
function twice(int $n): ?int { $m = $n; bump($m); bump($m); return $m; }
echo twice(5), "\n";
function bump(&$a): void { $a = $a + 1; if ($a > 100) return; }

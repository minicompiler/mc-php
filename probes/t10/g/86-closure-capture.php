<?php
// `use ($x)` is BY VALUE, and for an array that means a copy: php_arr_set
// stores the zval header and an array's header holds the hash, so the
// closure and the outer variable shared one.
$a = [1, 2];
$f = function () use ($a) { $a[] = 3; return count($a); };
echo $f(), " ", count($a), "\n";
print_r($a);
// nested arrays too
$b = ["k" => [1]];
$g = function () use ($b) { $b["k"][] = 2; return count($b["k"]); };
echo $g(), " ", count($b["k"]), "\n";
// a scalar was always fine
$n = 1;
$h = function () use ($n) { $n = 9; return $n; };
echo $h(), " ", $n, "\n";
// and BY REFERENCE still writes through
$r = 1;
$i = function () use (&$r) { $r = 7; };
$i();
echo $r, "\n";
// the closure is called twice: its own copy starts fresh each time
echo $f(), " ", $f(), " ", count($a), "\n";

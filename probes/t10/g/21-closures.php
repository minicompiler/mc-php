<?php
$mul = 3;
$f = function (int $x) use ($mul) { return $x * $mul; };
echo $f(7), "\n";
$g = fn($x) => $x + $mul;
echo $g(10), "\n";
$a = [1, 2, 3, 4];
print_r(array_map(fn($v) => $v * $v, $a));
print_r(array_filter($a, fn($v) => $v % 2 == 0));
echo array_reduce($a, fn($c, $v) => $c + $v, 0), "\n";
$b = [3, 1, 2];
usort($b, fn($x, $y) => $x <=> $y);
print_r($b);
class Counter { private int $n = 0; public function bump(): callable { return function() { $this->n++; return $this->n; }; } }
$c = new Counter(); $inc = $c->bump();
echo $inc(), $inc(), $inc(), "\n";

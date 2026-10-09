<?php
// A variadic closure or arrow function, a closure with more than five
// parameters, and a callable object's __invoke called with more than five
// arguments. A closure is reached with five argument slots; the rest arrive
// in the list php_call_zv_t hands it, the same way a method's past the sixth
// do (tests/g/178).
$c = function (string $p, int ...$n) { return $p . array_sum($n); };
var_dump($c("s", 1, 2, 3), $c("t"), $c("u", 1, 2, 3, 4, 5, 6, 7, 8), $c(...["v", 9, 9]), $c("w", ...range(1, 12)));
$a = fn(...$x) => count($x);
var_dump($a(1, 2, 3, 4, 5), $a(), $a(1, 2, 3, 4, 5, 6, 7));
$six = function ($a, $b, $c, $d, $e, $f, $g = "G") { return "$a$b$c$d$e$f$g"; };
var_dump($six(1, 2, 3, 4, 5, 6), $six(1, 2, 3, 4, 5, 6, 7));
try { $six(1, 2, 3, 4, 5); } catch (ArgumentCountError $e) { echo $e->getMessage(), "\n"; }
try { $c("x", 1, "no"); } catch (TypeError $e) { echo $e->getMessage(), "\n"; }
class Inv { public function __invoke(...$a) { return implode("+", $a); } }
$i = new Inv; var_dump($i(1, 2, 3, 4, 5, 6, 7, 8));
$k = 10; $cl = function (...$xs) use ($k) { return $k + count($xs); }; var_dump($cl(1, 2, 3, 4, 5, 6));
class Q { public int $base = 100; public function mk() { return fn(int ...$v) => $this->base + array_sum($v); } }
var_dump((new Q)->mk()(1, 2, 3, 4, 5, 6, 7));

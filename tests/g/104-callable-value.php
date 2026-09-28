<?php
// A callable VALUE called: `$f(...)` and `(expr)(...)` over a closure, an
// arrow function, an __invoke object and a callable a function returned. On
// the program road a callable STRING has no table to be looked up in and is
// refused by design (tests/r/d6-callable-string.php); an extension calls it
// through php (tests/ext.sh step 19).
$double = function (int $x): int { return $x * 2; };
echo $double(21), "\n";
$add = fn($a, $b) => $a + $b;
echo $add(40, 2), "\n";
$k = 3;
$times = function ($x) use ($k) { return $x * $k; };
echo $times(14), "\n";
class Greeter { public function __invoke($name) { return "hi $name"; } }
$g = new Greeter();
echo $g("php"), "\n";
function make(int $n): Closure { return function ($x) use ($n) { return $x + $n; }; }
$plus5 = make(5);
echo $plus5(37), "\n";
echo (function () { return "iife"; })(), "\n";
$fs = [$double, $add];
echo $fs[0](4), " ", $fs[1](1, 2), "\n";
$none = function () {};
var_dump($none());
$thrower = function () { throw new RuntimeException("from a closure"); };
try { $thrower(); } catch (RuntimeException $e) { echo get_class($e), ": ", $e->getMessage(), "\n"; }

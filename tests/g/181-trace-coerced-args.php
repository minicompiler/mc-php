<?php
// php's stack trace shows a frame's arguments as the parameters received
// them -- after the conversion to the declared type -- so a TypeError on the
// second argument shows the first one already converted (`f(1.0, 'x')`).
// The frames kept the caller's values. And a function parameter converted in
// its own prologue reported the argument number one too high once a
// nullable parameter came before it.
declare(strict_types=1);
class A {
    public function f(float $a, float $b) { return 1; }
    public function v(float ...$f) { return 1; }
    public static function s(int $a, float $b, string ...$c) { return 1; }
    public function many($a, $b, $c, $d, $e, $f, float $g, float $h) { return 1; }
}
function g(float $a, float $b) { return 1; }
function h(float $a, ?float $b = null, float $c = 0.5) { return 1; }
$cl = function (float $a, float ...$r) { return 1; };
foreach ([fn() => (new A)->f(1, "x"), fn() => g(1, "x"), fn() => (new A)->v(1, 2, "z"), fn() => A::s(1, 2, "a", 3),
          fn() => (new A)->many(1, 2, 3, 4, 5, 6, 7, "q"), fn() => h(1, 2, "w"), fn() => $cl(1, 2, 3, 4, 5, 6, "e")] as $t) {
    try { $t(); } catch (TypeError $e) { echo $e->getMessage(), "\n", $e->getTraceAsString(), "\n"; }
}
function hh(float $a, ?float $b = null, float $c = 0.5) { return 1; }
function kk(int $a, ?int $b = null, int $c = 5) { return 1; }
try { hh(1, 2, "w"); } catch (TypeError $e) { echo $e->getMessage(), "\n"; }
try { kk(1, 2, "w"); } catch (TypeError $e) { echo $e->getMessage(), "\n"; }

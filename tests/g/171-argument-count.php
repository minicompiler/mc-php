<?php
// A call that leaves out a required parameter: php's ArgumentCountError --
// "N passed in FILE on line L and exactly|at least M expected", placed at the
// parameter -- for a function, a method, a closure and a callback; the
// optional-before-required and implicitly-nullable deprecations; a typed
// parameter's TypeError placed at the parameter. Found while fixing PR #65's
// defects.
function f($a,
  $b,
  $c = 3,
  $d) { return $a; }
function g(int $a) { return $a; }
function o($a, $b = 1) {}
function v($a, ...$r) {}
function b0(int $x = null, $y) {}
class C { function m($x) { return $x; } static function s($x) { return $x; } function k($x = 2, $y) {} }
try { f(1); } catch (ArgumentCountError $e) { echo $e->getMessage(), " @", $e->getLine(), "\n", $e->getTraceAsString(), "\n"; }
try { f(1, 2); } catch (ArgumentCountError $e) { echo $e->getMessage(), " @", $e->getLine(), "\n"; }
try { (new C)->m(); } catch (ArgumentCountError $e) { echo $e->getMessage(), "\n"; }
try { C::s(); } catch (ArgumentCountError $e) { echo $e->getMessage(), "\n"; }
try { $c = fn($q) => $q; $c(); } catch (ArgumentCountError $e) { echo $e->getMessage(), "\n"; }
try { $c2 = function (
  $x,
  $y) { return 1; }; $c2(1); } catch (ArgumentCountError $e) { echo $e->getMessage(), " @", $e->getLine(), "\n"; }
try { array_map(fn($a, $b) => 1, [1]); } catch (ArgumentCountError $e) { echo $e->getMessage(), "\n", $e->getTraceAsString(), "\n"; }
try { echo sprintf(); } catch (ArgumentCountError $e) { echo $e->getMessage(), "\n"; }
try { g(); } catch (ArgumentCountError $e) { echo $e->getMessage(), " @", $e->getLine(), "\n"; }
try { v(); } catch (ArgumentCountError $e) { echo $e->getMessage(), "\n"; }
try { o(); } catch (ArgumentCountError $e) { echo $e->getMessage(), "\n"; }
try { b0(); } catch (ArgumentCountError $e) { echo $e->getMessage(), "\n"; }
function h(
  int $a,
  int $q) { return $q; }
try { h(1, "x"); } catch (TypeError $e) { echo $e->getMessage(), " @", $e->getLine(), "\n"; }
class D { function m(
   int $x) { return $x; } }
try { (new D)->m("y"); } catch (TypeError $e) { echo $e->getMessage(), " @", $e->getLine(), "\n"; }
$t = function (
  int $z, string $s = "d") { return $z . $s; };
try { $t("w"); } catch (TypeError $e) { echo $e->getMessage(), " @", $e->getLine(), "\n"; }
echo $t(3), "\n";
function vv(int $a,
  int ...$r) { return 1; }
try { vv(1, 2, "x"); } catch (TypeError $e) { echo $e->getMessage(), " @", $e->getLine(), "\n"; }

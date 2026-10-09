<?php
// A parameter declared with more than one plain scalar -- a nullable (?int,
// ?float, ?string, ?bool), a union, a class or interface, iterable, object,
// or the implicitly nullable `int $x = null` -- was never checked: h(2) on a
// ?float kept int(2), "abc" reached the body, an object of the wrong class
// went through, and `int $x = null` refused the null it allows. Functions,
// methods (variadic ones element by element), closures and a native ?int
// argument all check and convert as php does, with php's message.
interface Shape {}
class Sq implements Shape { function __toString(): string { return "sq"; } }
class Other {}
function u(int|string $x) { var_dump($x); }
function cls(Shape $s) { return get_class($s); }
function ncls(?Shape $s = null) { return $s === null ? "none" : get_class($s); }
function imp(int $x = null) { var_dump($x); }
function it(iterable $i) { return is_array($i) ? "arr" : "obj"; }
function st(Stringable $s) { return (string)$s; }
function fb(int|float $n) { var_dump($n); }
function ob(object $o) { return get_class($o); }
function bf(bool|int $b) { var_dump($b); }
class M { function m(?int $a, int|string $b, Shape $c, ?string ...$rest) { return json_encode([$a, $b, get_class($c), $rest]); } }
$c = fn(?float $f, Shape|int $s) => json_encode([$f, is_object($s) ? get_class($s) : $s]);
$cases = [fn() => u(5), fn() => u("x"), fn() => u(1.5), fn() => u(true), fn() => u([]), fn() => cls(new Sq), fn() => cls(new Other),
  fn() => ncls(), fn() => ncls(null), fn() => ncls(new Sq), fn() => ncls(5), fn() => imp(), fn() => imp(null), fn() => imp("7"), fn() => imp("a"),
  fn() => it([1]), fn() => it(new Sq), fn() => st(new Sq), fn() => st("str"), fn() => fb("3"), fn() => fb("3.5"), fn() => fb("x"), fn() => ob(new Other), fn() => ob(1),
  fn() => bf("1"), fn() => bf(2.0),
  fn() => (new M)->m(null, 4, new Sq), fn() => (new M)->m("5", 6.0, new Sq, "a", null, 7), fn() => (new M)->m(1, 2, new Other), fn() => (new M)->m(1, 2, new Sq, []),
  fn() => $c(1, 2), fn() => $c(null, new Sq), fn() => $c("x", 1), fn() => $c(1, "q")];
foreach ($cases as $n => $t) { try { var_dump($t()); } catch (TypeError $e) { echo "$n: ", $e->getMessage(), "\n"; } }
function h(?float $b) { var_dump($b); }
function i(?int $b = null) { var_dump($b); }
function s(?string $b) { var_dump($b); }
function bo(?bool $b) { var_dump($b); }
class C { function m(?float $b) { var_dump($b); } static function n(?string $s = null) { var_dump($s); } }
h(2); h(null); h("3.5"); i("7"); s(5); bo(1); (new C)->m(4); C::n(9);
$cl = function (?float $f) { var_dump($f); }; $cl(6);
try { h("abc"); } catch (TypeError $e) { echo $e->getMessage(), "\n"; }

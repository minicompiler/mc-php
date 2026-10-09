<?php
// A variadic method -- instance, static, a constructor, a promoted
// constructor, an override calling parent:: with a spread -- and a method with
// more than six parameters. Every method is reached with six argument slots,
// so a call with more arguments, or a spread, used to be a compile error at
// the declaration (`...`), at the call (more than six), or silently cut at
// six. The first six still travel in the slots, the rest in a list the
// runtime hands the method (lib/php_rt.mc php_targs); a by-reference seventh
// parameter still writes through. Typed elements are checked as php checks
// them, and __call / __callStatic see every argument.
class A {
    public function sum(int ...$xs): int { return array_sum($xs); }
    public function lst(string $p, ...$r): string { return $p . ":" . json_encode($r); }
    public static function cat(string $sep, string ...$parts): string { return implode($sep, $parts); }
    public function seven($a, $b, $c, $d, $e, $f, $g, $h = "H"): string { return "$a$b$c$d$e$f$g$h"; }
    public function sevenr($a, $b, $c, $d, $e, $f, &$g): void { $g = "changed"; }
    public function afterSix($a, $b, $c, $d, $e, $f, $g, ...$rest): string { return $g . "|" . json_encode($rest); }
    public function fl(float ...$f): string { return json_encode($f); }
}
class B extends A {
    public function __construct(public string $name = "", int ...$ids) { $this->ids = $ids; }
    public array $ids = [];
    public function sum(int ...$xs): int { return parent::sum(...$xs) * 10; }
}
class M {
    public function __call($n, $a) { return "$n(" . implode(",", $a) . ")"; }
    public static function __callStatic($n, $a) { return "static $n(" . implode(",", $a) . ")"; }
}
$o = new A;
$r = [];
$r[] = $o->sum(1, 2, 3, 4, 5, 6, 7, 8, 9, 10);
$r[] = $o->sum(...range(1, 20));
$r[] = $o->sum(1, 2, ...[3, 4, 5, 6, 7, 8]);
$r[] = $o->lst("p");
$r[] = $o->lst("p", null, 1.5, "x", [1], 5, 6, 7, 8);
$r[] = A::cat("-", "a", "b", "c", "d", "e", "f", "g", "h");
$r[] = A::cat(...["/", "x", "y"]);
$r[] = $o->seven(1, 2, 3, 4, 5, 6, 7);
$r[] = $o->seven(1, 2, 3, 4, 5, 6, 7, 8);
$r[] = $o->afterSix(1, 2, 3, 4, 5, 6, 7);
$r[] = $o->afterSix(1, 2, 3, 4, 5, 6, 7, 8, 9, ...[10, 11]);
$r[] = $o->fl(1, "2.5", 3);
$v = "orig"; $o->sevenr(1, 2, 3, 4, 5, 6, $v); $r[] = $v;
$b = new B("bee", 4, 5, 6, 7, 8, 9, 10, 11);
$r[] = $b->name . json_encode($b->ids);
$r[] = $b->sum(1, 2, 3, 4, 5, 6, 7);
$r[] = (new B)->name . json_encode((new B)->ids);
$n = null;
$r[] = $n?->sum(1, 2, 3, 4, 5, 6, 7, 8);
$anon = new class(1, 2, 3, 4, 5, 6, 7, 8) { public array $all; public function __construct(...$all) { $this->all = $all; } };
$r[] = json_encode($anon->all);
$m = new M;
$r[] = $m->foo(1, 2, 3, 4, 5, 6, 7, 8);
$r[] = M::bar(1, 2, 3, 4, 5, 6, 7);
$r[] = $m->baz(...[1, 2, 3, 4, 5, 6, 7, 8, 9]);
foreach ($r as $x) { var_dump($x); }
try { $o->sum(1, 2, "x"); } catch (TypeError $e) { echo $e->getMessage(), "\n"; }
try { $o->sum(1, 2, 3, 4, 5, 6, 7, []); } catch (TypeError $e) { echo $e->getMessage(), "\n"; }
try { $o->seven(1, 2, 3, 4, 5, 6); } catch (ArgumentCountError $e) { echo $e->getMessage(), "\n"; }
try { $o->lst(); } catch (ArgumentCountError $e) { echo $e->getMessage(), "\n"; }
try { $o->sum(...5); } catch (TypeError $e) { echo $e->getMessage(), "\n"; }

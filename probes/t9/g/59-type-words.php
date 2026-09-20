<?php
class Box { public $v = 7; }
function f1(array $a): int { return count($a); }
function f2(mixed $m): string { return gettype($m); }
function f3(?int $x): string { return var_export($x, true); }
function f4(int|string $x): string { return gettype($x); }
function f5(Box $b): int { return $b->v; }
function f6(callable $c): int { return $c(3); }
function f7(iterable $i): int { $n = 0; foreach ($i as $x) { $n = $n + 1; } return $n; }
function f8(object $o): string { return get_class($o); }
function f9(): void { echo "void\n"; }
function f10(\Box $b): int { return $b->v + 1; }
function f11(?array $a = null): string { return var_export($a, true); }
echo f1([1,2,3]), "\n", f2(1.5), "\n", f3(null), "\n", f3(4), "\n";
echo f4("s"), " ", f4(9), "\n", f5(new Box), "\n";
echo f6(function($n) { return $n * 2; }), "\n", f7([1,2]), "\n", f8(new Box), "\n";
f9();
echo f10(new Box), "\n", f11(), "\n", f11([1]), "\n";

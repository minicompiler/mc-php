<?php
// by-reference parameters, closures, the alternative syntax, destructuring
// and an anonymous class -- T8's first four blocks, in one program.
function f(&$x) { $x = 5; }
$a = 1; f($a); echo $a, "\n";
function out(&$r) { $r = [1, 2]; }
out($n); var_dump($n);
$c = 0;
$g = function () use (&$c) { $c++; };
$g(); $g(); echo $c, "\n";
function sum(int ...$v) { return array_sum($v); }
echo sum(1, 2, 3), "\n";
if (true): echo "alt-if\n"; elseif (false): echo "no\n"; else: echo "no\n"; endif;
$i = 0; while ($i < 2): echo $i; $i++; endwhile; echo "\n";
for ($j = 0; $j < 2; $j++): echo $j; endfor; echo "\n";
foreach ([7, 8] as $v): echo $v; endforeach; echo "\n";
switch (2): case 1: echo "one"; break; case 2: echo "two"; break; endswitch; echo "\n";
list($p, $q) = [10, 20]; echo "$p $q\n";
[$r, [$s, $t]] = [1, [2, 3]]; echo "$r $s $t\n";
['k' => $u] = ['k' => 'v']; echo $u, "\n";
interface Ihi { public function hi(); }
$o = new class(9) implements Ihi { public $n; function __construct($n) { $this->n = $n; }
                                   public function hi() { return "hi " . $this->n; } };
echo $o->hi(), "\n";
$z = 3; $o2 = new class { function bump(&$v) { $v++; } }; $o2->bump($z); echo $z, "\n";
$h = function () { return 42; };
$h();
echo "done\n";

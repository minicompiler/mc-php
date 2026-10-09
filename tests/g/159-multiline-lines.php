<?php
// A statement spread over several lines: php reports a diagnostic at the line
// of the operation that raised it -- the call's name, the operand's index, the
// interpolated variable -- not at the statement's first line. (PR #65 defect 1)
function f($x) { return 1; }
function g(int $x) { return $x; }
class C { function m(int $x) { return $x; } static function s(int $x) { return $x; } }
$a = [];
$x =
  $a[1];
$y = $a[2] +
  $a[3] + $a[4]
  + $a[5];
$z = [
  'k' => $a[6],
  'j' =>
     $a[7]];
echo
  $a[8],
  "\n";
$q = f(
  $a[9]) + $a
  [10];
try { $r = 1 +
   []; } catch (TypeError $e) { echo $e->getLine(), "\n"; }
try { $r = intdiv(1,
  0) ; } catch (Error $e) { echo $e->getLine(), "\n"; }
try { $r =
  intdiv
  (1,
  0) ; } catch (Error $e) { echo $e->getLine(), "\n"; }
if ($a[11]
  || $a[12]) {}
echo str_repeat("a", 2),
   strpos("abc", "b",
     0), "\n";
$i = 0;
while ($a[$i + 20] === null && $i < 2) {
  $i++;
}
for ($j = 0; $j < 2 && $a[$j + 30] === null; $j++) {
  $c = 2;
}
try { echo g(1) +
  g(
   "zz"), "\n"; } catch (TypeError $e) { echo $e->getLine(), " ", $e->getMessage(), "\n"; }
$o = new C;
try { $r = $o
   ->m(
   "a"); } catch (TypeError $e) { echo $e->getLine(), " ", $e->getMessage(), "\n"; }
try { $r = C
   ::s(
   "a"); } catch (TypeError $e) { echo $e->getLine(), " ", $e->getMessage(), "\n"; }
try { $r =
   strlen(
   []); } catch (TypeError $e) { echo $e->getLine(), " ", $e->getMessage(), "\n"; }
$s = "x
 $a[40] y
  {$a[41]}";
$h = <<<EOT
  one
  two $a[42]
  EOT;
echo
  "q $a[43]\n";
class P { public int $n = 0; }
$p = new P;
try { $p->n =
   "x"; } catch (TypeError $e) { echo $e->getLine(), " ", $e->getMessage(), "\n"; }
$t = 1 +
  2 +
  $a[50] +
  intdiv(1,
     0);

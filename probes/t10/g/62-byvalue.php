<?php
// php parameters are BY VALUE: the callee's writes do not reach the caller
function f($x) { $x[] = 2; $x["k"] = 3; return count($x); }
$a = [1];
echo f($a), " ", count($a), "\n";
function g($s) { $s = "no"; return $s; }
$t = "yes";
echo g($t), " ", $t, "\n";
class C {
    function m($y) { $y[] = 9; return count($y); }
    function byref(&$z) { $z[] = 5; return count($z); }
}
$o = new C();
$b = [1, 2];
echo $o->m($b), " ", count($b), "\n";
// and a by-REFERENCE parameter still writes through
$c = [1];
echo $o->byref($c), " ", count($c), "\n";
function h(&$w) { $w[] = 4; }
$d = [1];
h($d);
echo count($d), "\n";
// nested arrays are copied too
function deep($p) { $p[0][] = 99; return count($p[0]); }
$e = [[1, 2]];
echo deep($e), " ", count($e[0]), "\n";

<?php
function f($a, $b = 'B', $c = 'C') { echo "$a|$b|$c\n"; }
$x = [1, 2, 3];
f(...$x);
f(...[9]);
f(0, ...[7, 8]);
function v(...$r) { var_dump($r); }
v(...$x);
v(1, ...$x);
echo implode(",", [...$x, 4]), "\n";
class K { function m($p, $q = 5) { echo "$p/$q\n"; } }
(new K)->m(...[1, 2]);
$x=[1,5,3];
echo max(...$x)," ",min(...$x),"\n";
echo max(1,2)," ",min(2.5,1)," ",max([4,9,2])," ",min([4,9,2]),"\n";
echo max("10","9a")," ",max(1,2,3,0),"\n";
var_dump(max([1,2],[1,3]));

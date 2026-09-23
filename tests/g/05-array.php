<?php
$a = [1, 2, 3];
$b = array("x", "y");
var_dump($a);
var_dump($b);
var_dump(count($a));
foreach ($a as $v) { echo $v, ","; }
echo "\n";
foreach ($b as $k => $w) { echo $k, "=", $w, ";"; }
echo "\n";
$a[] = 4;
$a[0] = 9;
var_dump($a);
echo implode("-", $b), "\n";
var_dump(explode(",", "p,q,r"));

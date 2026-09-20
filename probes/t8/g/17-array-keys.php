<?php
// T6: php's ordered hash -- string keys, integer keys, insertion order, the
// next-free-integer rule, holes left by unset, heterogeneous elements.
$a = [5 => "five", "k" => "vee", "10" => "ten", "x"];
$a[] = "next";
$a[-3] = "neg";
$a[] = "after-neg";
var_dump($a);
unset($a["k"]);
echo count($a), "\n";
foreach ($a as $k => $v) { echo var_export($k, true), " => ", $v, "\n"; }
var_dump(isset($a["k"]), isset($a[5]), array_key_exists(5, $a));
$b = [1, [2, [3]]];
print_r($b);
var_dump($b == [1, [2, [3]]], $b === [1, [2, [3]]], $b === [1, [2, [4]]]);

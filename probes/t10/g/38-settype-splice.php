<?php
$v = "12abc"; settype($v, "int"); var_dump($v);
$w = 1; settype($w, "bool"); var_dump($w);
$y = 3; settype($y, "string"); var_dump($y);
var_dump(str_decrement("b"), str_decrement("aa"), str_decrement("B"), str_decrement("10"));
$a = [1,2,3,4,5];
$cut = array_splice($a, 1, 2);
var_dump($a, $cut);
$b = [1,2,3];
array_splice($b, 1, 0, ['x','y']);
var_dump($b);
parse_str("a=1&b=two&c[]=3&c[]=4&d[k]=v", $out);
var_dump($out);
var_dump(strlen(uniqid()));
var_dump(substr(uniqid("p"), 0, 1));

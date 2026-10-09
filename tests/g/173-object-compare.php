<?php
// Objects compared with == != < > <=> and against scalars, php's way: the
// same class property by property, another class never equal. Found while
// fixing PR #65's defects.
class P { public $a = 1; public $b = 2; }
class Q { public $a = 1; public $b = 2; }
$p = new P; $q = new P; $q->b = 3; $r = new Q; $s = new P;
var_dump($p == $q, $p != $q, $p < $q, $p > $q, $p == $s, $p == $r, $p <=> $q, $q <=> $p, $p == 1, $p == null, $p == "x");
class P2 { public $a = 1; public $b = [2]; }
$p = new P2; $q = new P2;
var_export($p); echo "\n"; var_dump($p == $q, $p < $q, serialize($p), json_encode($p)); foreach ($p as $k => $v) echo $k; echo "\n"; print_r($p);

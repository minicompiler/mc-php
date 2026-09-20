<?php
function f() { return 100; }
function &g() { static $x = 5; return $x; }
$a = &f();
var_dump($a);
$b = &g();
$b = 9;
var_dump(g());
$arr = [1,2,3];
$v = 7;
$arr[0] = &$v;
$v = 42;
var_dump($arr[0]);
class C { public $p = 1; }
$o = new C;
$o->p = &$v;
$v = 8;
var_dump($o->p);
$a2 = ['x' => 1];
$w = 3;
$a2['x'] = &$w;
$w = 11;
var_dump($a2['x'], $w);

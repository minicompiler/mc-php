<?php
class T { public $x = [[1]]; public $y; }
$t = new T;
var_dump(isset($t->x[0][0]), isset($t->x[0][5]), isset($t->y), isset($t->nope));
var_dump(empty($t->x[0][0]), empty($t->x[9]), empty($t->y));
$a = [1, 2];
var_dump(isset($a[0]), isset($a[5]), empty($a[0]), empty($a[5]));
$s = "abc";
var_dump(isset($s[1]), isset($s[9]));
$u = null;
var_dump(isset($u), isset($undefined));

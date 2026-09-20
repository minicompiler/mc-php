<?php
$a = [new stdClass];
$a[0]->p = 1;
var_dump($a[0]->p);
class T { public $x = []; }
$t = new T;
$t->x[0] = "q";
var_dump($t->x);
$t->x[1][2] = "deep";
var_dump($t->x[1][2]);
$b = [[new stdClass]];
$b[0][0]->z = 9;
var_dump($b[0][0]->z);

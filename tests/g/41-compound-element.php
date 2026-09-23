<?php
$m = ["a"];
$m[0] .= "x";
var_dump($m);
$q = [1];
$q[0] += 5;
$q[0] *= 2;
var_dump($q);
$r = [3];
$r[0]++;
$r[0]--;
$r[0]--;
var_dump($r);
$n = [];
$n["k"] ??= "d";
$n["k"] ??= "e";
var_dump($n);
class C { public $p = 1; }
$c = new C;
$c->p += 4;
var_dump($c->p);
$d = [["z" => 1]];
$d[0]["z"] += 9;
var_dump($d);

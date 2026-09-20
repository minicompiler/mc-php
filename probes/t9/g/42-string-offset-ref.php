<?php
$s = "0123456789";
$s[9] = "x";
var_dump($s);
$s[12] = "z";
var_dump($s);
class T2 { public $l = [1]; }
$t = new T2;
$c = &$t->l;
$c[] = 2;
var_dump($t->l);
$a = [1, 2];
$r = &$a[0];
$r = 99;
// echo and not var_dump: php marks a REFERENCED element `&int(99)`, and D7
// has no refcount to tell the mark from the value (probes/t8/RESULTS.md
// section "What is not there").
echo $a[0], " ", $a[1], "\n";

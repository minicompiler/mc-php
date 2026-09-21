<?php
// php SHORT-CIRCUITS && and ||: the right operand is not evaluated at all
// when the left already decides. T9 lowered both sides unconditionally.
function t($n) { echo "ran $n\n"; return $n > 1; }
var_dump(false && t(1));
var_dump(true || t(2));
var_dump(true && t(3));
var_dump(false || t(4));
// the right side's own pending statements go inside the branch too: an
// array literal is a run of inserts, and it must not run either
$k = 0;
$r = false && count([$k = 9, 2]) > 0;
var_dump($r, $k);
// ?? and ?: short-circuit the same way
$n = null;
$a = $n ?? t(5);
var_dump($a);
$b = 1 ?? t(6);
var_dump($b);
$c = true ? 7 : t(8);
var_dump($c);
// and a throwing right operand is simply not reached
function boom() { throw new Exception("no"); }
var_dump(false && boom());
var_dump(true || boom());

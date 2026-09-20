<?php
$u1 .= "x";
var_dump($u1);
$u2++;
var_dump($u2);
$u3 += 2;
var_dump($u3);
unset($u4);
var_dump(isset($u4));
$a = &$b;
var_dump($a, $b);

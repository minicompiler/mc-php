<?php
$ar = [];
@$ar[0] = 1;
var_dump($ar);
@$undef2 = 5;
var_dump($undef2);
$x = @$nope;
var_dump($x);
echo "end\n";

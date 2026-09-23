<?php
// the float tail T6 named, and what var_dump/print_r/var_export owe a class
foreach ([1.7E-300, 1e-290, 0.1, 1/3, 1e22, 1e23, -0.0, 1.0, 1e15] as $x) {
    echo $x, " ";
    var_dump($x);
}
class P { public $a = 1; protected $b = 2; private $c = 3; }
$o = new P;
var_dump($o);
print_r($o);
echo "\n";
var_export($o);
echo "\n";
var_export(new stdClass);
echo "\n";
var_export(['x' => [1, true, null, 1.5]]);
echo "\n";

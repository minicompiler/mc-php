<?php
// D6 was corrected by T8's measurement: func_get_args needs no run-time type
// table -- the arguments of the executing function ARE its own parameters,
// which the compiler has in front of it. debug_backtrace stays refused.
function f($a, $b = null, $c = null) {
    $args = func_get_args();
    var_dump($args);
    echo count($args), " ", func_num_args(), "\n";
    foreach ($args as $i => $v) { echo $i, "=", var_export($v, true), "\n"; }
}
f(1);
f(1, "x", 3.5);
f(null, false, [1, 2]);

<?php
// A typed by-reference METHOD parameter: php coerces the caller's own
// variable when the value is acceptable, and leaves it exactly as it was
// when the declared type refuses it.
class K {
    function m(int &$x) { $x = $x + 1; return $x; }
}
$k = new K;
$a = "5";
echo $k->m($a), " ", var_export($a, true), "\n";
$b = [];
try { $k->m($b); } catch (\Throwable $e) { echo get_class($e), "\n"; }
var_dump($b);
$c = 7;
echo $k->m($c), " ", var_export($c, true), "\n";

<?php
// array_diff_key and array_intersect_key answer by KEY. Wiring them to the
// value-comparing helper is invisible until two entries share a value or two
// keys share one: `array_diff_key(["a"=>1], ["b"=>1])` keeps `a` in php and
// kept nothing here.
$a = ["a" => 1, "b" => 2, "c" => 3];
$b = ["b" => 9, "c" => 3];
var_dump(array_diff_key($a, $b));
var_dump(array_intersect_key($a, $b));

// equal values under different keys: the case the value helper gets wrong
var_dump(array_diff_key(["a" => 1], ["b" => 1]));
var_dump(array_intersect_key(["a" => 1], ["b" => 1]));

// integer keys, including a list
var_dump(array_diff_key([10, 20, 30], [1 => 0]));
var_dump(array_intersect_key([10, 20, 30], [1 => 0, 2 => 0]));

// a numeric STRING key is an integer key once stored, on both sides
var_dump(array_diff_key(["7" => "x", "k" => "y"], [7 => "z"]));
var_dump(array_intersect_key(["7" => "x", "k" => "y"], ["7" => "z"]));

// mixed keys, and an empty side
var_dump(array_diff_key(["a" => 1, 0 => 2], []));
var_dump(array_intersect_key(["a" => 1, 0 => 2], []));
var_dump(array_diff_key([], ["a" => 1]));

// the value forms are untouched
var_dump(array_diff([1, 2, 3], [2]));
var_dump(array_intersect([1, 2, 3], [2, 3]));
echo "end\n";

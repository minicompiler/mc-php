<?php
// one line each, from docs/review-backlog.md section 2
var_dump(2 ** -1);              // float(0.5), not int(1)
var_dump(2 ** 3 ** 2);          // right-associative: 512
$e = -2; var_dump(2 ** $e);
$a = [[1, 2], [3]];
$v = array_values($a);
$v[0][] = 99;
var_dump(count($a[0]));         // array_values copies the nested array
$m = array_merge([[1]], [[2]]);
$m[0][] = 7;
var_dump(count($m[0]));
$p = [1];
var_dump(array_push($p, 1, null), count($p));   // an explicit null counts
var_dump(function_exists('strlen'), function_exists('nope'), function_exists('mine'));
function mine() {}
$o = new stdClass();
var_dump(strlen(spl_object_hash($o)));          // 32 hex characters
function twelve($a,$b,$c,$d,$e2,$f,$g,$h,$i,$j,$k,$l) { return func_num_args(); }
var_dump(twelve(1,2,3,4,5,6,7,8,9,10,11,12));
var_dump(implode(1, ["a","b"]));

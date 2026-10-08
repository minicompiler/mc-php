<?php
// tests/ext.sh step 19b (arrays.php says what): loaded and interpreted, the
// same bytes.
if (!function_exists('arr_rows')) { require __DIR__ . '/arrays.php'; }
var_export(arr_rows(3)); echo "\n";
var_export(arr_grow(3)); echo "\n";
var_export(arr_holes()); echo "\n";
$h = arr_holes(); $h[] = 'more'; $h['a'] = 'A'; var_export($h); echo "\n";
var_export(arr_twice()); echo "\n";
echo json_encode(arr_rows(2)), ' ', count(arr_rows(50)), "\n";
$r = arr_rows(2); $r[0]['name'] = 'mine'; echo $r[0]['name'], ' ', arr_rows(2)[0]['name'], "\n";

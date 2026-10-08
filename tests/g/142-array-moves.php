<?php
// An array local's last read hands the array over instead of copying it
// (src/opt.mc, ph_mv_fn), only where nothing reads it again: the row a loop
// rebuilds every round, and not the row that keeps growing, nor one read
// after the loop. `$a[] = $v` copies $v once (php_arr_pushv), and a string
// key or value goes into the slot with no box (ph_opt_aset). Every answer
// byte for byte php's.
require __DIR__ . '/../ext/arrays/arrays.php';
var_export(arr_rows(3)); echo "\n";
var_export(arr_grow(3)); echo "\n";
var_export(arr_holes()); echo "\n";
var_export(arr_twice()); echo "\n";

function after(): array {
    $o = [];
    for ($i = 0; $i < 2; $i++) { $r = [$i]; $o[] = $r; }
    $r[] = 'after';                            // read after the loop: not moved
    $o[] = $r;
    $o[0][] = 'own';
    return $o;
}
var_export(after()); echo "\n";

function nested(): array {
    $all = [];
    for ($i = 0; $i < 2; $i++) {
        $inner = ['v' => [$i, $i + 1]];
        $all[] = $inner;
    }
    $all[0]['v'][] = 'x';
    return $all;
}
var_export(nested()); echo "\n";

<?php
// tests/ext.sh step 19b: arrays a module builds and hands to php. A row array
// filled with string keys and moved into a list (src/opt.mc's ph_mv_fn and
// ph_opt_aset), a row that keeps growing and so is copied, a numeric string
// key, a deleted element (a hole the engine's array must not keep), nested
// arrays, and the answer made the engine's by its Buckets (lib/php_ext.mc's
// phx_r2e_arr).
function arr_rows(int $n): array {
    $rows = [];
    for ($i = 0; $i < $n; $i++) {
        $row = [];
        $row['id'] = "$i";
        $row['name'] = 'row-' . $i;
        $row['12'] = 'twelve';                 // an int key, 12
        $row["k$i"] = str_repeat('x', $i);
        $rows[] = $row;
    }
    return $rows;
}
function arr_grow(int $n): array {
    $rows = [];
    $row = [];
    for ($i = 0; $i < $n; $i++) {
        $row[] = $i;
        $rows[] = $row;                        // read again next round: copied
    }
    $row[] = 99;
    $rows[] = $row;
    return $rows;
}
function arr_holes(): array {
    $a = ['a' => 1, 'b' => 2, 'c' => 3, 7 => 'seven', 'd' => [1, 2, ['x' => 'y']]];
    unset($a['b']);
    unset($a[7]);
    $a[] = 'next';
    $a['e'] = 'last';
    return $a;
}
function arr_twice(): array {
    $out = [];
    for ($i = 0; $i < 3; $i++) {
        $r = ['i' => $i];
        $out[] = $r;
        $out[] = $r;                           // the second is the last read
    }
    $out[0]['i'] = 'changed';
    return $out;
}

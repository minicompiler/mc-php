<?php
// The T9 bench program: it runs under `php` unchanged and as an mc-php
// binary, and probes/t10/bench/bench.sh times the two interleaved.
// It takes no arguments -- mc-php has no $argv (7 tests in the whole
// corpus want one, which is not enough to build it).
require __DIR__ . "/workload.php";

$rows = wl_make_records(60);
$out  = 0;
$out += wl_json_roundtrip($rows, 3);
$out += wl_render_all($rows, 3);
$out += wl_sort($rows, 3);
echo $out, "\n";

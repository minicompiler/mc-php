<?php
// The same workload without the JSON phase and with ten times the work:
// the JSON round trip is what the 48 MiB arena (D7, no free) cannot hold
// at this size, and this is the program that says what the two are worth
// once php's ~35 ms of start-up is not most of the measurement.
require __DIR__ . "/workload.php";

$rows = wl_make_records(150);
$out  = 0;
$out += wl_render_all($rows, 10);
$out += wl_sort($rows, 10);
echo $out, "\n";

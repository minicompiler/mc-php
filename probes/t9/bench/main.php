<?php
require "workload.php";

$rows = wl_make_records(400);
$phase = $argv[1] ?? "all";
$out = 0;
if ($phase === "json" || $phase === "all") $out += wl_json_roundtrip($rows, 20);
if ($phase === "render" || $phase === "all") $out += wl_render_all($rows, 20);
if ($phase === "sort" || $phase === "all") $out += wl_sort($rows, 20);
echo $out, "\n";

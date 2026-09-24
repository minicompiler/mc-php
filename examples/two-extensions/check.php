<?php
// The differential driver: run TWICE -- once with extA and extB loaded (the
// hand-written pair), once with extA.php and extB.php required -- and the two
// runs must print the same bytes. The order the two are loaded in is the
// gate's business: it runs the native half both ways.
declare(strict_types=1);

if (!extension_loaded('extA')) { require __DIR__ . '/extA.php'; }
if (!extension_loaded('extB')) { require __DIR__ . '/extB.php'; }

var_dump(a_add(2, 3));
var_dump(b_use(2, 3));
var_dump(b_use(-40, 82));
var_dump(b_use(PHP_INT_MAX - 1, 1));
var_dump(function_exists('a_add'), function_exists('b_use'));
$n = 0;
for ($i = 0; $i < 1000; $i++) { $n = b_use($n, $i); }
var_dump($n);

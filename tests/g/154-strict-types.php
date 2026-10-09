<?php
declare(strict_types=1);
// declare(strict_types=1): an argument of a php function must be its declared
// type exactly (an int for a float is the one widening), checked with the
// calling file's mode; a declared return likewise with the declaring file's
// (lib/php_rt.mc PC_STRICT).
function takes_int(int $i): int { return $i * 2; }
function takes_float(float $f): float { return $f / 2; }
function bad_ret(): int { return "5"; }
var_dump(takes_float(3));
foreach (["5", 5.0, true] as $v) {
    try { var_dump(takes_int($v)); } catch (TypeError $e) { echo $e->getMessage(), "\n"; }
}
try { bad_ret(); } catch (TypeError $e) { echo $e->getMessage(), "\n"; }
function outer(string $s): int { return takes_int($s); }
echo outer("5"), "\n";

<?php
// `function &f(): T` returns the callee's CELL whatever T is: the declared
// scalar used to make the return a native value, a copy, so `$r = &f();
// $r = 9;` wrote into nothing (src/decl.mc rdecl). The declared type is still
// php's check on the value, made in the cell (src/lvalue.mc).
function &ref_int(): int { static $v = 5; return $v; }
function &ref_str(): string { static $v = "a"; return $v; }
function &ref_float(): float { static $v = 1.5; return $v; }
function &ref_bool(): bool { static $v = false; return $v; }
function &ref_coerce(): int { static $v = "7"; return $v; }
function &ref_bad(): int { static $v = "x"; return $v; }

$r = &ref_int(); $r = 9; echo ref_int(), "\n";
$s = &ref_str(); $s .= "bc"; echo ref_str(), "\n";
$f = &ref_float(); $f *= 2; echo ref_float(), "\n";
$b = &ref_bool(); $b = true; var_dump(ref_bool());
var_dump(ref_coerce());
$c = &ref_coerce(); $c = 8; var_dump(ref_coerce());
echo ref_int() + 1, "\n";
try { ref_bad(); } catch (TypeError $e) { echo $e->getMessage(), "\n"; }

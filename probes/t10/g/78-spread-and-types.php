<?php
// What php checks before it enters a callee, and what a declared type still
// means when the parameter has a default or the call came first.
function f(...$a) { return count($a); }
try { echo f(...1), "\n"; } catch (\Throwable $e) { echo get_class($e), ": ", $e->getMessage(), "\n"; }
try { echo f(...null), "\n"; } catch (\Throwable $e) { echo get_class($e), ": ", $e->getMessage(), "\n"; }
// the widest spread this compiler emits slots for
echo f(...[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16]), "\n";
// a declared type survives a default
function d(int $x = 1) { return $x; }
echo d(), " ", d(5), " ", d("7"), "\n";
try { d([]); } catch (\Throwable $e) { echo get_class($e), "\n"; }
function ds(string $s = "d") { return $s; }
echo ds(), " ", ds("a"), " ", ds(3), "\n";
function df(float $z = 1.5) { return $z; }
echo df(), " ", df(2), "\n";
// and a declared type survives a call that comes BEFORE the declaration
function caller() { return early(2, "3"); }
function early(int $a, string $b) { return $a . $b; }
echo caller(), "\n";
try { early([], "x"); } catch (\Throwable $e) { echo get_class($e), "\n"; }

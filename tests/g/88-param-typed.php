<?php
// A parameter that KEEPS its declared primitive is handed a native value, so
// the callee cannot see what it was given. php checks at the call, names the
// parameter, and reports the FIRST argument it refuses -- not the last.
function f(int $a) { return $a + 1; }
echo f(41), "\n";
echo f("7"), "\n";
echo f(true), "\n";
try { echo f([]), "\n"; } catch (\Throwable $e) { echo $e->getMessage(), "\n"; }
try { echo f("abc"), "\n"; } catch (\Throwable $e) { echo $e->getMessage(), "\n"; }
try { echo f(null), "\n"; } catch (\Throwable $e) { echo $e->getMessage(), "\n"; }

function s(string $x) { return strtoupper($x); }
echo s("ab"), "\n";
echo s(5), "\n";
try { echo s([]), "\n"; } catch (\Throwable $e) { echo $e->getMessage(), "\n"; }

function d(float $x) { return $x * 2; }
echo d(1.5), "\n";
echo d(3), "\n";
echo d("2.5"), "\n";
try { echo d([]), "\n"; } catch (\Throwable $e) { echo $e->getMessage(), "\n"; }

function b(bool $x) { return $x ? "y" : "n"; }
echo b(1), "\n";
echo b(""), "\n";
try { echo b([]), "\n"; } catch (\Throwable $e) { echo $e->getMessage(), "\n"; }

// two bad arguments: the first one is the one php reports
function two(int $a, int $b) { return $a + $b; }
try { echo two([], []), "\n"; } catch (\Throwable $e) { echo $e->getMessage(), "\n"; }
try { echo two(1, "zz"), "\n"; } catch (\Throwable $e) { echo $e->getMessage(), "\n"; }

// the body must not run on a refused argument
function side(int $a) { echo "BODY\n"; return $a; }
try { echo side([]), "\n"; } catch (\Throwable $e) { echo get_class($e), "\n"; }

// an argument that already has the declared type is passed straight through
function id(int $a): int { return $a; }
$t = 0;
for ($i = 0; $i < 3; $i++) { $t = $t + id($i); }
echo $t, "\n";
echo "end\n";

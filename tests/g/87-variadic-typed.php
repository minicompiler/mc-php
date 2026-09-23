<?php
// A typed variadic: php erases the type for the callee -- $xs IS an array --
// but still checks EVERY argument at the call, by its position in the call and
// with no parameter name in the message. The caller is the only side that has
// the arguments, so the caller is where the check has to happen.
function f(int ...$xs) { return array_sum($xs); }
echo f(1, 2, "3"), "\n";
echo f(), "\n";
try { echo f([]), "\n"; } catch (\Throwable $e) { echo get_class($e), ": ", $e->getMessage(), "\n"; }
try { echo f(1, [2], 3), "\n"; } catch (\Throwable $e) { echo get_class($e), ": ", $e->getMessage(), "\n"; }
try { echo f(1, "abc"), "\n"; } catch (\Throwable $e) { echo get_class($e), ": ", $e->getMessage(), "\n"; }

function g(string ...$s) { return implode("|", $s); }
echo g("a", 2, 3.5), "\n";
try { echo g("a", []), "\n"; } catch (\Throwable $e) { echo get_class($e), ": ", $e->getMessage(), "\n"; }

function h(float ...$n) { return array_sum($n); }
echo h(1, "2.5"), "\n";

// untyped: nothing is checked and an array is an ordinary element
function u(...$a) { return count($a); }
echo u(1, [2, 3], "x"), "\n";

// a fixed parameter in front of the variadic keeps its own name in the message
function m(int $a, string ...$rest) { return $a . ":" . implode(",", $rest); }
echo m(1, "b", "c"), "\n";
try { echo m([], "b"), "\n"; } catch (\Throwable $e) { echo $e->getMessage(), "\n"; }
try { echo m(1, "b", []), "\n"; } catch (\Throwable $e) { echo $e->getMessage(), "\n"; }

// a refused element stops the call: the body must not run
function side(int ...$x) { echo "BODY\n"; return count($x); }
try { echo side(1, []), "\n"; } catch (\Throwable $e) { echo get_class($e), "\n"; }
echo "end\n";

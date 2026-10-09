<?php
// A callback a builtin calls (array_map, array_reduce, usort, uasort, uksort,
// array_filter): php's trace has `#N [internal function]: f(...)` for the
// callback's own frame and the builtin's frame under it. (PR #65 defect 3)
function f($x) { if ($x == 2) throw new Exception("f$x"); return $x * 2; }
class K { function __invoke($x) { throw new Exception("inv"); } }
try { array_map(fn($x) => f($x), [2]); } catch (Exception $e) { echo $e->getTraceAsString(), "\n"; }
try { array_reduce([1, 2], fn($c, $i) => f($i), 0); } catch (Exception $e) { echo $e->getTraceAsString(), "\n"; }
try { $a = [2, 1]; uasort($a, function ($x, $y) { throw new Exception("ua"); }); } catch (Exception $e) { echo $e->getTraceAsString(), "\n"; }
try { $a = [2, 1]; usort($a, fn($x, $y) => $x <=> f(2)); } catch (Exception $e) { echo $e->getTraceAsString(), "\n"; }
try { array_filter([1, 2], fn($x) => f($x)); } catch (Exception $e) { echo $e->getTraceAsString(), "\n"; }
try { array_map(new K, [1]); } catch (Exception $e) { echo $e->getTraceAsString(), "\n"; }
try { $a = ['b' => 1, 'a' => 2]; uksort($a, function ($x, $y) { throw new Exception("uk"); }); } catch (Exception $e) { echo $e->getTraceAsString(), "\n"; }
try { array_map(fn($x) => array_map(fn($y) => f($y), [$x]), [2]); } catch (Exception $e) { echo $e->getTraceAsString(), "\n"; }
$r = array_map(fn($x) => $x + 1, [1, 2]);
echo implode(",", $r), "\n";
function g() { return array_map(fn($x) => f($x), [1, 2]); }
try { g(); } catch (Exception $e) { echo $e, "\n"; }

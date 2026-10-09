<?php
// A builtin given an argument of the wrong type in weak mode: coerced as php's
// ZPP coerces it (with the null and float-to-int deprecations), or php's
// TypeError with the builtin's frame on top of the trace. (PR #65 defect 2)
function t($f) { try { $r = $f(); echo var_export($r, true), "\n"; } catch (Throwable $e) { echo get_class($e), ": ", $e->getMessage(), "\n"; } }
echo "--int\n";
foreach (["12abc", " 12", "12 ", "1.5", "1e3", "abc", "", 1.5, 1e20, NAN, true, null, [], new stdClass] as $v)
  t(fn() => str_repeat("a", $v) === "" ? 0 : strlen(str_repeat("a", $v)));
echo "--float\n";
foreach (["1.5", "abc", "1.5x", true, null, [], 3] as $v) t(fn() => round($v, 0));
echo "--string\n";
foreach ([1.5, true, false, null, [], new stdClass, 7] as $v) t(fn() => strtoupper($v));
echo "--bool\n";
foreach (["abc", "", "0", 1.5, null, [], 2] as $v) t(fn() => json_encode(in_array(1, [1], $v)));
echo "--num\n";
foreach (["1.5", "12", "x", "12x", null, true, [], " 3"] as $v) t(fn() => abs($v));
function tm(mixed $m) {
  try { echo strlen($m), " ", str_repeat("ab", $m), " ", abs($m), "\n"; }
  catch (TypeError $e) { echo get_class($e), ": ", $e->getMessage(), " @", $e->getLine(), "\n", $e->getTraceAsString(), "\n"; }
}
tm(2); tm("3"); tm("1.5"); tm(null); tm([]); tm(2.5); tm(true); tm("x"); tm(" 4");
function ti($f) { try { $r = $f(); echo var_export($r, true), "\n"; } catch (Throwable $e) { echo get_class($e), ": ", $e->getMessage(), "\n", $e->getTraceAsString(), "\n"; } }
function u(mixed $a, mixed $b) { ti(fn() => implode($a, $b)); ti(fn() => join($a, $b)); }
ti(fn() => implode([1,2]));
ti(fn() => implode(",", [1,2]));
ti(fn() => implode([1,2], ","));
ti(fn() => implode(5));
ti(fn() => implode(",", null));
ti(fn() => implode(",", 5));
ti(fn() => join([1], [2]));
u(",", [3]); u([1], [2]); u(",", null); u([1], ","); u(",", 5);
class K implements Countable { function count(): int { return 7; } }
function c(mixed $m) { try { return count($m); } catch (TypeError $e) { echo $e->getMessage(), "\n", $e->getTraceAsString(), "\n"; } }
var_dump(c([1, 2]), c(5), c(null), c("ab"), c(new stdClass), c(new K), sizeof(new K));
ti(fn() => array_sum(null));
ti(fn() => strpos("abc", "c", "1"));
ti(fn() => str_pad("a", "4", 5));
echo implode(",", [1, 2]), " ", str_pad("a", 3, "-"), round(2.5), "\n";

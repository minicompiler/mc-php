<?php
// A spread into a function whose parameters kept a native type (int, float,
// string, bool, array, an `int $b = 10` default, a native ?int) was a named
// compile error. Each value is now checked and converted as an argument
// written out is, a missing required one is php's ArgumentCountError at the
// parameter, an exhausted spread leaves a default in place, and an `array`
// parameter handed a zval that is not one is the TypeError it always was.
function add(int $a, int $b = 10): int { return $a + $b; }
function mix(string $s, float $f, bool $b): string { return $s . ":" . $f . ":" . ($b ? "y" : "n"); }
function opt(?int $x, int $y = 2): string { return ($x === null ? "null" : (string)$x) . "/" . $y; }
function arr(array $a): int { return count($a); }
$cases = [
    fn() => add(...[1, 2]), fn() => add(...[5]), fn() => add(...["7", "8"]), fn() => add(3, ...[4]),
    fn() => add(...[]), fn() => add(...["x"]), fn() => mix(...["a", 1, 1]), fn() => mix(...["a", "2.5", 0]),
    fn() => opt(...[null]), fn() => opt(...[4, 5]), fn() => opt(...["9"]), fn() => opt(...[]), fn() => opt(...["z"]),
    fn() => arr(...[[1, 2, 3]]), fn() => arr(...[5]),
];
foreach ($cases as $n => $t) {
    try { var_dump($t()); } catch (Throwable $e) { echo "$n ", get_class($e), ": ", $e->getMessage(), "\n"; }
}
$m = 5;
function viaz(mixed $v): int { return arr($v); }
try { viaz($m); } catch (TypeError $e) { echo $e->getMessage(), "\n"; }

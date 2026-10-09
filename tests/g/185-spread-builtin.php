<?php
// A spread into a builtin: `array_push($a, ...$v)` and `array_merge(...$x)`
// crashed (the slots a spread did not reach were 0, read as arrays), and a
// builtin of a fixed arity -- strlen, substr, implode, str_replace -- was a
// compile error. The call is now dispatched on the spread's count, each arm
// the call written out; a count php refuses is its ArgumentCountError. A
// first-class callable of a builtin, `strlen(...)`, rides on the same road.
var_dump(array_merge(...[[1], [2]]));
$a = [1]; array_push($a, ...[2, 3]); var_dump($a);
var_dump(array_merge([0], ...[[1], [2]]));
var_dump(min(...[4, 2]), max(...[4, 9]));
$x = [[1], [2]]; var_dump(array_merge(...$x));
var_dump(implode(",", ...[[1, 2]]));
var_dump(substr("abcdef", ...[1, 2]), strlen(...["abc"]), str_replace(...["a", "b", "aaa"]));
$k = strlen(...); var_dump($k("abcd"));
$up = strtoupper(...); var_dump(array_map($up, ["a", "b"]));
foreach ([fn() => strlen(...[]), fn() => strlen(...["a", "b"]), fn() => substr(...["x"]), fn() => implode(...[1, 2, 3]), fn() => array_push(...[])] as $t) {
    try { var_dump($t()); } catch (ArgumentCountError $e) { echo $e->getMessage(), "\n"; }
}

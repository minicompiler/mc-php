<?php
// A php conditional allocates nothing when both branches share a native type
// (docs/plan.md § 7). fib(30) is 1.3 million evaluations: one zval each ran
// the arena out before the fix, and the `if` form of the same function did not.
function fib(int $n): int { return $n < 2 ? $n : fib($n - 1) + fib($n - 2); }
echo fib(30), "\n";

// the value keeps its own type when the branches differ
function pick(bool $c) { return $c ? 1 : "one"; }
var_dump(pick(true), pick(false));
$f = true ? 1.5 : 2.5;
var_dump($f);
$s = strlen("ab") > 1 ? "long" : "short";
var_dump($s);
$b = 0 ? false : true;
var_dump($b);
$n = (1 > 2) ? 1 : ((2 > 1) ? 2 : 3);
var_dump($n);
$m = null;
var_dump($m ?: "default", 0 ?: 7);
// the condition runs once, and only the branch taken runs at all
function probe(string $w): int { echo "[$w]"; return strlen($w); }
$k = probe("cond") > 3 ? probe("then") : probe("else!");
var_dump($k);

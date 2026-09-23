<?php
// php HOISTS a global function declaration: a call may come first
echo f(), "\n";
echo g(3), "\n";
echo h(), "\n";
echo h(9), "\n";
function f() { return 42; }
function g(int $n): int { return $n * 2; }
function h($a = 5, ...$rest) { return $a + count($rest); }
echo g(4), "\n";
function rec($n) { if ($n <= 0) return 0; return $n + rec($n - 1); }
echo rec(4), "\n";
byref($v);
echo $v, "\n";
function byref(&$x) { $x = 7; }

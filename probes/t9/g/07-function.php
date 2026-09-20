<?php
function add(int $a, int $b): int { return $a + $b; }
function greet(string $who): string { return "hello " . $who; }
function fact(int $n): int { if ($n < 2) { return 1; } return $n * fact($n - 1); }
function shout(string $s): void { echo strtoupper($s), "\n"; }
echo add(40, 2), "\n";
echo greet("world"), "\n";
echo fact(6), "\n";
shout("done");

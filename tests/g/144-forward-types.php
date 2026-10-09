<?php
// A call before the declaration (php hoists a global function): the scan
// (src/program.mc, ph_scan_decl) types a parameter it can read exactly -- a
// bare `int $x`, `float $x`, `string $x`, `bool $x` -- so the call passes the
// native value; anything else (a default, `?`, a union, `&`, `...`, a name
// that heads two declarations) stays a zval. php's own coercions and
// TypeErrors, byte for byte.
echo add(2, 3), ' ', add("4", 5), ' ', cat("a", 7), ' ', half(3), ' ', flag(1), ' ', flag(""), "\n";
echo opt(1), ' ', opt(1, 9), ' ', nul(null), ' ', nul(4), ' ', uni(2), ' ', uni("s"), "\n";
$v = 1; bump($v); echo $v, ' ', sum(1, 2, 3), ' ', twice(5), "\n";
try { echo add([], 1); } catch (TypeError $e) { echo get_class($e), ': ', $e->getMessage(), "\n"; }
try { echo half("x"); } catch (TypeError $e) { echo get_class($e), ': ', $e->getMessage(), "\n"; }

function add(int $a, int $b): int { return $a + $b; }
function cat(string $s, int $n): string { return $s . $n; }
function half(float $x): float { return $x / 2; }
function flag(bool $b): string { return $b ? 'T' : 'F'; }
function opt(int $a, int $b = 2): int { return $a * $b; }
function nul(?int $a): string { return $a === null ? 'null' : (string) ($a + 1); }
function uni(int|string $a): string { return gettype($a); }
function bump(&$a): void { $a = $a + 1; }
function sum(int ...$xs): int { return array_sum($xs); }
class K { function twice(string $s): string { return $s . $s; } }
function twice(int $n): int { return $n * 2; }

<?php
// tests/ext.sh step 17: a module whose signatures go beyond the scalars --
// arrays, objects, a class, a callable, nullable, a default, variadics -- and
// the engine's arrays and objects inside it (lib/php_ext.mc § engine values).
// check.php runs it loaded and interpreted and the two must agree; the
// errors are an internal function's own words (errors.expect).
namespace xa;
function sum(array $a): int { $s = 0; foreach ($a as $v) { $s += (int) $v; } return $s; }
function keys(array $a): array { return array_keys($a); }
function wrap(mixed $v): array { return ['v' => $v, 'n' => [1, 2]]; }
function pass(object $o): object { return $o; }
function cls(object $o): string { return get_class($o) . " " . ($o instanceof \ArrayAccess ? "aa" : "-") . " " . ($o instanceof \stdClass ? "std" : "-"); }
function prop(object $o): mixed { $o->y = $o->x + 1; return $o->y; }
function meth(object $o): string { return $o->m("q"); }
function va(string $sep, mixed ...$xs): string { return implode($sep, $xs); }
function cnt(int ...$xs): int { return count($xs); }
function cb(callable $f): mixed { return $f; }
function dflt(int $a, int $b = 5): int { return $a + $b; }
function nul(?array $a): string { return $a === null ? "null" : "arr"; }
function ser(array $a): string { return serialize($a); }
function unser(string $s): array { return unserialize($s); }
function same(object $a, object $b): bool { return $a === $b; }
function typed(\ArrayObject $o): string { return get_class($o); }

<?php
// tests/ext.sh step 19: a module that CALLS a php callable it was handed --
// a function's name, an array callable, an engine closure, an __invoke
// object, a spread -- and a throwable crossing both ways: what the callable
// throws is the module's to catch, and a throwable the module keeps goes back
// to php as the engine's object of that class (lib/php_ext.mc's phx_vcall
// and phx_exc_obj). check.php runs it loaded and interpreted and the two must
// agree byte for byte.
namespace pk;
function call(callable $fn, mixed ...$args): mixed { return $fn(...$args); }
function call1(callable $fn, mixed $a): mixed { return $fn($a); }
function callm(mixed $fn): mixed { return $fn(); }
function caught(callable $fn): string {
    try { $fn(); return "no"; } catch (\Throwable $e) { return get_class($e) . ": " . $e->getMessage(); }
}
function keep(): \Throwable { return new \RuntimeException("mine", 7); }
function wrapped(callable $fn): array {
    try { $fn(); } catch (\Throwable $e) { return ['e' => $e]; }
    return [];
}
function named(string $s): string { $f = 'strrev'; return $f($s) . ('str' . 'toupper')($s); }

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
// a throwable class the engine does not know (module-private): it crosses as a
// plain Exception naming it, which the interpreted source does not print, so
// check.php leaves it to tests/leaks.sh's workload
class _Oops extends \RuntimeException {}
function oops(): \Throwable { return new _Oops("own", 4); }
function thrown(): int { throw new _Oops("up"); }
// An arrow function captures, by value at its creation, the variables its
// body names and no other (tests/g/123-arrow-capture.php is the program
// road's copy): arrow_odd's $e is never assigned on the even path, and is not
// read.
function arrow_odd(int $n): int {
    try {
        if ($n % 2) throw new \RuntimeException("odd");
    } catch (\RuntimeException $e) {
        return -1;
    }
    $f = fn(int $x): int => $x * 2;
    return $f($n);
}
function arrow_spoil(): int { $a = 1; $b = 2; $c = 3; $d = 4; $q = 5; return $a + $b + $c + $d + $q; }
function arrow_later(): string {
    $a = 1;
    $f = fn(): int => $a + 10;
    $a = 5;
    return $f() . " " . $a;
}
function arrow_nested(): int {
    $k = 3;
    $f = fn(int $x): int => (fn(int $y): int => $y + $k)($x) * 2;
    return $f(4);
}

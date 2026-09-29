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
// A closure's parameter is its own variable (tests/g/124-closure-shadow.php
// is the program road's copy): not captured over, and what a nested arrow
// function captures is its outer arrow function's parameter.
function shadow_a(): int { $x = 100; $f = fn($x) => fn() => $x * 2; return $f(5)(); }
function shadow_b(): int { $x = 999; $g = fn() => fn($x) => $x + 1; return $g()(1); }
function shadow_c(): int { $x = 1; $f = fn($x) => fn($y) => $x + $y; return $f(10)(5); }
function shadow_d(): int { $x = 5; $y = 1; $f = function ($x) use ($y) { return $x + $y; }; return $f(10) + $x; }
function shadow_wide(): int {
    $v1 = 1; $v2 = 2; $v3 = 3; $v4 = 4; $v5 = 5; $v6 = 6; $v7 = 7; $v8 = 8; $v9 = 9;
    $v10 = 10; $v11 = 11; $v12 = 12; $v13 = 13; $v14 = 14; $v15 = 15; $v16 = 16; $v17 = 17;
    $g = fn() => $v17 + $v1;
    return $g();
}
// A closure written inside a try block is a function of its own
// (tests/g/127-closure-in-try.php is the program road's copy): its throw
// does not break out of the try around its definition.
function try_closure(string $m): string {
    try {
        $f = function (string $m): int { if ($m === "ok") return 1; throw new \LogicException($m); };
        return "ret " . $f($m);
    } catch (\LogicException $e) {
        return "caught " . $e->getMessage();
    }
}
function try_finally(): string {
    try {
        $c = function (int $m): int { try { throw new \LogicException("through $m"); } finally { echo "closure finally\n"; } };
        try { $c(3); } catch (\LogicException $e) { return "caught " . $e->getMessage(); }
        return "none";
    } finally {
        echo "outer finally\n";
    }
}
// A top-level read of a name only a function's `global` creates is the
// global (tests/g/128-global-toplevel.php is the program road's copy).
function tg_set(int $v): void { global $tg; $tg = $v; }
tg_set(41);
$tg_seen = $tg + 1;
$tg_str = "seen $tg";
function top_global(): string { global $tg_seen, $tg_str; return $tg_seen . " " . $tg_str; }

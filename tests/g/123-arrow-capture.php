<?php
// An arrow function captures, by value and at its creation, the enclosing
// variables its body names -- and only those. One its body does not name is
// never read: in g(), $e, which the catch did not assign on this path (it
// used to be copied anyway, out of an unset slot, and the program died).
function g(int $n): int {
    try {
        if ($n % 2) throw new RuntimeException("odd");
    } catch (RuntimeException $e) {
        return -1;
    }
    $f = fn(int $x): int => $x * 2;
    return $f($n);
}
// leaves the stack below it dirty, so g()'s unset slot is not a lucky zero
function spoil(): int { $a = 1; $b = 2; $c = 3; $d = 4; $q = 5; return $a + $b + $c + $d + $q; }
function later(): string {
    $a = 1;
    $f = fn(): int => $a + 10;
    $a = 5;
    return $f() . " " . $a;
}
function nested(): int {
    $k = 3;
    $f = fn(int $x): int => (fn(int $y): int => $y + $k)($x) * 2;
    return $f(4);
}
echo spoil(), " ", g(2), " ", g(1), "\n";
echo later(), "\n";
echo nested(), "\n";

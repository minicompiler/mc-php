<?php
// A match arm's conditions and value, and the right side of ??=, run only when
// they are reached. The statements an expression needs ahead of itself (a ??
// temporary, a call's check) were emitted in front of the WHOLE match or ??=,
// so every arm's `f(...) ?? x` ran for every subject, and `$a ??= f() ?? 1`
// called f() with $a set. A `default` written before other arms is still the
// last resort. `??=` on a variable with a native type (never null) does
// nothing -- it used to be a "not implemented" compile error.
function f(string $s): ?int { echo "f($s) "; return null; }
function m(int $x): mixed {
    return match ($x) {
        1 => f("one") ?? 10,
        2, f("cond") ?? 3 => f("two") ?? 20,
        default => 0,
    };
}
foreach ([1, 2, 3, 9] as $v) { var_dump(m($v)); }
function h(int $x): string { return match ($x) { default => "dflt", 1 => "one", f("late") ?? 4 => "four" }; }
foreach ([1, 4, 5] as $v) { var_dump(h($v)); }
function nomatch(int $x): string {
    try { return match ($x) { 1 => "one", f("c2") ?? 2 => "two" }; }
    catch (\UnhandledMatchError $e) { return get_class($e) . ": " . $e->getMessage(); }
}
var_dump(nomatch(1), nomatch(7));
function coal(): array {
    $a = 5; $a ??= f("int") ?? 1;
    $s = "x"; $s ??= "y";
    $m = null; $m ??= f("m") ?? 7;
    $n = 3 > 2 ? 8 : null; $n ??= f("n") ?? 9;
    $u ??= 11;
    return [$a, $s, $m, $n, $u];
}
var_dump(coal());

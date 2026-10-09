<?php
// `throw` as an expression (php 8): in a ??, a ?:, either branch of a
// conditional, an arrow function's body, a match arm, a function's argument,
// the right side of || / && and of ??=, inside a try with a finally, in a
// method. It used to be a compile error at the `new` that followed it. The
// throw runs only on the branch it is in; a conditional with a throwing
// branch keeps the other branch's native type.
declare(strict_types=1);

function a(?int $y): int { $x = $y ?? throw new InvalidArgumentException("null y"); return $x + 1; }
function b(int $v): int { $x = $v ?: throw new RuntimeException("zero"); return $x; }
function c(bool $c): string { return $c ? "yes" : throw new LogicException("no"); }
function d(bool $c): int { return $c ? throw new LogicException("yes") : 7; }
function g(int $x): string { return match ($x) { 1 => "one", 2 => "two", default => throw new UnexpectedValueException("bad $x") }; }
function arg(?int $v): int { return intdiv($v ?? throw new ArgumentCountError("no v"), 2); }
function orx(bool $ok): string { $ok || throw new RuntimeException("not ok"); return "fine"; }
function andx(bool $bad): string { $bad && throw new RuntimeException("bad"); return "fine"; }
function coal(): mixed { $a = null; $a ??= throw new LengthException("unset"); return $a; }
function fin(int $x): string {
    try { return "v" . ($x > 0 ? (string)$x : throw new Exception("neg")); }
    catch (Exception $e) { return "caught " . $e->getMessage(); }
    finally { echo "[finally] "; }
}
class C { public function m(?string $s): string { return $s ?? throw new TypeError("null s"); } }

$f = fn(int $n): int => $n > 0 ? $n : throw new DomainException("neg $n");
$always = fn() => throw new Exception("always");
$e0 = new OverflowException("prebuilt");
foreach ([fn() => a(4), fn() => a(null), fn() => b(5), fn() => b(0), fn() => c(true), fn() => c(false),
          fn() => d(true), fn() => d(false), fn() => g(1), fn() => g(3), fn() => arg(9), fn() => arg(null),
          fn() => orx(true), fn() => orx(false), fn() => andx(false), fn() => andx(true),
          fn() => coal(), fn() => fin(4), fn() => fin(-1), fn() => (new C)->m("x"), fn() => (new C)->m(null),
          fn() => $f(3), fn() => $f(-2), $always, fn() => null ?? throw $e0] as $t) {
    try { var_dump($t()); } catch (Throwable $e) { echo get_class($e), ": ", $e->getMessage(), "\n"; }
}
// at the top level, and a throw that is never reached
$ok = 3 ?? throw new Exception("unreached");
echo $ok, "\n";
try { $q = null ?? throw new Exception("top"); echo "not here\n"; }
catch (Exception $e) { echo "top-level: ", $e->getMessage(), "\n"; }

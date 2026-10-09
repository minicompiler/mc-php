<?php
// A method's, a closure's and an arrow function's declared return type is
// checked as a function's is: php's weak coercion, its TypeError, its
// deprecations. (PR #65 defect 4)
class C {
  function a(): int { return "5"; }
  function b(): int { return "x"; }
  function c(): string { return 5; }
  function d(): ?int { return null; }
  function e(): float { return 3; }
  function f(): bool { return 0; }
  static function g(): int { return 2.0; }
  function h(): int { return 2.5; }
  function i(): array { return 1; }
  function j(): int { }
  function k(): void { return; }
  function l(): mixed { return 1; }
  function m(): static { return $this; }
  function n(): self { return $this; }
  function o(): int|string { return 1.5; }
  function p(): iterable { return [1]; }
  function q(): ?string { return 7; }
}
function t($f) { try { var_dump($f()); } catch (Throwable $e) { echo get_class($e), ": ", $e->getMessage(), "\n"; } }
$c = new C;
t(fn() => $c->a()); t(fn() => $c->b()); t(fn() => $c->c()); t(fn() => $c->d()); t(fn() => $c->e());
t(fn() => $c->f()); t(fn() => C::g()); t(fn() => $c->h()); t(fn() => $c->i()); t(fn() => $c->j());
t(fn() => $c->k()); t(fn() => $c->l()); t(fn() => get_class($c->m())); t(fn() => get_class($c->n())); t(fn() => $c->o());
t(fn() => $c->p()); t(fn() => $c->q());
$cl = function (): int { return "7"; }; t($cl);
$cl2 = function (): int { return "z"; }; t($cl2);
$ar = fn(): string => 12; t($ar);
$ar2 = fn(): int => []; t($ar2);
$cl3 = function (): void { }; t($cl3);
class Foo {}
function a(): ?int { return "5"; }
function b(): ?int { return null; }
function c2(): int|string { return 1.5; }
function d(): Foo { return 5; }
function e(): ?string { return 7; }
function f(): iterable { return 1; }
function g(): object { return 1; }
function h(): never { throw new Exception("n"); }
function i(): int { }
t(fn() => a()); t(fn() => b()); t(fn() => c2()); t(fn() => d()); t(fn() => e()); t(fn() => f()); t(fn() => g()); t(fn() => h()); t(fn() => i());

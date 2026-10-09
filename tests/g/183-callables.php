<?php
// Callables D6 keeps (docs/plan.md: a literal method name is dispatch, not
// reflection): an array callable `[$o, 'm']` / `[C::class, 'm']` called as
// `$c(...)` or handed to a builtin (usort, array_map) -- with the calling
// scope's visibility -- Closure::fromCallable, and php 8.1's first-class
// callable syntax `f(...)`, `$o->m(...)`, `C::m(...)`, `$closure(...)`.
// They were a parse error, "Value not callable", or a crash.
function add(int $a, int $b = 10): int { return $a + $b; }
function many(...$x) { return implode(",", $x); }
class S {
    private int $k = 3;
    private function cmp($a, $b) { return $a <=> $b; }
    public static function dbl($x) { return $x * 2; }
    public function mul($x) { return $x * $this->k; }
    public function run() { $a = [3, 1, 2]; usort($a, [$this, 'cmp']); return $a; }
    public function m2() { return array_map([self::class, 'dbl'], [1, 2]); }
    public function priv() { return Closure::fromCallable([$this, 'cmp']); }
    public function sum(int ...$xs): int { return array_sum($xs); }
    public function __invoke($x) { return "inv$x"; }
}
$o = new S;
var_dump($o->run(), $o->m2());
$c = [$o, 'mul']; var_dump($c(5));
$d = [S::class, 'dbl']; var_dump($d(5));
$e = ['S', 'dbl']; var_dump($e(6));
$f = Closure::fromCallable([$o, 'mul']); var_dump($f(2));
$g = $o->mul(...); var_dump($g(4));
$h = S::dbl(...); var_dump($h(7));
$i = add(...); var_dump($i(1), $i(1, 2));
$j = many(...); var_dump($j(1, 2, 3, 4, 5, 6, 7));
$l = $o->sum(...); var_dump($l(1, 2, 3, 4, 5, 6, 7, 8));
$m = Closure::fromCallable($o); var_dump($m("!"));
$p = $o->priv(); var_dump($p(1, 2));
var_dump(array_map($o->mul(...), [1, 2]), array_map([$o, 'mul'], [3]));
$n = fn($x) => $x + 1; $q = $n(...); var_dump($q(1));
foreach ([fn() => [1, 2, 3](), fn() => [$o, 'nope'](), fn() => [$o](), fn() => Closure::fromCallable([$o, 'nope']), fn() => (new S)->priv() && [$o, 'cmp'](1, 2)] as $t) {
    try { var_dump($t()); } catch (Throwable $ex) { echo get_class($ex), ": ", $ex->getMessage(), "\n"; }
}

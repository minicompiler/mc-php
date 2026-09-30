<?php
// tests/ext.sh step 19 (callables.php says what): loaded and interpreted, the
// same bytes.
if (!function_exists('pk\call')) { require __DIR__ . '/callables.php'; }
class Inv { public function __invoke($x) { return $x * 2; } }
class Svc { public function shout(string $s): string { return strtoupper($s) . "!"; }
            public static function twice(int $n): int { return $n * 2; } }
var_dump(pk\call('strtoupper', 'intent'));
var_dump(pk\call1('strrev', 'abc'));
var_dump(pk\named("abc"));
var_dump(pk\call([new ArrayObject([1, 2, 3]), 'count']));
var_dump(pk\call([new Svc, 'shout'], 'hi'));
var_dump(pk\call('Svc::twice', 21));
var_dump(pk\call(fn($a, $b) => $a . $b, 'x', 'y'));
var_dump(pk\call(new Inv, 21));
var_dump(pk\call(function (...$xs) { return count($xs); }, 1, 2, 3, 4));
var_dump(pk\call(function () { return func_num_args(); }));
var_dump(pk\caught(function () { throw new LogicException("lx"); }));
var_dump(pk\caught(fn() => intdiv(1, 0)));
$e = pk\keep();
var_dump(get_class($e), $e->getMessage(), $e->getCode(), $e instanceof Throwable);
$w = pk\wrapped(function () { throw new DomainException("kept", 3); });
var_dump(get_class($w['e']), $w['e']->getMessage(), $w['e']->getCode());
foreach (['nope', new stdClass, 5, null] as $bad) {
    try { pk\callm($bad); } catch (Error $x) { echo get_class($x), ": ", $x->getMessage(), "\n"; }
}
echo pk\arrow_spoil(), " ", pk\arrow_odd(2), " ", pk\arrow_odd(1), " ", pk\arrow_later(), " ", pk\arrow_nested(), "\n";
echo pk\shadow_a(), " ", pk\shadow_b(), " ", pk\shadow_c(), " ", pk\shadow_d(), " ", pk\shadow_wide(), "\n";
echo pk\try_closure("ok"), " ", pk\try_closure("bad"), " ", pk\try_finally(), "\n";
echo pk\top_global(), "\n";
echo pk\top_global2(), "\n";

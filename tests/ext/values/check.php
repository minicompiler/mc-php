<?php
// tests/ext.sh step 17 (values.php says what): everything up to the errors is
// compared with the interpreted source, the errors with errors.expect.
if (!function_exists('xa\sum')) { require __DIR__ . '/values.php'; }
class M { public $x = 4; public $y; public function m($s) { return "m:$s"; } }
echo xa\sum([1, 2, 3]), "\n";
var_dump(xa\keys(['a' => 1, 5 => 2, 'b' => [3]]));
var_dump(xa\wrap(new M));
$o = new M; var_dump(xa\pass($o) === $o);
echo xa\cls(new \stdClass), " | ", xa\cls(new \ArrayObject([])), "\n";
$m = new M; echo xa\prop($m), " ", $m->y, "\n";
echo xa\meth(new M), "\n";
echo xa\va(",", 1, "b", 2.5), " ", xa\cnt(), " ", xa\cnt(1, 2, 3), "\n";
var_dump(xa\cb('strlen'));
echo xa\dflt(1), " ", xa\dflt(1, 2), "\n";
echo xa\nul(null), " ", xa\nul([]), "\n";
echo xa\ser(['a' => [1, true, null]]), "\n";
var_dump(xa\unser('a:2:{i:0;s:1:"x";s:1:"k";a:1:{i:0;d:1.5;}}'));
echo var_export(xa\same($o, $o), true), var_export(xa\same($o, new M), true), "\n";
echo xa\typed(new \ArrayObject([1, 2])), "\n";
foreach ([fn() => xa\sum(1), fn() => xa\cnt("x"), fn() => xa\cb('nope'), fn() => xa\typed(new M), fn() => xa\dflt(), fn() => xa\dflt(1, 2, 3), fn() => xa\nul(1)] as $f) {
    try { $f(); } catch (\Throwable $e) { echo get_class($e), ": ", $e->getMessage(), "\n"; }
}

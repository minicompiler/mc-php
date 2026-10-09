<?php
// ++ and -- on every type, php 8.5's answers: null-- and ++/-- on a bool warn
// and keep the value, "" decrements to -1 with a deprecation, an array or an
// object is a TypeError -- on a zval (lib/php_rt.mc php_zv_inc/php_zv_dec)
// and on a variable the compiler holds natively (src/expr.mc ph_incdec_other).
function show(string $what, $v) { echo $what, " => "; var_dump($v); }
$vals = ['null' => null, 'true' => true, 'false' => false, 'empty' => "", 'num' => "5",
         'alpha' => "az", 'dot' => ".", 'arr' => [1], 'obj' => new stdClass, 'int' => 7, 'dbl' => 2.5];
foreach ($vals as $k => $v) {
    foreach (['++', '--'] as $op) {
        $x = $v;
        try { if ($op === '++') { $x++; } else { $x--; } show("$k$op", $x); }
        catch (TypeError $e) { echo "$k$op ", get_class($e), ": ", $e->getMessage(), "\n"; }
    }
}
$n = null; --$n; var_dump($n);
$t = true; $t++; var_dump($t);
$f = false; --$f; var_dump($f);
$b = true; $c = ++$b; var_dump($c);
$a = [1]; try { $a++; } catch (TypeError $e) { echo $e->getMessage(), "\n"; }
class P {}
$o = new P; try { --$o; } catch (TypeError $e) { echo $e->getMessage(), "\n"; }
function g(mixed $m): mixed { return --$m; }
var_dump(g(null));

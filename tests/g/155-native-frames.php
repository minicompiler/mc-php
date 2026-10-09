<?php
// Three things a trace and a position owe php, each against php's own answer:
//  * a builtin that raises is the innermost frame, at the caller's line, with
//    its arguments (lib/php_rt.mc php_nat_throw) -- intdiv, str_repeat,
//    array_fill on both of its roads, str_decrement, str_replace, settype,
//    func_get_arg with both of its messages;
//  * a user call's frame is built inside the expression (src/builtin.mc
//    ph_fr_wrap): nothing left of the call moves behind it, an argument that
//    throws is not inside it, a call copied in (src/opt.mc) keeps it, and a
//    left operand runs before a right one's hoisted temporaries
//    (src/expr.mc ph_spill_left);
//  * the position comes back when a call returns (php_fr_pop), and an arrow
//    function's body announces its own;
//  * a frame shows the arguments PASSED: a variadic one element by element,
//    a native nullable one as NULL, no default the caller left out;
//  * class_alias of a class that does not exist is php's warning and false.
function f(int $a, int $b): int { return intdiv($a, $b); }
function d(int $a, int $b): int { return intdiv($a, $b); }
function e(int $a, float $x, string $s): int { return d($a, strlen($s)) + (int) $x; }
function sq(int $a): int { return $a * $a; }
function p(int $x): int { echo "p$x\n"; return $x; }
function w(int $x): int { echo "w$x\n"; return $x * 2; }
function g($a, $b) { return func_get_arg(5); }
function h($a) { return func_get_arg(-1); }
function two($x, $y) { echo "two ran\n"; return 1; }
function vv(int $a, ...$r) { throw new Exception("v"); }
function oo(?int $x, int $y = 4, ?string $s = null) { throw new Exception("o"); }
function ff(float $f, bool $b, array $a) { throw new Exception("f"); }

foreach ([fn() => f(7, 0), fn() => str_repeat("ab\n\t\x01", -1), fn() => array_fill(0, -2, 1),
          fn() => array_fill(5, -1, 'v'), fn() => str_decrement(""), fn() => str_decrement("a-"),
          fn() => intdiv(PHP_INT_MIN, -1), fn() => str_replace('a', ['b'], 'abc'),
          fn() => g(1, 2), fn() => h(1), fn() => 7 % 0] as $c) {
    try { $c(); } catch (Throwable $ex) { echo get_class($ex), ": ", $ex->getMessage(), " @", $ex->getLine(), "\n", $ex->getTraceAsString(), "\n"; }
}
$v = null;
try { settype($v, 'nope'); } catch (ValueError $ex) { echo $ex->getMessage(), "\n", $ex->getTraceAsString(), "\n"; }

try { $r = two(intdiv(1, 0), 3); } catch (Throwable $ex) { echo $ex->getTraceAsString(), "\n"; }
try { $r = two(4, intdiv(1, 0)); } catch (Throwable $ex) { echo $ex->getTraceAsString(), "\n"; }

echo p(5) . w(6) . intdiv(9, p(3)), "\n";
$v2 = p(1) + intdiv(8, p(2)) * w(4);
echo $v2, "\n";
try { $t = p(9) + intdiv(1, p(0)); } catch (DivisionByZeroError $ex) { echo "caught at ", $ex->getLine(), "\n"; }

$t = 0;
for ($i = 3; $i >= 0; $i--) {
    try { $t += e(10, 1.5, str_repeat("z", $i)) + sq($i); echo $t, "\n"; }
    catch (DivisionByZeroError $ex) { echo $ex->getLine(), "\n", $ex->getTraceAsString(), "\n"; }
}
echo sq(sq(3)), "\n";

$n = null; $k = 7;
foreach ([fn() => vv(1, 'x', 2.5), fn() => vv(2), fn() => oo($n), fn() => oo($k, 5, "s"), fn() => oo(null, 1),
          fn() => ff(0.1, true, [1])] as $c) {
    try { $c(); } catch (Exception $ex) { echo $ex->getMessage(), "\n", $ex->getTraceAsString(), "\n"; }
}
var_dump(class_alias('NoSuchClass', 'Other'));

$af = fn() => intdiv(1, 0);
try { $af(); } catch (Throwable $ex) { echo "arrow at ", $ex->getLine(), "\n"; }
echo intdiv(1, 0);

<?php
// C semantics, the default (docs/semantics.md): + - * on an int wrap as C's
// do and nothing is thrown or promoted to float. What C would trap on still
// throws: a division or a modulo by zero, and intdiv(PHP_INT_MIN, -1).
function add(int $a, int $b): int { return $a + $b; }
function el(int $n): string {
    $x = array_fill(0, 3, 0);
    $x[0] = $n;
    $x[1] = $x[0] + 1;
    $x[2] = $x[0] * 3;
    return $x[1] . " " . $x[2] . " " . (-$x[1]) . " " . ($x[1] - $x[0]);
}
echo add(PHP_INT_MAX, 1), " ", add(PHP_INT_MIN, -1), "\n";
echo el(5), "\n";
echo el(PHP_INT_MAX), "\n";
try { echo intdiv(PHP_INT_MIN, -1), "\n"; } catch (ArithmeticError $e) { echo get_class($e), ": ", $e->getMessage(), "\n"; }
try { echo intdiv(1, 0), "\n"; } catch (DivisionByZeroError $e) { echo get_class($e), ": ", $e->getMessage(), "\n"; }
try { $z = 0; echo 7 % $z, "\n"; } catch (DivisionByZeroError $e) { echo get_class($e), ": ", $e->getMessage(), "\n"; }

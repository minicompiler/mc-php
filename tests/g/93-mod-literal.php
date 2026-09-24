<?php
// `%` by a literal the compiler can see is positive lowers to mc's own `%`
// and no call -- so the statement around it needs neither php_pos nor
// php_thrown. This checks the answers are still php's, at the edges where a
// native remainder and php's could part company, and that the divisor forms
// the fold does NOT take are unchanged: a variable, a zero, a negative.

function m(int $a, int $b): int { return $a % $b; }

echo 7 % 3, " ", m(7, 3), "\n";
echo -7 % 3, " ", m(-7, 3), "\n";
echo 7 % -3, " ", m(7, -3), "\n";
echo -7 % -3, " ", m(-7, -3), "\n";
echo 0 % 5, " ", m(0, 5), "\n";
echo PHP_INT_MIN % 7, " ", m(PHP_INT_MIN, 7), "\n";
echo PHP_INT_MAX % 7, " ", m(PHP_INT_MAX, 7), "\n";
echo PHP_INT_MIN % 1, " ", m(PHP_INT_MIN, 1), "\n";
echo PHP_INT_MIN % -1, " ", m(PHP_INT_MIN, -1), "\n";

// the throw still throws, on the line it is on, both ways round
try { echo 1 % 0; } catch (DivisionByZeroError $e) { echo $e->getMessage(), " @", $e->getLine(), "\n"; }
$z = 0;
try { echo 1 % $z; } catch (DivisionByZeroError $e) { echo $e->getMessage(), " @", $e->getLine(), "\n"; }

// PHP_INT_MIN by -1, the one quotient an i64 cannot hold: php answers 0 for
// the remainder, a float for the division and an ArithmeticError for intdiv,
// and an x86-64 `idiv` answers SIGFPE for all three.
$mn = PHP_INT_MIN;
$m1 = -1;
echo $mn % $m1, "\n";
echo $mn / $m1, "\n";
echo PHP_INT_MIN / -1, "\n";
try { echo intdiv(PHP_INT_MIN, -1), "\n"; }
catch (ArithmeticError $e) { echo get_class($e), ": ", $e->getMessage(), "\n"; }
echo intdiv(PHP_INT_MIN, 2), " ", intdiv(-7, 2), " ", intdiv(7, -2), "\n";

// a compound assignment takes the same road
$k = 17;
$k %= 5;
echo $k, "\n";

// in a loop, which is the shape the fold exists for
$s = 0;
for ($i = 0; $i < 10; $i = $i + 1) { $s = $s + $i % 4; }
echo $s, "\n";

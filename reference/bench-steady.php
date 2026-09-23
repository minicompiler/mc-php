<?php
// The same two functions reference/bench.php times, with a warm-up and the
// BEST of N. reference/bench.php times one cold call each, which on this host
// carries a code-alignment band of up to 2.5x on sum(): two builds of the same
// source differing only in the module's NAME measured 5.9 and 1.9 ms.
function php_fib(int $n): int { return $n < 2 ? $n : php_fib($n-1) + php_fib($n-2); }
function php_sum(int $n): int { $s = 0; for ($i=1;$i<=$n;$i++) $s += $i % 7; return $s; }
$N = 30; $M = 3000000; $R = 9;
if (php_fib($N) !== mcb_fib($N) || php_sum($M) !== mcb_sum($M)) { echo "MISMATCH\n"; exit(1); }
function best(callable $f, int $a, int $r): float {
    $f($a); $b = INF;
    for ($i = 0; $i < $r; $i++) { $t = hrtime(true); $f($a); $d = (hrtime(true)-$t)/1e6; if ($d < $b) $b = $d; }
    return $b;
}
$p1 = best('php_fib', $N, $R); $m1 = best('mcb_fib', $N, $R);
$p2 = best('php_sum', $M, $R); $m2 = best('mcb_sum', $M, $R);
printf("fib(%d)       interpreted %6.2f ms   compiled %6.2f ms   %5.2fx\n", $N, $p1, $m1, $p1/$m1);
printf("sum(%d)  interpreted %6.2f ms   compiled %6.2f ms   %5.2fx\n", $M, $p2, $m2, $p2/$m2);

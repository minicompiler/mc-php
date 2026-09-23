<?php
declare(strict_types=1);
function php_fib(int $n): int { return $n < 2 ? $n : php_fib($n-1) + php_fib($n-2); }
function php_sum(int $n): int { $s = 0; for ($i=1;$i<=$n;$i++) $s += $i % 7; return $s; }
$N = 30; $M = 3000000;
$a = php_fib($N); $b = mcb_fib($N);
$c = php_sum($M); $d = mcb_sum($M);
if ($a !== $b || $c !== $d) { echo "MISMATCH fib $a/$b sum $c/$d\n"; exit(1); }
echo "agree: fib($N)=$a sum($M)=$c\n";
$t=hrtime(true); php_fib($N); $p1=(hrtime(true)-$t)/1e6;
$t=hrtime(true); mcb_fib($N); $m1=(hrtime(true)-$t)/1e6;
$t=hrtime(true); php_sum($M); $p2=(hrtime(true)-$t)/1e6;
$t=hrtime(true); mcb_sum($M); $m2=(hrtime(true)-$t)/1e6;
printf("fib(%d)  interpreted %7.1f ms   compiled %7.1f ms   %5.1fx\n", $N, $p1, $m1, $p1/$m1);
printf("sum(%d) interpreted %7.1f ms   compiled %7.1f ms   %5.1fx\n", $M, $p2, $m2, $p2/$m2);

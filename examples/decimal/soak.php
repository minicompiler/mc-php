<?php
// The memory gate: N calls of dec_add in ONE request, and what php's own
// allocator says before and after. Every string the module builds inside a
// call is a Zend block the call frees when it returns, so the peak must not
// grow with N (docs/php-extension.md § The memory). Before batch A the module
// had a fixed arena instead and died with `mc-php: arena exhausted` between
// 28 000 and 30 000 calls.
//
//     php -d extension=build/decimal.so soak.php 1000000
declare(strict_types=1);

if (!extension_loaded('decimal')) {
    require __DIR__ . '/decimal.php';
}
$n = (int) ($argv[1] ?? 1000000);
$acc = '0';
dec_add($acc, '1', 2);                        // warm: literals, first-call state
$u0 = memory_get_usage();
$p0 = memory_get_peak_usage();
for ($i = 0; $i < $n; $i++) {
    $acc = dec_add($acc, '12.5', 2);
}
$u1 = memory_get_usage();
$p1 = memory_get_peak_usage();
printf("calls %d  result %s  usage %d -> %d  peak %d -> %d\n", $n, $acc, $u0, $u1, $p0, $p1);

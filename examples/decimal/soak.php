<?php
// The memory gate: N calls of dec_add in ONE request, and what php's own
// allocator says before and after. Every string the module builds is a Zend
// block of its own, freed when its last reference goes -- a temporary at the
// end of the loop iteration or the return that used it -- so the peak must not
// grow with N (docs/php-extension.md § The memory). Before batch A the module
// had a fixed arena instead and died with `mc-php: arena exhausted` between
// 28 000 and 30 000 calls.
//
// What the peak DOES follow is the size of a call's own temporaries, and those
// grow with the accumulator: 12500.00 after the warm-up, 12500000.00 after a
// million calls, three digits that move a few of them into the next 8-byte
// size class of php's allocator. So the warm-up is a thousand calls (the
// literals, the first-call state and the pool at their working size) and the
// gate allows the peak a kilobyte, which is two orders of magnitude under one
// leaked string a call.
//
//     php -d extension=build/decimal.so soak.php 1000000
declare(strict_types=1);

if (!extension_loaded('decimal')) {
    require __DIR__ . '/decimal.php';
}
$n = (int) ($argv[1] ?? 1000000);
$acc = '0';
for ($i = 0; $i < 1000; $i++) {                // warm
    $acc = dec_add($acc, '12.5', 2);
}
$u0 = memory_get_usage();
$p0 = memory_get_peak_usage();
for ($i = 1000; $i < $n; $i++) {
    $acc = dec_add($acc, '12.5', 2);
}
$u1 = memory_get_usage();
$p1 = memory_get_peak_usage();
printf("calls %d  result %s  usage %d -> %d  peak %d -> %d\n", $n, $acc, $u0, $u1, $p0, $p1);

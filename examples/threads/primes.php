<?php
// examples/threads: the thread API (docs/threads.md § Step 3) on the program
// road. The primes below a limit are counted in T slices, one thread each,
// every thread running compiled code natively with its own arena; the joins
// add the counts. c/primes.c is the same program with pthreads (or Win32
// threads), for reference and for the bench row tests/examples.sh prints.
//
//     mc-php --exe primes.php -o primes && PRIMES_THREADS=4 ./primes
function count_primes(int $lo, int $hi): int {
    $n = 0;
    for ($i = $lo; $i < $hi; $i++) {
        if ($i < 2) continue;
        $p = 1;
        for ($d = 2; $d * $d <= $i; $d++) {
            if ($i % $d == 0) { $p = 0; break; }
        }
        $n += $p;
    }
    return $n;
}

$limit = 2000000;
$nt = (int) getenv("PRIMES_THREADS");
if ($nt == 0) $nt = mcphp_hardware_concurrency();
if ($nt < 1) $nt = 1;
$step = intdiv($limit + $nt - 1, $nt);
$hs = [];
for ($t = 0; $t < $nt; $t++) {
    $lo = $t * $step;
    $hi = min($limit, $lo + $step);
    $hs[] = mcphp_thread_start(fn(int $a, int $b): int => count_primes($a, $b), $lo, $hi);
}
$total = 0;
foreach ($hs as $h) $total += (int) mcphp_thread_join($h);
echo "primes below $limit: $total\n";

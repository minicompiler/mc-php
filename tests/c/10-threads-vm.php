<?php
// A thread's arena goes with the thread (lib/php_rt.mc § other threads):
// eight threads each calling the six builtins that write a thread's own
// state -- set_error_handler, restore_error_handler, set_exception_handler,
// restore_exception_handler, strtok, fopen -- in rounds, and the process's
// virtual size (committed bytes on Windows) measured before and after. A
// kept arena is 256 MiB (64 MiB on Windows) per thread per round, so a leak
// is gigabytes; the bound is 256 MiB. mcphp_vm() is the runtime's own test
// gate (docs/threads.md); graded by tests/fixtures.sh against
// 10-threads-vm.out -- php has no such function.
function six(int $x, int $id): int {
    $k = 0;
    set_error_handler(fn($no, $str) => true);
    restore_error_handler();
    set_exception_handler(fn($e) => null);
    restore_exception_handler();
    $t = strtok("ab cd", " ");
    $k += strlen($t);
    $f = fopen(__FILE__, "r");
    if ($f) { $k += 1; fclose($f); }
    return $k;
}

$n = 8;
$first = mcphp_threads('six', $n, 0);
$before = mcphp_vm();
$ok = 0;
for ($round = 0; $round < 4; $round++) $ok += mcphp_threads('six', $n, 0) === 3 * $n ? 1 : 0;
$after = mcphp_vm();
echo "six builtins on $n threads: ", $first === 3 * $n ? "each answered" : "MISMATCH $first", "\n";
echo "4 more rounds: $ok answered\n";
$grew = $after - $before;
echo "the process grew by under 256 MiB: ", $before > 0 && $grew < 268435456 ? "yes" : "no (" . intdiv($grew, 1048576) . " MiB)", "\n";

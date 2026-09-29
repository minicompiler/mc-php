<?php
// tests/ext.sh step 20 (threads.php says what): the module's threads against
// php calling the same function one at a time, in rounds.
$n = 8;
$iters = 300;
$want = 0;
for ($t = 0; $t < $n; $t++) $want += th\work($iters, $t);
for ($round = 0; $round < 5; $round++) {
    $got = th\run($n, $iters);
    echo "round $round: ", $got === $want ? "the $n threads agree" : "MISMATCH $got / $want", "\n";
}
function th_host(int $i): int { return 1000 + $i; }
echo "php's engine from this thread: ", th\probe(0, 2), ", from 4 others: ", th\guard(4), "\n";

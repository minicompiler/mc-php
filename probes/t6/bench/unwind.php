<?php
// The benchmark behind T6's unwinding decision (probes/t6/RESULTS.md section
// 4): a call-heavy loop, so the per-statement `if (php_thrown())` check is
// paid as often as a real program pays it. It throws nothing -- the question
// is what the CHECK costs when no exception is ever raised.
//
// Its test in both worlds is the byte-for-byte comparison bench.sh makes on
// every run: php and the mc-php binary must print the same line.
function step(int $a, int $b): int { return ($a * 31 + $b) & 0xffffff; }

function mix(int $n): int {
    $h = 1;
    $i = 0;
    while ($i < $n) {
        $h = step($h, $i);
        $h = step($h, $h >> 3);
        $i = $i + 1;
    }
    return $h;
}

$total = 0;
$r = 0;
while ($r < 20) {
    $total = ($total + mix(1000000)) & 0xffffff;
    $r = $r + 1;
}
echo $total, "\n";

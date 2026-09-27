<?php
// mc-php: semantics=c-debug
// ... and with the checks back: a hash's valid keys read, a key it does not
// have is the trap, as a key outside the packed array is.
function h(int $n, int $k): int {
    $a = array_fill(0, $n, 7);
    $a[$n + 2] = 9;
    return $a[0] + $a[$n + 2] + $a[$k];
}
echo h(2, 1), "\n";
echo h(2, 3), "\n";
echo "not reached\n";

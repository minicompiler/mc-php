<?php
// mc-php: semantics=c-debug
// ... and a packed array's element read by an int key outside the array
function last(int $n, int $k): int {
    $a = array_fill(0, $n, 7);
    $t = 0;
    for ($i = 0; $i <= $k; $i++) { $t = $t + $a[$i]; }
    return $t;
}
echo last(4, 3), "\n";
echo last(4, 4), "\n";
echo "not reached\n";

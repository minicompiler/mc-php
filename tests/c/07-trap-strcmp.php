<?php
// `[php] checked_reads = true` (07-trap-strcmp.toml): a string offset compared
// with a one-byte literal (`$s[$i] === 'c'`, which is lowered to the byte
// compared in place) is checked like any other read, and outside the string it
// stops the program and names the line instead of answering false.
function count_x(string $s, int $from, int $n): int {
    $c = 0;
    for ($k = 0; $k < $n; $k++) {
        if ($s[$from + $k] === 'x') { $c = $c + 1; }
    }
    return $c;
}
echo count_x("axbxc", 0, 5), "\n";
echo count_x("axbxc", 3, 3), "\n";
echo "not reached\n";

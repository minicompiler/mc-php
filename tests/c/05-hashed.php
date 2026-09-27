<?php
// C semantics, the default: a store outside a packed array makes it php's
// hash under the same handle, and a read after that is the hash's -- a valid
// key answers its value, not the stale dense buffer's. (docs/semantics.md § 3)
function h(int $n): string {
    $a = array_fill(0, $n, 7);
    $a[$n + 2] = 9;              // outside: the array is a hash from here on
    $a[-1] = 5;
    $t = 0;
    for ($i = 0; $i < $n; $i++) { $t = $t + $a[$i]; }
    return $t . " " . $a[$n + 2] . " " . $a[-1] . " " . count($a);
}
echo h(1), "\n";
echo h(4), "\n";

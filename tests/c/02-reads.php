<?php
// C semantics, the default: a string offset and a packed element read in
// range answer exactly what php answers -- only a read OUTSIDE the range
// differs (undefined behaviour, docs/semantics.md). A negative offset the
// source spells as a literal is php's count-from-the-end, kept.
function bytes(string $s): int {
    $t = 0;
    for ($i = 0; $i < strlen($s); $i++) { $t = $t * 3 + ord($s[$i]) - 48; }
    return $t + ord($s[-1]);
}
function zeros(string $s): int {
    $n = 0;
    for ($i = 0; $i < strlen($s); $i++) { if ($s[$i] === '0') $n++; }
    return $n;
}
function sum(int $n): int {
    $a = array_fill(0, $n, 0);
    for ($i = 0; $i < $n; $i++) $a[$i] = $i * $i;
    $t = 0;
    for ($i = 0; $i < $n; $i++) $t = $t + $a[$i];
    return $t;
}
echo bytes("31415"), " ", zeros("1002003000"), " ", sum(10), " ", "abc"[1], "\n";

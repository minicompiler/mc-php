<?php
// str_pad of an int's digits is fused (php_str_pad_i), and === between two
// strings asks only whether the bytes are the same (php_str_eq): both must
// answer as php does at every edge -- a negative int, PHP_INT_MIN, a width
// the digits already exceed, every pad type, a pad longer than one byte, and
// strings that differ only in length or only in their last byte.
foreach ([0, 7, -7, 123456789, -123456789, PHP_INT_MAX, PHP_INT_MIN] as $v) {
    echo str_pad((string) $v, 9, '0', STR_PAD_LEFT), "|", str_pad((string) $v, 12, "ab", STR_PAD_BOTH), "|",
         str_pad((string) $v, 3, "*"), "|", str_pad((string) $v, 14, "-=", STR_PAD_RIGHT), "\n";
}
function limb(int $d): string { return str_pad((string) $d, 9, '0', STR_PAD_LEFT); }
echo limb(42), " ", limb(999999999), " ", limb(1000000000), "\n";
$pairs = [["", ""], ["", "a"], ["abc", "abc"], ["abc", "abd"], ["abcdefgh", "abcdefgh"],
          ["abcdefghi", "abcdefghj"], ["abcdefgh", "abcdefg"], ["0", "0"], ["0", "00"]];
foreach ($pairs as $p) {
    $a = $p[0]; $b = $p[1];
    var_dump($a === $b, $a !== $b);
}
function same(string $a, string $b): bool { return $a === $b; }
var_dump(same("x", "x"), same("x", "xy"), same("12345678", "12345679"));

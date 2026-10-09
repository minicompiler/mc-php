<?php
// `$a[$i] === $b[$j]` (and !==) compares the two bytes (src/expr.mc): each
// read is exactly one byte, so no one-byte strings are made to be compared.
// NUL, high bytes and the same string on both sides, byte for byte php's.
function cmp2(string $a, string $b): string {
    $o = '';
    for ($i = 0; $i < strlen($a); $i++) {
        $o .= $a[$i] === $b[$i] ? '=' : '.';
        $o .= $a[$i] !== $b[strlen($b) - 1 - $i] ? '!' : '~';
    }
    return $o;
}
echo cmp2("ab\0\xff9", "ab\0\xfe9"), ' ', cmp2("abba", "abba"), ' ', cmp2("x", "y"), "\n";
function lead(string $r): int { $z = 0; while ($z < strlen($r) - 1 && $r[$z] === $r[$z + 1]) { $z++; } return $z; }
echo lead('0001'), lead('1'), lead('aaaa'), "\n";

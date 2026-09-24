<?php
// The runtime's byte loops, at every length that crosses a word: a copy of
// 0..20 bytes (substr, concat), and str_replace of one byte -- found at the
// start, the end, adjacent, never, and inside an eight-byte word -- with an
// empty, a one-byte and a longer replacement.
$s = "0123456789abcdefghijklmnop";
for ($n = 0; $n <= 20; $n++) {
    $a = substr($s, 3, $n);
    echo $n, ":", $a, "|", $a . substr($s, 0, $n), "\n";
}
$subjects = ["", "-", "--", "a-b", "-ab-", "abcdefgh-", "-abcdefgh", "abcdefg-h",
             "12345678.12345678", "........", "no occurrence at all, but long", "-.-.-.-."];
foreach ($subjects as $x) {
    echo "[", str_replace("-", "", $x), "] [", str_replace(".", "", str_replace("-", "", $x)), "] [",
         str_replace("-", "+", $x), "] [", str_replace("-", "<->", $x), "]\n";
}
// the same over NATIVE strings, where two one-byte deletions nested are ONE
// pass (php_str_del2) -- and the shapes that are not that stay two calls
function del2(string $s): string { return str_replace(".", "", str_replace("-", "", $s)); }
function not2(string $s): string {
    return str_replace(".", "x", str_replace("-", "", $s)) . "|" . str_replace("..", "", str_replace("-", "", $s))
         . "|" . str_replace(".", "", str_replace("-", "+", $s));
}
foreach ($subjects as $x) {
    $ns = (string) $x;
    echo "[", del2($ns), "] [", not2($ns), "]\n";
}
// strpos of a one-byte literal from the start is a scan alone (php_strpos1),
// and $s[$i] === 'c' reads the byte in place when the name and index are
// plain -- the call only outside the string, where php warns
function find_dot(string $s): string {
    $p = strpos($s, '.');
    if ($p === false) { return "none"; }
    return (string) $p;
}
function at(string $s, int $i): string {
    return var_export($s[$i] === '.', true) . var_export($s[0] !== '-', true);
}
foreach (["", ".", "a.", "abcdefgh.", "abcdefghijklmnopq.", "no dot here at all"] as $t) {
    echo find_dot($t), " ";
}
echo "\n", at("1.5", 1), at("-1.5", 2), at("x", -1), at(".", 3), at("x", PHP_INT_MAX), "\n";

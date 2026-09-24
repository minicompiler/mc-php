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

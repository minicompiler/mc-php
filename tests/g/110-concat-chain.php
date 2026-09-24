<?php
// `a . b . c` is built as ONE string (php_str_cat3/cat4, then chained): the
// bytes, the conversions of every part and their warnings in php's order.
$a = "x"; $b = 5; $c = [1];
echo $a . "-" . $b . "|" . 1.5 . "#" . true . "" . null, "\n";
echo "v=$a" . "!" . "?", "\n";
$s = "p" . "q" . "r" . "s" . "t" . "u" . "v" . "w" . "x";
echo $s, strlen($s), "\n";
echo "k" . $c . "m" . $c, "\n";
function fmt(string $coef, int $to): string {
    $len = strlen($coef);
    return substr($coef, 0, $len - $to) . '.' . substr($coef, $len - $to);
}
echo fmt("12345", 2), " ", fmt("7", 0), " ", fmt("", 0), "\n";

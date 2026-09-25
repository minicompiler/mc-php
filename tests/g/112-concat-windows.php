<?php
// A concatenation with substr() pieces is ONE string built from windows of
// its operands (src/opt.mc): php's own substr bounds for every piece --
// negative starts and lengths, a start past the end, no length, a length of
// PHP_INT_MAX -- and plain pieces beside them, in two, three and four parts.
function w2(string $s, int $a, int $b): string { return substr($s, $a, $b) . "|"; }
function w2n(string $s, int $a): string { return "<" . substr($s, $a); }
function w3(string $s, int $k): string { return substr($s, 0, $k) . '.' . substr($s, $k); }
function w4(string $s, int $a, int $b): string { return substr($s, $a) . "[" . substr($s, 0, $b) . "]"; }
$s = "0123456789";
$as = [0, 2, -4, -20, 8, 11, 10, 3, 0, -1, 5];
$bs = [3, -2, 2, 5, 10, 1, 0, -20, PHP_INT_MAX, PHP_INT_MAX, PHP_INT_MIN];
for ($i = 0; $i < count($as); $i++) {
    $a = $as[$i];
    $b = $bs[$i];
    echo w2($s, $a, $b), w2n($s, $a), " ", w4($s, $a, $b), "\n";
}
foreach ([0, 1, 5, 10, 12, -3] as $k) { echo w3($s, $k), " ", w3("", $k), "\n"; }
$e = "";
echo substr($e, 0, 1) . substr($e, 1), "|", strlen(substr($s, 9) . substr($s, 10)), "\n";
// a piece that is a whole string, and one that is a call's answer
function up(string $x): string { return strtoupper($x); }
echo substr(up("abcdef"), 1, 3) . up("x") . substr($s, -2), "\n";

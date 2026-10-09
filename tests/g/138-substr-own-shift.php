<?php
// `$x = substr($x, ...)` on a string slot of a function that loops is
// shortened where it lies when nobody else holds the string (src/rc.mc,
// php_substr_own) and copied when someone does -- another variable, an
// array, the caller's argument. And a shift by a literal count is mc's own
// shift (src/expr.mc). Every answer byte for byte php's.

function trim0(string $d): string {
    $log = [];
    $keep = $d;                         // the caller's string, and a copy of it
    $r = '';
    for ($i = 0; $i < 3; $i++) {
        $r = str_repeat('0', $i) . $d . $i;
        $alias = $r;                    // held twice: copied, not shortened
        $r = substr($r, strspn($r, '0'));
        $log[] = $alias;
        $r = substr($r, 0, -1);         // unique now: in place
        $r = substr($r, -2);            // a negative start
        $r = substr($r, 5);             // past the end: ""
    }
    $d = substr($d, 1);                 // the parameter, assigned: the caller's own is untouched
    return "$keep|$d|$r|" . strlen($r) . ' ' . implode(',', $log);
}
$arg = '00123';
echo trim0($arg), " ", $arg, "\n";

function windows(string $s): string {
    $out = '';
    for ($k = 0; $k < 4; $k++) {
        $t = $s . $k;
        $t = substr($t, $k, 3);         // in place, a window inside
        $t = substr($t, 1, 100);        // a length past the end
        $out .= "[$t]";
    }
    return $out;
}
echo windows('abcdef'), "\n";

function shifts(int $x): string {
    $y = $x; $y >>= 1;
    $z = $x; $z <<= 3;
    $e = $x; $n = 0;
    while ($e > 0) { $e >>= 1; $n++; }
    return ($x >> 1) . ' ' . ($x << 63) . ' ' . ($x >> 63) . ' ' . ($x << 0) . " $y $z $n";
}
foreach ([-8, -1, 0, 7, PHP_INT_MAX, PHP_INT_MIN] as $v) { echo shifts($v), "\n"; }

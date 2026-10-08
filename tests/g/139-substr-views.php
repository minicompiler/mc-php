<?php
// A string local of a function with no loop, assigned by substr(), is kept as
// a window of the string it was cut from (src/opt.mc, ph_view_fn) and built
// only where a read needs a string of its own. Every shape a window serves --
// strlen, strspn from an offset (inside and outside the window), a byte, a
// substr() of it, a piece of a concatenation and of an appended answer -- and
// every substr() bound, byte for byte php's.

function trimz(string $x, int $n): string {
    $ip = substr($x, 0, $n);
    $z = strspn($ip, '0');
    if ($z === strlen($ip)) { $z = strlen($ip) - 1; }
    $ip = substr($ip, $z);
    return $ip . '|' . substr($x, $n) . '|' . strlen($ip) . $ip[0];
}
echo trimz('000123450', 6), ' ', trimz('0000', 4), ' ', trimz('7', 1), "\n";

function bounds(string $s): string {
    $a = substr($s, -3);            // from the end
    $b = substr($s, 2, -2);         // a negative length
    $c = substr($s, 50);            // past the end: ""
    $d = substr($s, -50, 3);        // a start before the beginning
    $e = substr($s, 3, 0);          // empty
    $f = substr($a, 1, 100);        // a window of a window, length past its end
    $g = substr($b, -2, 1);
    return "[$a][$b][$c][$d][$e][$f][$g]" . strlen($c) . strlen($e) . strlen($f);
}
echo bounds('abcdefgh'), ' ', bounds('xy'), ' ', bounds(''), "\n";

function scans(string $s): string {
    $w = substr($s, 2, 6);
    $n1 = strspn($w, '0123456789');
    $n2 = strspn($w, '0123456789', 3);
    $n3 = strspn($w, 'abc', 9);       // an offset outside the window
    $n4 = strspn($w, 'xyz', -2);      // a negative offset
    return "$n1 $n2 $n3 $n4 " . ord($w[1]) . ' ' . $w[2];
}
echo scans('zz1234a6789'), ' ', scans('..xyz'), "\n";

// the answer appended a piece at a time, each a substr() of a window
function fmt(string $c, int $k, bool $neg): string {
    $w = substr($c, 1, strlen($c) - 1);
    $o = $neg ? '-' : '';
    if (strlen($w) > $k) { $o .= substr($w, 0, strlen($w) - $k); } else { $o .= '0'; }
    $o .= '.';
    $o .= substr($w, -$k);
    return $o;
}
echo fmt('912345', 2, true), ' ', fmt('91', 3, false), "\n";

// reads that need a string of their own: compared, passed on, returned
function needs(string $s): string {
    $w = substr($s, 1, 3);
    $v = substr($s, 2);
    $eq = $w === 'bcd' ? 'Y' : 'N';
    return $eq . strtoupper($w) . str_pad($v, 6, '*') . $w;
}
echo needs('abcdef'), ' ', needs('a'), "\n";

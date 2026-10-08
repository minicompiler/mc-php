<?php
// The window count along every path (src/opt.mc, vw_flow): a substr() local
// cut in one branch of a conditional and made a string only on another road,
// pieces of an appended answer cut from it (the rope's php_rope_v), an early
// return; and a fresh buffer of a function that does not loop (src/rc.mc,
// ph_rc_fb_scan_nc), written in place before it is handed on and copied when
// a write comes after. Every answer byte for byte php's.

function fmt(string $c, int $kn, bool $up): string {
    $w = $kn === 0 ? '0' : substr($c, 1, $kn);
    $w0 = 0;
    if ($up) { $w = strrev($w) . '1'; $w0 = 1; }
    $o = $up ? '-' : '';
    $o .= substr($w, $w0, 2);
    $o .= '.';
    $o .= substr($w, -2);
    $o .= substr($w, 1, -1);
    $o .= substr($w, 9);
    return $o . '|' . strlen($w) . substr($w, 0, 1);
}
foreach ([['912345', 0], ['912345', 3], ['912345', 40], ['9', 2], ['', 1]] as $p) {
    echo fmt($p[0], $p[1], false), ' ', fmt($p[0], $p[1], true), "\n";
}

// the saving only on an early return: the local stays a string
function early(string $s, int $n, bool $quit): string {
    $t = $s;
    if ($n > 0) { $t = substr($s, $n); }
    if ($quit) { return 'q' . strlen($t); }
    return strtoupper($t) . $t;
}
echo early('abcdef', 2, false), ' ', early('abcdef', 2, true), ' ', early('ab', 0, false), "\n";

// written in place, then handed on: the copies keep what it was then
function one(int $w, int $k): string {
    $one = str_repeat('0', $w);
    $one[$k] = '1';
    $one[-1] = 'z';
    $one[$w + 2] = '7';                 // past the end: php pads with spaces
    $keep = $one;
    $copy = strrev($one);
    return "[$keep][$copy]" . strlen($one);
}
echo one(5, 0), ' ', one(5, 4), ' ', one(1, 0), "\n";

// a write after the buffer was handed on: the other name keeps the old bytes
function late(int $w): string {
    $b = str_repeat('x', $w);
    $c = $b;
    $b[0] = 'y';
    $lit = 'abc';
    $lit[1] = 'Q';                      // a literal is never written in place
    return $c . '|' . $b . '|' . $lit . '|' . 'abc';
}
echo late(3), ' ', late(1), "\n";

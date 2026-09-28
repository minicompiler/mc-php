<?php
// The lowerings of decimal-2x, each against php: a string built by appends
// under branches (src/opt.mc's rope), a buffer made by str_repeat and written
// byte by byte (src/rc.mc's fresh buffer), a packed array whose stores are to
// the keys their right-hand sides read (src/packed.mc's fixed array), a pad
// (`. str_repeat`), and the short circuits folded back into && and ||.

function fmt(bool $neg, string $w, int $il, int $to): string {
    $o = $neg ? '-' : '';
    if (strlen($w) > $to) { $o .= substr($w, 0, $il); } else { $o .= '0'; }
    if ($to > 0) {
        $o .= '.';
        if (strlen($w) < $to) { $o .= str_repeat('0', $to - strlen($w)); }
        if (strlen($w) > $to) { $o .= substr($w, $il, $to); } else { $o .= $w; }
    }
    return $o;
}

function windows(string $s): string {
    $o = '[';
    $o .= substr($s, -3);
    $o .= substr($s, 1, -1);
    $o .= substr($s, 10);
    $o .= substr($s, -20, 2);
    if ($s === '') { return $o . 'empty'; }
    $o .= ']';
    return $o;
}

function early(int $n): string {
    $o = 'x';
    if ($n > 0) { $o .= 'pos'; return $o; }
    $o .= 'neg';
    return $o;
}

function fresh(int $n): string {
    $out = str_repeat('0', $n);
    for ($k = 0; $k < $n; $k++) { $out[$n - 1 - $k] = chr(48 + ($k * 7) % 10); }
    return $out;
}

function past_end(): string {
    $s = str_repeat('a', 3);
    for ($k = 0; $k < 2; $k++) { $s[5 + $k] = 'x'; }
    return $s;
}

function one(): string {
    $s = str_repeat('q', 1);
    for ($k = 0; $k < 1; $k++) { $s[0] = 'z'; }
    return $s . '|' . str_repeat('q', 1);
}

function acc(int $n): string {
    $a = array_fill(0, $n, 0);
    for ($i = 0; $i < $n; $i++) {
        for ($j = 0; $j + $i < $n; $j++) { $a[$i + $j] = $a[$i + $j] + $i * $j + 1; }
    }
    $t = '';
    for ($k = 0; $k < $n; $k++) { $t .= $a[$k] . ','; }
    return $t;
}

function pad(string $s, int $n): string { return $s . str_repeat('0', $n); }

function sign(string $s): int {
    $p = 0;
    if (strlen($s) > 0 && ($s[0] === '-' || $s[0] === '+')) { $p = 1; }
    if ($p > 0 && $s[0] === '-' || strlen($s) > 3) { $p = $p + 10; }
    return $p;
}

function said(string $w, int $v): bool { echo "[$w]"; return $v > 1; }

function sc(int $a, int $b): string {
    $r = '';
    if ($a > 0 && said('b', $b)) { $r .= 'and '; }
    if ($a > 0 || said('c', $b)) { $r .= 'or '; }
    if ($a > 0 && ($b > 1 || said('d', $a))) { $r .= 'nested'; }
    return $r;
}

echo fmt(false, '250906', 4, 2), ' ', fmt(true, '5', 1, 2), ' ', fmt(false, '12', 1, 0), "\n";
echo windows('abcdef'), ' ', windows(''), ' ', windows('xy'), "\n";
echo early(1), ' ', early(-1), "\n";
echo fresh(12), ' ', fresh(1), ' ', fresh(0), "|\n";
echo past_end(), ' ', one(), "\n";
echo acc(6), "\n";
echo pad('7', 3), ' ', pad('', 0), ' ', pad('ab', 1), "\n";
try { echo pad('x', -1), "\n"; } catch (ValueError $e) { echo get_class($e), ': ', $e->getMessage(), "\n"; }
echo sc(1, 2), '|', sc(0, 1), '|', sc(1, 1), "\n";
echo sign('-5'), ' ', sign('+5'), ' ', sign('5'), ' ', sign(''), ' ', sign('-123'), ' ', sign('1234'), "\n";

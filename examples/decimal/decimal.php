<?php
// decimal -- fixed-point DECIMAL arithmetic, written in PHP and compiled by
// mc-php into a native PHP extension.
//
// A number is a STRING, `[+-]?[0-9]+(\.[0-9]+)?`, and every result is a
// string with exactly $scale digits after the point -- bcmath's shape. The
// arithmetic is exact: a number is its DIGITS and a scale, and no float
// appears anywhere in the path.
//
// ROUNDING: half-even (banker's), in EVERY function and not only dec_div.
// When the exact result has more digits than $scale it is rounded to the
// nearest representable value, and an exact tie goes to the even last digit:
// dec_round("0.125", 2) is "0.12", dec_round("0.135", 2) is "0.14", and
// dec_round("-2.5", 0) is "-2". bcmath TRUNCATES instead; README.md says how
// the gate compares the two anyway.
//
// THE ALGORITHM IS c/decimal.c's, function by function: the C twin is the
// specification, and this file says in PHP what that one says in C, so that
// the three columns of the bench (php interpreting this, the module compiled
// from it, the twin) measure one algorithm three ways. Each operand is parsed
// ONCE into its digits; the arithmetic is base 10, one digit at a time --
// schoolbook multiplication, long division by repeated subtraction -- and a
// result digit is written into a string of the right length, as the twin
// writes into its buffer. Where C moves a pointer past leading zeros (skip0),
// PHP carries the index it would have moved to.
//
// It is ordinary PHP and nothing else: `require` it and the functions are
// php's own; `mc-php build` beside mcphp.toml turns the same file into
// decimal.so. The API is the six dec_* functions at the bottom. The _dec_*
// helpers above them are module-private: a leading underscore is not
// published (docs/php-extension.md § What is published), so php sees the six
// and nothing else.

// ---- a number: sign, all its digits, how many of them follow the point ------
// C's `dnum` is three locals of the caller here -- the sign, the digits
// (integer part then fraction, no point) and the scale -- because a PHP
// function returns one value: _dec_parse answers the scale, _dec_digits the
// digits and _dec_neg the sign.

// dparse + dvalid: [+-]?[0-9]+(\.[0-9]+)?, and its scale; anything else is a
// ValueError naming the argument
function _dec_parse(string $s, string $fn, int $argno, string $name): int {
    $n = strlen($s);
    $p = 0;
    if ($n > 0 && ($s[0] === '-' || $s[0] === '+')) { $p = 1; }
    $id = strspn($s, '0123456789', $p);
    $p += $id;
    $sc = 0;
    $ok = $id > 0;
    if ($ok && $p < $n) {
        $ok = false;
        if ($s[$p] === '.') {
            $sc = strspn($s, '0123456789', $p + 1);
            $ok = $sc > 0 && $p + 1 + $sc === $n;
        }
    }
    if (!$ok) {
        throw new ValueError("$fn(): Argument #$argno (\$$name) is not a decimal number");
    }
    return $sc;
}

// the digits of a valid number at scale $sc: its sign and its point left out
function _dec_digits(string $s, int $sc): string {
    $i = 0;
    if ($s[0] === '-' || $s[0] === '+') { $i = 1; }
    if ($sc === 0) { return substr($s, $i); }
    $p = strlen($s) - $sc - 1;
    return substr($s, $i, $p - $i) . substr($s, $p + 1);
}

// negative, and not zero
function _dec_neg(string $s, string $d): bool {
    return $s[0] === '-' && strspn($d, '0') < strlen($d);
}

function _dec_scale(int $scale, string $fn, int $argno): void {
    if ($scale < 0) {
        throw new ValueError("$fn(): Argument #$argno (\$scale) must be greater than or equal to 0");
    }
}

// ---- magnitudes: digit strings, most significant first -----------------------
// skip0: how many leading zeros to step over, keeping at least one digit
function _dec_skip0(string $d): int {
    $k = strspn($d, '0');
    if ($k === strlen($d)) { $k--; }
    return $k;
}

function _dec_ucmp(string $a, string $b): int {
    $ka = _dec_skip0($a);
    $kb = _dec_skip0($b);
    $na = strlen($a) - $ka;
    $nb = strlen($b) - $kb;
    if ($na !== $nb) { return $na < $nb ? -1 : 1; }
    $c = strcmp(substr($a, $ka), substr($b, $kb));
    if ($c < 0) { return -1; }
    return $c > 0 ? 1 : 0;
}

// max(na, nb) + 1 digits
function _dec_uadd(string $a, string $b): string {
    $na = strlen($a);
    $nb = strlen($b);
    $n = ($na > $nb ? $na : $nb) + 1;
    $out = str_repeat('0', $n);
    $carry = 0;
    for ($k = 0; $k < $n; $k++) {
        $d = $carry;
        if ($k < $na) { $d += ord($a[$na - 1 - $k]) - 48; }
        if ($k < $nb) { $d += ord($b[$nb - 1 - $k]) - 48; }
        $carry = $d >= 10 ? 1 : 0;
        $out[$n - 1 - $k] = chr(48 + $d % 10);
    }
    return $out;
}

// a >= b; na digits
function _dec_usub(string $a, string $b): string {
    $na = strlen($a);
    $nb = strlen($b);
    $out = str_repeat('0', $na);
    $borrow = 0;
    for ($k = 0; $k < $na; $k++) {
        $d = ord($a[$na - 1 - $k]) - 48 - $borrow;
        if ($k < $nb) { $d -= ord($b[$nb - 1 - $k]) - 48; }
        $borrow = $d < 0 ? 1 : 0;
        $out[$na - 1 - $k] = chr(48 + ($d + 10) % 10);
    }
    return $out;
}

// na + nb digits
function _dec_umul(string $a, string $b): string {
    $na = strlen($a);
    $nb = strlen($b);
    $n = $na + $nb;
    $acc = array_fill(0, $n, 0);
    for ($i = 0; $i < $na; $i++) {
        $x = ord($a[$na - 1 - $i]) - 48;
        if ($x === 0) { continue; }
        for ($j = 0; $j < $nb; $j++) {
            $acc[$i + $j] = $acc[$i + $j] + $x * (ord($b[$nb - 1 - $j]) - 48);
        }
    }
    $out = str_repeat('0', $n);
    $carry = 0;
    for ($k = 0; $k < $n; $k++) {
        $t = $acc[$k] + $carry;
        $out[$n - 1 - $k] = chr(48 + $t % 10);
        $carry = intdiv($t, 10);
    }
    return $out;
}

// long division, b not zero: the quotient (na digits) and then the remainder,
// in one string -- the caller knows where the quotient ends. The remainder is
// the twin's: one buffer of nb + 2 digits, its first $rn in use, compared and
// subtracted where it lies.
function _dec_udivmod(string $a, string $b): string {
    $b = substr($b, _dec_skip0($b));
    $nb = strlen($b);
    $na = strlen($a);
    $q = str_repeat('0', $na);
    $r = str_repeat('0', $nb + 2);
    $rn = 0;
    for ($i = 0; $i < $na; $i++) {
        if ($rn === 1 && $r[0] === '0') { $rn = 0; }
        $r[$rn] = $a[$i];
        $rn++;
        $k = 0;
        while (true) {
            // skip0, in place: the leading zeros go, one digit stays
            $z = 0;
            while ($z < $rn - 1 && $r[$z] === '0') { $z++; }
            if ($z > 0) {
                for ($m = 0; $m < $rn - $z; $m++) { $r[$m] = $r[$m + $z]; }
                $rn -= $z;
            }
            // ucmp(r, b) < 0 ends the step
            if ($rn < $nb) { break; }
            if ($rn === $nb) {
                $m = 0;
                while ($m < $nb && $r[$m] === $b[$m]) { $m++; }
                if ($m < $nb && ord($r[$m]) < ord($b[$m])) { break; }
            }
            // usub(r, b) into r
            $borrow = 0;
            for ($m = 0; $m < $rn; $m++) {
                $d = ord($r[$rn - 1 - $m]) - 48 - $borrow;
                if ($m < $nb) { $d -= ord($b[$nb - 1 - $m]) - 48; }
                $borrow = $d < 0 ? 1 : 0;
                $r[$rn - 1 - $m] = chr(48 + ($d + 10) % 10);
            }
            $k++;
        }
        $q[$i] = chr(48 + $k);
    }
    if ($rn === 0) { return $q . '0'; }
    return $q . substr($r, 0, $rn);
}

// ---- the ONE place a result is rounded and written: half-even ----------------
// $c: a magnitude at scale $from; the answer has exactly $to digits after the
// point, and a zero is never negative
function _dec_fmt(bool $neg, string $c, int $from, int $to): string {
    // skip0 is the index of the first digit kept: the twin moves its pointer
    // there, and $w0 below is where $w's digits begin
    $c0 = _dec_skip0($c);
    $n = strlen($c) - $c0;
    if ($from > $to) {
        $k = $from - $to;
        // the digits kept are the first n - k, each a zero where n <= k
        $kn = $n > $k ? $n - $k : 0;
        $first = $n >= $k ? ord($c[$c0 + $n - $k]) : 48;
        $up = false;
        if ($first > 53) {
            $up = true;
        } elseif ($first === 53) {
            $up = strspn($c, '0', $c0 + $n - $k + 1) < $k - 1;
            if (!$up) { $up = $kn > 0 && (ord($c[$c0 + $kn - 1]) - 48) % 2 === 1; }
        }
        $w = $kn === 0 ? '0' : substr($c, $c0, $kn);
        $w0 = 0;
        if ($up) {
            $w = _dec_uadd($w, '1');
            $w0 = _dec_skip0($w);
        }
    } elseif ($to > $from && ($n !== 1 || $c[$c0] !== '0')) {
        $w = substr($c, $c0) . str_repeat('0', $to - $from);
        $w0 = 0;
    } else {
        $w = $c;
        $w0 = $c0;
    }
    $wn = strlen($w) - $w0;
    if (strspn($w, '0', $w0) === $wn) { $neg = false; }
    $il = $wn > $to ? $wn - $to : 1;          // digits before the point
    $o = $neg ? '-' : '';
    if ($wn > $to) { $o .= substr($w, $w0, $il); } else { $o .= '0'; }
    if ($to > 0) {
        $o .= '.';
        if ($wn < $to) { $o .= str_repeat('0', $to - $wn); }
        if ($wn > $to) { $o .= substr($w, $w0 + $il, $to); } else { $o .= substr($w, $w0); }
    }
    return $o;
}

// a number's digits at scale $s (>= its own): the digits padded with zeros
function _dec_at(string $d, int $sc, int $s): string {
    if ($s === $sc) { return $d; }
    return $d . str_repeat('0', $s - $sc);
}

function _dec_addsub(string $fn, string $a, string $b, int $scale, bool $minus): string {
    _dec_scale($scale, $fn, 3);
    $xs = _dec_parse($a, $fn, 1, 'a');
    $ys = _dec_parse($b, $fn, 2, 'b');
    $xd = _dec_digits($a, $xs);
    $yd = _dec_digits($b, $ys);
    $xn = _dec_neg($a, $xd);
    $yn = _dec_neg($b, $yd);
    if ($minus) { $yn = !$yn && _dec_ucmp($yd, '0') !== 0; }
    $s = $xs > $ys ? $xs : $ys;
    $cx = _dec_at($xd, $xs, $s);
    $cy = _dec_at($yd, $ys, $s);
    if ($xn === $yn) {
        $r = _dec_uadd($cx, $cy);
        $neg = $xn;
    } elseif (_dec_ucmp($cx, $cy) >= 0) {
        $r = _dec_usub($cx, $cy);
        $neg = $xn;
    } else {
        $r = _dec_usub($cy, $cx);
        $neg = $yn;
    }
    return _dec_fmt($neg, $r, $s, $scale);
}

// ---- the API ---------------------------------------------------------------
function dec_add(string $a, string $b, int $scale): string {
    return _dec_addsub('dec_add', $a, $b, $scale, false);
}

function dec_sub(string $a, string $b, int $scale): string {
    return _dec_addsub('dec_sub', $a, $b, $scale, true);
}

function dec_mul(string $a, string $b, int $scale): string {
    _dec_scale($scale, 'dec_mul', 3);
    $xs = _dec_parse($a, 'dec_mul', 1, 'a');
    $ys = _dec_parse($b, 'dec_mul', 2, 'b');
    $xd = _dec_digits($a, $xs);
    $yd = _dec_digits($b, $ys);
    $r = _dec_umul($xd, $yd);
    return _dec_fmt(_dec_neg($a, $xd) !== _dec_neg($b, $yd), $r, $xs + $ys, $scale);
}

// a / b = (ca * 10^sb) / (cb * 10^sa), scaled by 10^scale: one integer
// division, and 2r against the divisor decides the rounding
function dec_div(string $a, string $b, int $scale): string {
    _dec_scale($scale, 'dec_div', 3);
    $xs = _dec_parse($a, 'dec_div', 1, 'a');
    $ys = _dec_parse($b, 'dec_div', 2, 'b');
    $xd = _dec_digits($a, $xs);
    $yd = _dec_digits($b, $ys);
    if (_dec_ucmp($yd, '0') === 0) {
        throw new DivisionByZeroError("Division by zero");
    }
    $nn = strlen($xd) + $ys + $scale;
    $num = $xd . str_repeat('0', $ys + $scale);
    $den = $yd . str_repeat('0', $xs);
    $qr = _dec_udivmod($num, $den);
    $q = substr($qr, 0, $nn);
    $r = substr($qr, $nn);
    $c = _dec_ucmp(_dec_uadd($r, $r), $den);
    if ($c > 0 || ($c === 0 && (ord($q[$nn - 1]) - 48) % 2 === 1)) {
        $q = _dec_uadd($q, '1');
    }
    return _dec_fmt(_dec_neg($a, $xd) !== _dec_neg($b, $yd), $q, $scale, $scale);
}

function dec_cmp(string $a, string $b): int {
    $xs = _dec_parse($a, 'dec_cmp', 1, 'a');
    $ys = _dec_parse($b, 'dec_cmp', 2, 'b');
    $xd = _dec_digits($a, $xs);
    $yd = _dec_digits($b, $ys);
    $xn = _dec_neg($a, $xd);
    if ($xn !== _dec_neg($b, $yd)) {
        return $xn ? -1 : 1;
    }
    $s = $xs > $ys ? $xs : $ys;
    $r = _dec_ucmp(_dec_at($xd, $xs, $s), _dec_at($yd, $ys, $s));
    return $xn ? -$r : $r;
}

function dec_round(string $a, int $scale): string {
    _dec_scale($scale, 'dec_round', 2);
    $xs = _dec_parse($a, 'dec_round', 1, 'a');
    $xd = _dec_digits($a, $xs);
    return _dec_fmt(_dec_neg($a, $xd), $xd, $xs, $scale);
}

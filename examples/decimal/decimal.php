<?php
// decimal -- fixed-point DECIMAL arithmetic, written in PHP and compiled by
// mc-php into a native PHP extension.
//
// A number is a STRING, `[+-]?[0-9]+(\.[0-9]+)?`, and every result is a
// string with exactly $scale digits after the point -- bcmath's shape. The
// arithmetic is exact: a number is an integer COEFFICIENT (a string of
// digits) and a scale, and no float appears anywhere in the path.
//
// ROUNDING: half-even (banker's), in EVERY function and not only dec_div.
// When the exact result has more digits than $scale it is rounded to the
// nearest representable value, and an exact tie goes to the even last digit:
// dec_round("0.125", 2) is "0.12", dec_round("0.135", 2) is "0.14", and
// dec_round("-2.5", 0) is "-2". bcmath TRUNCATES instead; README.md says how
// the gate compares the two anyway.
//
// It is ordinary PHP and nothing else: `require` it and the functions are
// php's own; `mc-php build` beside mcphp.toml turns the same file into
// decimal.so. The API is the six dec_* functions at the bottom. The _dec_*
// helpers above them are published too, because every top-level function of
// an extension source is (README.md: "What it cannot do yet"), and each takes
// only scalars for the same reason.

// ---- a number: validated once, then read in three ways -----------------------
// The canonical form is the input without a leading '+'. strspn and not a
// loop over $s[$i]: every string an extension builds lives in D7's arena
// until the process ends (README.md), so the fewer strings, the more calls.
function _dec_valid(string $s, string $fn, int $argno, string $name): string {
    $n = strlen($s);
    $i = 0;
    if ($n > 0 && ($s[0] === '-' || $s[0] === '+')) { $i = 1; }
    $d = strspn($s, '0123456789', $i);
    $ok = $d > 0;
    $i += $d;
    if ($ok && $i < $n) {
        $ok = false;
        if ($s[$i] === '.') {
            $f = strspn($s, '0123456789', $i + 1);
            $ok = $f > 0 && $i + 1 + $f === $n;
        }
    }
    if (!$ok) {
        throw new ValueError("$fn(): Argument #$argno (\$$name) is not a decimal number");
    }
    if ($s[0] === '+') { return substr($s, 1); }
    return $s;
}

// the digits after the point
function _dec_sc(string $v): int {
    $p = strpos($v, '.');
    if ($p === false) { return 0; }
    return strlen($v) - $p - 1;
}

// the coefficient: "-012.30" is "1230". Zero is "0".
function _dec_coef(string $v): string {
    // two calls, not str_replace(['-', '.'], ...): both forms compile, and
    // three strings lower to a native call where an array goes through zvals
    $c = ltrim(str_replace('.', '', str_replace('-', '', $v)), '0');
    if ($c === '') { return '0'; }
    return $c;
}

// negative, and zero never is
function _dec_neg(string $v): bool {
    return $v[0] === '-' && strspn($v, '-0.') < strlen($v);
}

function _dec_scale(int $scale, string $fn, int $argno): void {
    if ($scale < 0) {
        throw new ValueError("$fn(): Argument #$argno (\$scale) must be greater than or equal to 0");
    }
}

// ---- coefficients: strings of digits with no leading zero ----------------------
// Worked nine digits at a time: a limb of nine decimal digits is an int, and
// the product of two plus a carry stays under 2^63.
function _dec_ucmp(string $a, string $b): int {
    $la = strlen($a);
    $lb = strlen($b);
    if ($la < $lb) { return -1; }
    if ($la > $lb) { return 1; }
    $c = strcmp($a, $b);
    if ($c < 0) { return -1; }
    if ($c > 0) { return 1; }
    return 0;
}

// a limb as nine digits, zero-padded
function _dec_limb(int $d): string {
    return str_pad((string) $d, 9, '0', STR_PAD_LEFT);
}

function _dec_strip(string $s): string {
    $r = ltrim($s, '0');
    if ($r === '') { return '0'; }
    return $r;
}

function _dec_uadd(string $a, string $b): string {
    $i = strlen($a);
    $j = strlen($b);
    $carry = 0;
    $out = '';
    while ($i > 0 || $j > 0) {
        $d = $carry;
        if ($i > 0) { $k = min(9, $i); $i -= $k; $d += (int) substr($a, $i, $k); }
        if ($j > 0) { $k = min(9, $j); $j -= $k; $d += (int) substr($b, $j, $k); }
        $carry = 0;
        if ($d >= 1000000000) { $d -= 1000000000; $carry = 1; }
        $out = _dec_limb($d) . $out;
    }
    if ($carry > 0) { $out = '1' . $out; }
    return _dec_strip($out);
}

// $a - $b, and $a >= $b
function _dec_usub(string $a, string $b): string {
    $i = strlen($a);
    $j = strlen($b);
    $borrow = 0;
    $out = '';
    while ($i > 0) {
        $k = min(9, $i);
        $i -= $k;
        $d = (int) substr($a, $i, $k) - $borrow;
        if ($j > 0) { $k = min(9, $j); $j -= $k; $d -= (int) substr($b, $j, $k); }
        $borrow = 0;
        if ($d < 0) { $d += 1000000000; $borrow = 1; }
        $out = _dec_limb($d) . $out;
    }
    return _dec_strip($out);
}

function _dec_umul(string $a, string $b): string {
    if ($a === '0' || $b === '0') { return '0'; }
    // little-endian limbs
    $x = [];
    for ($i = strlen($a); $i > 0; $i -= 9) { $k = min(9, $i); $x[] = (int) substr($a, $i - $k, $k); }
    $y = [];
    for ($j = strlen($b); $j > 0; $j -= 9) { $k = min(9, $j); $y[] = (int) substr($b, $j - $k, $k); }
    $nx = count($x);
    $ny = count($y);
    $r = array_fill(0, $nx + $ny, 0);
    for ($i = 0; $i < $nx; $i++) {
        $carry = 0;
        $xi = $x[$i];
        for ($j = 0; $j < $ny; $j++) {
            $t = $r[$i + $j] + $xi * $y[$j] + $carry;
            $r[$i + $j] = $t % 1000000000;
            $carry = intdiv($t, 1000000000);
        }
        $r[$i + $ny] = $carry;
    }
    $out = '';
    for ($i = $nx + $ny - 1; $i >= 0; $i--) { $out .= _dec_limb($r[$i]); }
    return _dec_strip($out);
}

// Long division of $a by $b (not "0"): "quotient,remainder". A divisor that
// fits in an int -- up to 17 digits, so remainder * 10 + 9 cannot overflow --
// divides digit by digit in ints; a longer one by repeated subtraction.
function _dec_udivmod(string $a, string $b): string {
    $n = strlen($a);
    $q = '';
    if (strlen($b) <= 17) {
        $den = (int) $b;
        $r = 0;
        for ($i = 0; $i < $n; $i++) {
            $r = $r * 10 + ord($a[$i]) - 48;
            $q .= chr(48 + intdiv($r, $den));
            $r = $r % $den;
        }
        return _dec_strip($q) . ',' . $r;
    }
    $rem = '0';
    for ($i = 0; $i < $n; $i++) {
        if ($rem === '0') { $rem = $a[$i]; } else { $rem .= $a[$i]; }
        $k = 0;
        while (_dec_ucmp($rem, $b) >= 0) { $rem = _dec_usub($rem, $b); $k++; }
        $q .= chr(48 + $k);
    }
    return _dec_strip($q) . ',' . $rem;
}

function _dec_zeros(string $coef, int $n): string {
    if ($n <= 0 || $coef === '0') { return $coef; }
    return $coef . str_repeat('0', $n);
}

// ---- signed coefficients: "-1230" or "1230" ----------------------------------
function _dec_sadd(string $x, string $y): string {
    $xn = $x[0] === '-';
    $yn = $y[0] === '-';
    $xa = ltrim($x, '-');
    $ya = ltrim($y, '-');
    if ($xn === $yn) {
        $r = _dec_uadd($xa, $ya);
        if ($xn) { return '-' . $r; }
        return $r;
    }
    $c = _dec_ucmp($xa, $ya);
    if ($c === 0) { return '0'; }
    if ($c > 0) {
        $r = _dec_usub($xa, $ya);
        if ($xn) { return '-' . $r; }
        return $r;
    }
    $r = _dec_usub($ya, $xa);
    if ($yn) { return '-' . $r; }
    return $r;
}

// The ONE place a result is rounded: a signed coefficient at scale $from,
// written with exactly $to digits after the point, half-even.
function _dec_fmt(string $sc, int $from, int $to): string {
    $neg = $sc[0] === '-';
    $coef = ltrim($sc, '-');
    if ($from > $to) {
        $k = $from - $to;
        $len = strlen($coef);
        if ($len <= $k) { $coef = str_repeat('0', $k - $len + 1) . $coef; $len = $k + 1; }
        $keep = substr($coef, 0, $len - $k);
        $drop = substr($coef, $len - $k);
        $first = $drop[0];
        $up = false;
        if ($first > '5') {
            $up = true;
        } elseif ($first === '5') {
            if (ltrim(substr($drop, 1), '0') !== '') {
                $up = true;
            } else {
                $up = (ord($keep[strlen($keep) - 1]) - 48) % 2 === 1;
            }
        }
        $keep = ltrim($keep, '0');
        if ($keep === '') { $keep = '0'; }
        if ($up) { $keep = _dec_uadd($keep, '1'); }
        $coef = $keep;
    } elseif ($from < $to) {
        $coef = _dec_zeros($coef, $to - $from);
    }
    if (ltrim($coef, '0') === '') { $neg = false; }
    if ($to > 0) {
        $len = strlen($coef);
        if ($len <= $to) { $coef = str_repeat('0', $to - $len + 1) . $coef; $len = $to + 1; }
        $coef = substr($coef, 0, $len - $to) . '.' . substr($coef, $len - $to);
    }
    if ($neg) { return '-' . $coef; }
    return $coef;
}

// a number as a signed coefficient at scale $s (>= its own)
function _dec_at(string $v, int $s): string {
    $c = _dec_zeros(_dec_coef($v), $s - _dec_sc($v));
    if (_dec_neg($v)) { return '-' . $c; }
    return $c;
}

function _dec_addsub(string $fn, string $a, string $b, int $scale, bool $minus): string {
    _dec_scale($scale, $fn, 3);
    $x = _dec_valid($a, $fn, 1, 'a');
    $y = _dec_valid($b, $fn, 2, 'b');
    $s = max(_dec_sc($x), _dec_sc($y));
    $yc = _dec_at($y, $s);
    if ($minus) {
        if ($yc[0] === '-') { $yc = substr($yc, 1); } elseif ($yc !== '0') { $yc = '-' . $yc; }
    }
    return _dec_fmt(_dec_sadd(_dec_at($x, $s), $yc), $s, $scale);
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
    $x = _dec_valid($a, 'dec_mul', 1, 'a');
    $y = _dec_valid($b, 'dec_mul', 2, 'b');
    $c = _dec_umul(_dec_coef($x), _dec_coef($y));
    if (_dec_neg($x) !== _dec_neg($y)) { $c = '-' . $c; }
    return _dec_fmt($c, _dec_sc($x) + _dec_sc($y), $scale);
}

// a / b = (ca * 10^sb) / (cb * 10^sa). Scaled by 10^scale that is one integer
// division, and the remainder decides the rounding: 2r against the divisor.
function dec_div(string $a, string $b, int $scale): string {
    _dec_scale($scale, 'dec_div', 3);
    $x = _dec_valid($a, 'dec_div', 1, 'a');
    $y = _dec_valid($b, 'dec_div', 2, 'b');
    $yc = _dec_coef($y);
    if ($yc === '0') { throw new DivisionByZeroError("Division by zero"); }
    $den = _dec_zeros($yc, _dec_sc($x));
    $qr = _dec_udivmod(_dec_zeros(_dec_coef($x), _dec_sc($y) + $scale), $den);
    $p = strpos($qr, ',');
    $q = substr($qr, 0, $p);
    $r = substr($qr, $p + 1);
    $c = _dec_ucmp(_dec_uadd($r, $r), $den);
    if ($c > 0 || ($c === 0 && (ord($q[strlen($q) - 1]) - 48) % 2 === 1)) {
        $q = _dec_uadd($q, '1');
    }
    if (_dec_neg($x) !== _dec_neg($y)) { $q = '-' . $q; }
    return _dec_fmt($q, $scale, $scale);
}

function dec_cmp(string $a, string $b): int {
    $x = _dec_valid($a, 'dec_cmp', 1, 'a');
    $y = _dec_valid($b, 'dec_cmp', 2, 'b');
    $xn = _dec_neg($x);
    if ($xn !== _dec_neg($y)) {
        if ($xn) { return -1; }
        return 1;
    }
    $s = max(_dec_sc($x), _dec_sc($y));
    $c = _dec_ucmp(_dec_zeros(_dec_coef($x), $s - _dec_sc($x)), _dec_zeros(_dec_coef($y), $s - _dec_sc($y)));
    if ($xn) { return -$c; }
    return $c;
}

function dec_round(string $a, int $scale): string {
    _dec_scale($scale, 'dec_round', 2);
    $x = _dec_valid($a, 'dec_round', 1, 'a');
    return _dec_fmt(_dec_at($x, _dec_sc($x)), _dec_sc($x), $scale);
}

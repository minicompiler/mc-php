<?php
// bcmath -- php-src's ext/bcmath ported to PHP and compiled by mc-php into a
// native PHP extension.
//
//     mc-php build examples/bcmath --config examples/bcmath/mcphp.toml
//
// and build/bcmath_port.so is what `php -d extension=...` loads. The functions
// reproduce ext/bcmath (libbcmath) exactly -- EXACT bcmath semantics, which
// means TRUNCATION at the scale, not rounding (examples/decimal is half-even;
// this is a DIFFERENT example). Graded byte for byte against php's own
// built-in bcmath (bccheck.php), and the bench's module/C ratio against a C
// twin (c/bcmath.c) is the DONE bar (README.md): module/C < 2.0.
//
// Why bc_* and not bc*: bcmath is loaded in the php this is graded on, and php
// refuses to redeclare an internal function. So the port publishes bc_add,
// bc_sub, ..., bc_scale and check.php / bccheck.php compare each bc_X against
// the built-in bcX in the same process -- the built-in bcmath IS the
// correctness reference.
//
// THE ALGORITHM is examples/decimal's digit-string core (the magnitude
// helpers below are decimal.php's, proven to agree with bcmath for add, sub,
// mul and div), with bcmath's TRUNCATING formatter in place of half-even and
// the rest of bcmath's surface built on the same helpers: modulo, power,
// powmod, square root, floor, ceil and a generic round. A number is a STRING,
// `[+-]?[0-9]*(\.[0-9]*)?`, parsed exactly as libbcmath's bc_str2num parses it
// (both the integer part and the fraction may be empty, so "", ".", "+" and
// ".5" are all valid), and no float appears anywhere.
//
// It is ordinary PHP: `require` it and the functions are php's own; `mc-php
// build` beside mcphp.toml turns the same file into bcmath_port.so. The _bc_*
// helpers are module-private -- a leading underscore is not published
// (docs/php-extension.md) -- so php sees the bc_* API and nothing else.

// ---- the default scale (bcscale), per request -------------------------------
// bcmath keeps one default scale per request; a function called without a
// scale uses it, and it starts at 0. `global` persists across calls in one
// request (tests/g/128), and an entry no one set reads back unset -> 0.
function _bc_defscale(): int {
    global $__bc_scale;
    return isset($__bc_scale) ? $__bc_scale : 0;
}

// resolve a function's scale argument: null -> the default; otherwise 0..INT_MAX
function _bc_scaleof(?int $scale, string $fn, int $argno): int {
    if ($scale === null) { return _bc_defscale(); }
    if ($scale < 0 || $scale > 2147483647) {
        throw new ValueError("$fn(): Argument #$argno (\$scale) must be between 0 and 2147483647");
    }
    return $scale;
}

// ---- a number: sign, all its digits, how many of them follow the point ------
// bc_str2num's grammar: an optional sign, then [0-9]* integer digits, then an
// optional '.' and [0-9]* fraction digits, and nothing else. Every part may be
// empty: "" is 0, "." is 0, "5." is 5, ".5" is 0.5. Anything else (a space, an
// exponent, a comma, a second point) is not well-formed.
function _bc_parse(string $s, string $fn, int $argno, string $name): int {
    $n = strlen($s);
    $p = 0;
    if ($n > 0 && ($s[0] === '-' || $s[0] === '+')) { $p = 1; }
    $p += strspn($s, '0123456789', $p);
    $sc = 0;
    if ($p < $n && $s[$p] === '.') {
        $sc = strspn($s, '0123456789', $p + 1);
        $p += 1 + $sc;
    }
    if ($p !== $n) {
        throw new ValueError("$fn(): Argument #$argno (\$$name) is not well-formed");
    }
    return $sc;
}

// the magnitude digits of a valid number at scale $sc: sign and point left
// out, integer part then fraction. Empty (e.g. "", ".") is the digit "0".
function _bc_digits(string $s, int $sc): string {
    $n = strlen($s);
    $i = ($n > 0 && ($s[0] === '-' || $s[0] === '+')) ? 1 : 0;
    // The scale $sc (from _bc_parse) fixes the dot's place arithmetically, so
    // no strpos -- which would return int|false and make every use of its
    // result a zval op. With $sc fraction digits the dot is at strlen-$sc-1.
    if ($sc > 0) {
        $dot = $n - $sc - 1;
        return substr($s, $i, $dot - $i) . substr($s, $dot + 1);
    }
    // $sc == 0: integer digits only; drop a trailing '.' ("5.", ".", "+")
    $end = ($n > 0 && $s[$n - 1] === '.') ? $n - 1 : $n;
    return $i >= $end ? '0' : substr($s, $i, $end - $i);
}

// negative, and not zero (a zero is never negative in bcmath)
function _bc_neg(string $s, string $d): bool {
    return $s !== '' && $s[0] === '-' && strspn($d, '0') < strlen($d);
}

// a magnitude is zero: all its digits are '0'. A strspn, no substr -- cheaper
// than _bc_ucmp($d, '0'), which skip0's both sides into new strings.
function _bc_iszero(string $d): bool {
    return strspn($d, '0') === strlen($d);
}

// ---- magnitudes: digit strings, most significant first (decimal.php's) ------
// skip0: how many leading zeros to step over, keeping at least one digit
function _bc_skip0(string $d): int {
    $k = strspn($d, '0');
    if ($k === strlen($d)) { $k--; }
    return $k;
}

// an integer argument: its fraction must be all zeros (trailing zeros carry no
// scale in bcmath, so "2.0" is the integer 2). Returns the magnitude's integer
// digits, leading zeros removed. Throws the "cannot have a fractional part"
// ValueError otherwise.
function _bc_intonly(string $d, int $sc, string $fn, int $argno, string $name): string {
    if ($sc > 0) {
        if (strspn($d, '0', strlen($d) - $sc) !== $sc) {
            throw new ValueError("$fn(): Argument #$argno (\$$name) cannot have a fractional part");
        }
        $d = substr($d, 0, strlen($d) - $sc);
        if ($d === '') { $d = '0'; }
    }
    return substr($d, _bc_skip0($d));
}


function _bc_ucmp(string $a, string $b): int {
    $ka = _bc_skip0($a);
    $kb = _bc_skip0($b);
    $na = strlen($a) - $ka;
    $nb = strlen($b) - $kb;
    if ($na !== $nb) { return $na < $nb ? -1 : 1; }
    // no leading zeros on either side (the money-shaped common case): the
    // strings compare directly, with no substr copy of each
    $c = ($ka === 0 && $kb === 0) ? strcmp($a, $b) : strcmp(substr($a, $ka), substr($b, $kb));
    if ($c < 0) { return -1; }
    return $c > 0 ? 1 : 0;
}

// max(na, nb) + 1 digits
function _bc_uadd(string $a, string $b): string {
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
function _bc_usub(string $a, string $b): string {
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
function _bc_umul(string $a, string $b): string {
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
// in one string -- the caller knows where the quotient ends. (decimal.php's.)
function _bc_udivmod(string $a, string $b): string {
    $b = substr($b, _bc_skip0($b));
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
            $z = 0;
            while ($z < $rn - 1 && $r[$z] === '0') { $z++; }
            if ($z > 0) {
                for ($m = 0; $m < $rn - $z; $m++) { $r[$m] = $r[$m + $z]; }
                $rn -= $z;
            }
            if ($rn < $nb) { break; }
            if ($rn === $nb) {
                $m = 0;
                while ($m < $nb && $r[$m] === $b[$m]) { $m++; }
                if ($m < $nb && ord($r[$m]) < ord($b[$m])) { break; }
            }
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

// a number's digits at scale $s (>= its own): the digits padded with zeros
function _bc_at(string $d, int $sc, int $s): string {
    if ($s === $sc) { return $d; }
    return $d . str_repeat('0', $s - $sc);
}

// ---- the ONE place a result is written: TRUNCATION, never rounding ----------
// $c: a magnitude at scale $from; the answer has exactly $to digits after the
// point, obtained by dropping (not rounding) the digits past $to or padding
// with zeros. A zero is never negative.
function _bc_fmt(bool $neg, string $c, int $from, int $to): string {
    if ($from > $to) {
        $k = $from - $to;
        $len = strlen($c);
        $c = $len > $k ? substr($c, 0, $len - $k) : '0';
    } elseif ($to > $from) {
        $c .= str_repeat('0', $to - $from);
    }
    $c0 = _bc_skip0($c);
    $wn = strlen($c) - $c0;
    if (strspn($c, '0', $c0) === $wn) { $neg = false; }
    $o = $neg ? '-' : '';
    if ($wn > $to) {
        $il = $wn - $to;
        $o .= substr($c, $c0, $il);
    } else {
        $il = 0;
        $o .= '0';
    }
    if ($to > 0) {
        $o .= '.';
        if ($wn < $to) { $o .= str_repeat('0', $to - $wn); }
        $o .= substr($c, $c0 + $il, $to);
    }
    return $o;
}

// ---- add / sub --------------------------------------------------------------
// exact sum/difference at max(scale_a, scale_b), truncated to $scale
function _bc_addsub(string $fn, string $a, string $b, int $s, bool $minus): string {
    $xs = _bc_parse($a, $fn, 1, 'num1');
    $ys = _bc_parse($b, $fn, 2, 'num2');
    $xd = _bc_digits($a, $xs);
    $yd = _bc_digits($b, $ys);
    $xn = _bc_neg($a, $xd);
    $yn = _bc_neg($b, $yd);
    if ($minus) { $yn = !$yn && !_bc_iszero($yd); }
    $m = $xs > $ys ? $xs : $ys;
    $cx = _bc_at($xd, $xs, $m);
    $cy = _bc_at($yd, $ys, $m);
    if ($xn === $yn) {
        $r = _bc_uadd($cx, $cy);
        $neg = $xn;
    } elseif (_bc_ucmp($cx, $cy) >= 0) {
        $r = _bc_usub($cx, $cy);
        $neg = $xn;
    } else {
        $r = _bc_usub($cy, $cx);
        $neg = $yn;
    }
    return _bc_fmt($neg, $r, $m, $s);
}

function bc_add(string $num1, string $num2, ?int $scale = null): string {
    return _bc_addsub('bc_add', $num1, $num2, _bc_scaleof($scale, 'bc_add', 3), false);
}

function bc_sub(string $num1, string $num2, ?int $scale = null): string {
    return _bc_addsub('bc_sub', $num1, $num2, _bc_scaleof($scale, 'bc_sub', 3), true);
}

// ---- mul --------------------------------------------------------------------
// exact product (scale xs+ys), truncated to min($scale, xs+ys), padded to $scale
function bc_mul(string $num1, string $num2, ?int $scale = null): string {
    $s = _bc_scaleof($scale, 'bc_mul', 3);
    $xs = _bc_parse($num1, 'bc_mul', 1, 'num1');
    $ys = _bc_parse($num2, 'bc_mul', 2, 'num2');
    $xd = _bc_digits($num1, $xs);
    $yd = _bc_digits($num2, $ys);
    $r = _bc_umul($xd, $yd);
    return _bc_fmt(_bc_neg($num1, $xd) !== _bc_neg($num2, $yd), $r, $xs + $ys, $s);
}

// ---- div --------------------------------------------------------------------
// quotient truncated toward zero to $scale fraction digits. a / b =
// (xd * 10^ys) / (yd * 10^xs), carried out $scale extra places.
function bc_div(string $num1, string $num2, ?int $scale = null): string {
    $s = _bc_scaleof($scale, 'bc_div', 3);
    $xs = _bc_parse($num1, 'bc_div', 1, 'num1');
    $ys = _bc_parse($num2, 'bc_div', 2, 'num2');
    $xd = _bc_digits($num1, $xs);
    $yd = _bc_digits($num2, $ys);
    if (_bc_iszero($yd)) {
        throw new DivisionByZeroError("Division by zero");
    }
    $nn = strlen($xd) + $ys + $s;
    $num = $xd . str_repeat('0', $ys + $s);
    $den = $yd . str_repeat('0', $xs);
    $q = substr(_bc_udivmod($num, $den), 0, $nn);
    return _bc_fmt(_bc_neg($num1, $xd) !== _bc_neg($num2, $yd), $q, $s, $s);
}

// ---- mod --------------------------------------------------------------------
// r = num1 - trunc(num1 / num2) * num2, exact, truncated to $scale. The
// remainder of the scaled integer division IS that value; its sign follows the
// dividend.
function bc_mod(string $num1, string $num2, ?int $scale = null): string {
    $s = _bc_scaleof($scale, 'bc_mod', 3);
    $xs = _bc_parse($num1, 'bc_mod', 1, 'num1');
    $ys = _bc_parse($num2, 'bc_mod', 2, 'num2');
    $xd = _bc_digits($num1, $xs);
    $yd = _bc_digits($num2, $ys);
    if (_bc_iszero($yd)) {
        throw new DivisionByZeroError("Modulo by zero");
    }
    $m = $xs > $ys ? $xs : $ys;
    $cx = _bc_at($xd, $xs, $m);
    $cy = _bc_at($yd, $ys, $m);
    $qr = _bc_udivmod($cx, $cy);
    $r = substr($qr, strlen($cx));
    return _bc_fmt(_bc_neg($num1, $xd), $r, $m, $s);
}

// ---- integer magnitude power (exponentiation by squaring) -------------------
function _bc_upow(string $d, int $e): string {
    $d = substr($d, _bc_skip0($d));
    $result = '1';
    while ($e > 0) {
        if ($e & 1) {
            $result = _bc_umul($result, $d);
            $result = substr($result, _bc_skip0($result));
        }
        $e >>= 1;
        if ($e > 0) {
            $d = _bc_umul($d, $d);
            $d = substr($d, _bc_skip0($d));
        }
    }
    return $result;
}

// ---- pow --------------------------------------------------------------------
// integer exponent only. For e >= 0 the exact power (scale xs*e) is truncated
// to min($scale, xs*e) and padded to $scale; for e < 0 it is 1 / base^|e|
// truncated to $scale. 0^0 is 1; a negative power of zero throws.
function bc_pow(string $num, string $exponent, ?int $scale = null): string {
    $s = _bc_scaleof($scale, 'bc_pow', 3);
    $xs = _bc_parse($num, 'bc_pow', 1, 'num');
    $es = _bc_parse($exponent, 'bc_pow', 2, 'exponent');
    $ed = _bc_intonly(_bc_digits($exponent, $es), $es, 'bc_pow', 2, 'exponent');
    if (strlen($ed) > 18) {
        throw new ValueError("bc_pow(): Argument #2 (\$exponent) is too large");
    }
    $e = (int) $ed;
    $eneg = _bc_neg($exponent, $ed);
    if ($e === 0) {
        return _bc_fmt(false, '1', 0, $s);
    }
    $xd = _bc_digits($num, $xs);
    if (_bc_iszero($xd)) {
        if ($eneg) {
            throw new DivisionByZeroError("Negative power of zero");
        }
        return _bc_fmt(false, '0', 0, $s);
    }
    $p = _bc_upow($xd, $e);
    $psc = $xs * $e;
    $psign = _bc_neg($num, $xd) && ($e & 1) === 1;
    if (!$eneg) {
        return _bc_fmt($psign, $p, $psc, $s);
    }
    // 1 / (p / 10^psc) = 10^(psc + s) / p, truncated to $s fraction digits
    $nn = 1 + $psc + $s;
    $q = substr(_bc_udivmod('1' . str_repeat('0', $psc + $s), $p), 0, $nn);
    return _bc_fmt($psign, $q, $s, $s);
}

// ---- powmod -----------------------------------------------------------------
// (num ^ exponent) mod modulus, integers only, exponent >= 0. Square and
// multiply with a modulo (sign following the dividend) at each step, exactly
// as libbcmath does; the integer result is padded to $scale.
function bc_powmod(string $num, string $exponent, string $modulus, ?int $scale = null): string {
    $s = _bc_scaleof($scale, 'bc_powmod', 4);
    $ns = _bc_parse($num, 'bc_powmod', 1, 'num');
    $xd = _bc_intonly(_bc_digits($num, $ns), $ns, 'bc_powmod', 1, 'num');
    $es = _bc_parse($exponent, 'bc_powmod', 2, 'exponent');
    $ed = _bc_intonly(_bc_digits($exponent, $es), $es, 'bc_powmod', 2, 'exponent');
    if (_bc_neg($exponent, $ed)) {
        throw new ValueError("bc_powmod(): Argument #2 (\$exponent) must be greater than or equal to 0");
    }
    $ms = _bc_parse($modulus, 'bc_powmod', 3, 'modulus');
    $md = _bc_intonly(_bc_digits($modulus, $ms), $ms, 'bc_powmod', 3, 'modulus');
    if (_bc_iszero($md)) {
        throw new DivisionByZeroError("Modulo by zero");
    }
    if (_bc_ucmp($md, '1') === 0) {
        return _bc_fmt(false, '0', 0, $s);
    }
    // Square and multiply on magnitudes and signs, as libbcmath and the C
    // twin do: each product reduced mod the modulus by the long division,
    // the remainder's sign following the dividend's and a zero never
    // negative. The power starts as num mod modulus; squaring makes it
    // non-negative.
    $power = substr(_bc_udivmod($xd, $md), strlen($xd));
    $psign = _bc_neg($num, $xd) && $power !== '0';
    $temp = '1';
    $tsign = false;
    $exp = substr($ed, _bc_skip0($ed));
    while ($exp !== '0') {
        $odd = (ord($exp[strlen($exp) - 1]) - 48) & 1;
        $q = substr(_bc_udivmod($exp, '2'), 0, strlen($exp));
        $exp = substr($q, _bc_skip0($q));
        if ($odd) {
            $pr = _bc_umul($temp, $power);
            $temp = substr(_bc_udivmod($pr, $md), strlen($pr));
            $tsign = $tsign !== $psign && $temp !== '0';
        }
        $sq = _bc_umul($power, $power);
        $power = substr(_bc_udivmod($sq, $md), strlen($sq));
        $psign = false;
    }
    // $temp is an integer magnitude; render it at $scale (pad only)
    return _bc_fmt($tsign, $temp, 0, $s);
}

// ---- integer square root (floor) -------------------------------------------
// Newton's method on digit strings: x_{n+1} = floor((x_n + floor(S/x_n)) / 2),
// started above sqrt(S); it descends to floor(sqrt(S)).
function _bc_isqrt(string $s): string {
    $s = substr($s, _bc_skip0($s));
    if ($s === '0') { return '0'; }
    $x = '1' . str_repeat('0', intdiv(strlen($s) + 1, 2));
    while (true) {
        $q = substr(_bc_udivmod($s, $x), 0, strlen($s));   // floor(S / x)
        $d = _bc_uadd($x, $q);
        $y = substr(_bc_udivmod($d, '2'), 0, strlen($d));  // floor((x + S/x) / 2)
        $y = substr($y, _bc_skip0($y));
        if (_bc_ucmp($y, $x) >= 0) { break; }
        $x = $y;
    }
    return $x;
}

// ---- sqrt -------------------------------------------------------------------
// floor(sqrt(num)) at $scale fraction digits: isqrt of num scaled by 10^(2s).
function bc_sqrt(string $num, ?int $scale = null): string {
    $s = _bc_scaleof($scale, 'bc_sqrt', 2);
    $xs = _bc_parse($num, 'bc_sqrt', 1, 'num');
    $xd = _bc_digits($num, $xs);
    if (_bc_neg($num, $xd)) {
        throw new ValueError("bc_sqrt(): Argument #1 (\$num) must be greater than or equal to 0");
    }
    if (_bc_iszero($xd)) {
        return _bc_fmt(false, '0', 0, $s);
    }
    $d2 = 2 * $s - $xs;
    if ($d2 >= 0) {
        $m = $xd . str_repeat('0', $d2);
    } else {
        $keep = strlen($xd) + $d2;
        $m = $keep > 0 ? substr($xd, 0, $keep) : '0';
    }
    return _bc_fmt(false, _bc_isqrt($m), $s, $s);
}

// ---- comp -------------------------------------------------------------------
// compare at $scale: each fraction truncated to min(its own, $scale) first.
function bc_comp(string $num1, string $num2, ?int $scale = null): int {
    $s = _bc_scaleof($scale, 'bc_comp', 3);
    $xs = _bc_parse($num1, 'bc_comp', 1, 'num1');
    $ys = _bc_parse($num2, 'bc_comp', 2, 'num2');
    $xd = _bc_digits($num1, $xs);
    $yd = _bc_digits($num2, $ys);
    // truncate each fraction to the compare scale, THEN judge sign: a value
    // that truncates to zero is not negative (bccomp('-0.1', '0', 0) is 0).
    $tx = $xs > $s ? $s : $xs;
    $ty = $ys > $s ? $s : $ys;
    if ($xs > $tx) { $xd = substr($xd, 0, strlen($xd) - ($xs - $tx)); }
    if ($ys > $ty) { $yd = substr($yd, 0, strlen($yd) - ($ys - $ty)); }
    $xn = $num1 !== '' && $num1[0] === '-' && strspn($xd, '0') < strlen($xd);
    $yn = $num2 !== '' && $num2[0] === '-' && strspn($yd, '0') < strlen($yd);
    if ($xn !== $yn) {
        return $xn ? -1 : 1;
    }
    $m = $tx > $ty ? $tx : $ty;
    $r = _bc_ucmp(_bc_at($xd, $tx, $m), _bc_at($yd, $ty, $m));
    return $xn ? -$r : $r;
}

// ---- scale ------------------------------------------------------------------
// bcscale: read and (optionally) set the request default scale. php keeps it in
// BCG(bc_precision): per request, and per php thread under ZTS. Here it is a
// `global`, which mc-php keeps the same way (docs/threads.md, "What each
// request starts from"): per php thread, copied fresh at each request. The
// module's OWN worker threads would share it, but this file starts none, and
// another module's worker reaches bc_scale only through php's engine -- refused
// on a worker, or under ZTS a php request of its own with its own copy
// (tests/ext/threads/bcscale.php, tests/ext.sh step 20d). So no lock: only the
// request's own thread ever writes it.
function bc_scale(?int $scale = null): int {
    global $__bc_scale;
    $old = isset($__bc_scale) ? $__bc_scale : 0;
    if ($scale !== null) {
        if ($scale < 0 || $scale > 2147483647) {
            throw new ValueError("bc_scale(): Argument #1 (\$scale) must be between 0 and 2147483647");
        }
        $__bc_scale = $scale;
    }
    return $old;
}

// ---- floor / ceil -----------------------------------------------------------
// integer result: floor rounds toward -inf, ceil toward +inf.
function _bc_floorceil(string $num, string $fn, bool $isfloor): string {
    $xs = _bc_parse($num, $fn, 1, 'num');
    $xd = _bc_digits($num, $xs);
    $neg = _bc_neg($num, $xd);
    $len = strlen($xd);
    $ip = $xs >= $len ? '0' : substr($xd, 0, $len - $xs);
    $fracnz = $xs > 0 && strspn($xd, '0', $len - $xs) < $xs;
    if ($fracnz && (($neg && $isfloor) || (!$neg && !$isfloor))) {
        $ip = _bc_uadd($ip, '1');
    }
    return _bc_fmt($neg, $ip, 0, 0);
}

function bc_floor(string $num): string {
    return _bc_floorceil($num, 'bc_floor', true);
}

function bc_ceil(string $num): string {
    return _bc_floorceil($num, 'bc_ceil', false);
}

// ---- round (half away from zero) -------------------------------------------
// libbcmath's bc_round for the default mode, RoundingMode::HalfAwayFromZero
// (PHP_ROUND_HALF_UP): the first dropped digit decides, >= 5 rounds away from
// zero. $precision may be negative (round to tens, hundreds, ...).
function bc_round(string $num, int $precision = 0): string {
    if ($precision > 2147483647) {
        throw new ValueError("bc_round(): Argument #2 (\$precision) must be between -9223372036854775808 and 2147483647");
    }
    $xs = _bc_parse($num, 'bc_round', 1, 'num');
    $xd = _bc_digits($num, $xs);
    $neg = _bc_neg($num, $xd);
    // canonical digits: integer part leading zeros removed (>= 1 digit),
    // followed by $xs fraction digits.
    $total = strlen($xd);
    $ilen = $total - $xs;
    if ($ilen <= 0) {
        $nlen = 1;
        $nval = '0' . str_repeat('0', -$ilen) . $xd;
    } else {
        $ip = substr($xd, 0, $ilen);
        $z = strspn($ip, '0');
        if ($z === $ilen) { $z = $ilen - 1; }
        $ip = substr($ip, $z);
        $nlen = strlen($ip);
        $nval = $ip . substr($xd, $ilen);
    }
    // the number is smaller than the place being rounded to -> 0 (HalfAwayFromZero).
    // `$nlen < -$precision`, written without the negation: -PHP_INT_MIN
    // overflows a C integer (docs/semantics.md), and $nlen >= 1 keeps the sum
    // in range for every accepted precision.
    if ($precision < 0 && $nlen + $precision < 0) {
        return '0';
    }
    // rounding to more places than the number has: unchanged, padded
    if ($precision >= 0 && $xs <= $precision) {
        return _bc_fmt($neg, $nval, $xs, $precision);
    }
    $rsc = $precision > 0 ? $precision : 0;
    $rlen = $nlen + $precision;      // digits kept from the left
    $w = $nlen + $xs;                // width of $nval
    $up = $rlen < $w && ord($nval[$rlen]) - 48 >= 5;
    if ($rlen <= 0) {
        // the kept value is 0; rounding away adds 1 at the 10^(-precision) place
        if (!$up) { return _bc_fmt(false, '0', 0, $rsc); }
        return _bc_fmt($neg, '1' . str_repeat('0', $nlen - $rlen), 0, $rsc);
    }
    $kept = str_pad(substr($nval, 0, $rlen), $nlen + $rsc, '0', STR_PAD_RIGHT);
    if ($up) {
        // a one at the last kept place: zeros, then the digit written in place
        $one = str_repeat('0', $nlen + $rsc);
        $one[$rlen - 1] = '1';
        $kept = _bc_uadd($kept, $one);
        return _bc_fmt($neg, $kept, $rsc, $rsc);
    }
    return _bc_fmt($neg, $kept, $rsc, $rsc);
}

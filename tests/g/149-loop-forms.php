<?php
// The shapes four lowering changes rewrite, each against php's own answer:
//  * a `continue` that names its `for` carries a copy of the step
//    (src/stmt.mc ph_cont_step): with and without braces, beside a continue
//    from a nested loop (which keeps the first-iteration flag), a continue 2,
//    and a foreach;
//  * `y = x / K` moves up to the statement computing `x % K`, which becomes
//    `x - y * K` (src/opt.mc phq_list) -- and stays where it is when y is
//    read, or x written, in between;
//  * a FIXED packed array with no `$x[] =` keeps its buffer pointer in a
//    local (src/packed.mc STABLE), reinitialised inside a loop too, with a
//    computed key that is no temporary;
//  * a literal on the left of + or * moves to the right.
declare(strict_types=1);

function cont_braces(int $n): string {
    $s = '';
    for ($i = 0; $i < $n; $i++) { if ($i % 3 === 0) { continue; } $s .= $i; }
    return $s;
}
function cont_bare(int $n): int {
    $t = 0;
    for ($i = 0; $i < $n; $i += 1) {
        if ($i === 2) continue;
        if ($i === 5) continue;
        $t += $i * (10 - $i);
    }
    return $t;
}
function cont_nested(int $n): string {
    $s = '';
    for ($i = 0; $i < $n; $i++) {
        for ($k = 0; $k < 3; $k++) { if ($k === 1) { continue 2; } $s .= "$i$k,"; }
        $s .= '!';
    }
    return $s;
}
function cont_inner(int $n): string {
    $s = '';
    for ($i = 0; $i < $n; $i++) {
        if ($i === 1) { continue; }
        for ($k = 0; $k < 4; $k++) { if ($k % 2 === 1) { continue; } $s .= "$i$k "; }
    }
    return $s;
}
function cont_each(array $a): int {
    $t = 0;
    foreach ($a as $k => $v) { if ($v < 0) { continue; } $t += (int) $k * (int) $v; }
    return $t;
}

function digits(int $v): string {
    $out = str_repeat('0', 20);
    $carry = $v;
    for ($k = 0; $k < 20; $k++) {
        $t = $carry;
        $out[19 - $k] = chr(48 + $t % 10);
        $carry = intdiv($t, 10);
    }
    return $out;
}
function divmod_read(int $t): string {
    $q = 5;
    $r = $t % 7;
    $s = "q was $q";
    $q = intdiv($t, 7);
    return "$r $q $s";
}
function divmod_write(int $t): string {
    $r = $t % 9;
    $t = $t + 1;
    $q = intdiv($t, 9);
    return "$r $q";
}
function divmod_neg(int $t): string {
    $r = -$t % 10;
    $u = -$t;
    $r2 = $u % 10;
    $q = intdiv($u, 10);
    return "$r $r2 $q";
}

function conv(string $a, string $b): string {
    $na = strlen($a);
    $nb = strlen($b);
    $out = '';
    for ($round = 0; $round < 2; $round++) {
        $acc = array_fill(0, $na + $nb, 0);
        for ($i = 0; $i < $na; $i++) {
            for ($j = 0; $j < $nb; $j++) {
                $acc[$i + $j] = $acc[$i + $j] + (ord($a[$i]) - 48) * (ord($b[$j]) - 48 + $round);
            }
        }
        for ($k = 0; $k < $na + $nb; $k++) { $out .= $acc[$k] . ' '; }
        $out .= '| ';
    }
    return $out;
}
function lit_left(int $x): int { return (48 + $x) * 1000 + 3 * $x + (2 + $x) * 7; }

echo cont_braces(10), "\n", cont_bare(9), "\n", cont_nested(3), "\n", cont_inner(3), "\n";
echo cont_each([3, -1, 4, -1, 5]), "\n";
echo digits(1234567890123), " ", digits(-987), " ", digits(PHP_INT_MAX), "\n";
echo divmod_read(100), " / ", divmod_write(80), " / ", divmod_neg(1234), " / ", divmod_neg(-56), "\n";
echo conv('1234', '567'), "\n";
echo lit_left(5), " ", lit_left(-48), "\n";

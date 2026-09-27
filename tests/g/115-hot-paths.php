<?php
// The runtime's fast paths copied into the compiled code (src/opt.mc, phr_*):
// a string offset read as its byte, a byte written in place, a packed
// element read and written, an overflow-checked add, intdiv -- each with the
// slow half it falls back to: a negative offset, a string shared by two
// names, a key outside the array (php's warning, and the line it names --
// the announcement moved into that slow half), an array that became a hash,
// a division by zero. And the loops around them: a `for` whose step follows
// its body, one with a `continue` that still runs the step, an int-literal
// ternary, strspn from an offset, str_repeat of nothing.
function bytes(string $s): int {
    $t = 0;
    for ($i = 0; $i < strlen($s); $i++) { $t = $t * 3 + ord($s[$i]) - 48; }
    return $t + ord($s[-1]);
}
function digits(int $n): string {
    $out = str_repeat('0', $n);
    for ($k = 0; $k < $n; $k++) { $out[$n - 1 - $k] = chr(48 + ($k * 7) % 10); }
    $out[-1] = chr(65);
    return $out;
}
function shared(string $a): string {
    $b = $a;
    $b[0] = chr(120);
    return $a . "/" . $b;
}
function acc(int $n): int {
    $a = array_fill(0, $n, 0);
    for ($i = 0; $i < $n; $i++) {
        for ($j = 0; $j < $n; $j++) { $a[($i + $j) % $n] = $a[($i + $j) % $n] + $i * $j; }
    }
    $s = $a[1] + $a[$n + 2];
    $a[$n + 3] = 7;
    return $s + $a[1] + $a[$n + 3] + $a[$n - 1] + $a[$n + 5];
}
function carry(int $d): int { return $d >= 10 ? 1 : 0; }
function sign(int $a, int $b): int { return $a < $b ? -1 : 1; }
function skipper(): string {
    $r = '';
    for ($i = 0; $i < 6; $i++) {
        if ($i % 2) { continue; }
        $r .= $i;
    }
    return $r;
}
function divs(int $a, int $b): int { return intdiv($a, $b); }

echo bytes("12345"), "\n";
echo bytes("7"), "\n";
echo digits(6), "\n";
echo shared("abc"), "\n";
echo acc(4), "\n";
echo carry(9), carry(10), carry(19), sign(1, 2), sign(3, 2), "\n";
echo skipper(), "\n";
echo divs(7, 2), " ", divs(-7, 2), " ", divs(7, -2), "\n";
try { echo divs(1, 0), "\n"; } catch (DivisionByZeroError $e) { echo get_class($e), ": ", $e->getMessage(), "\n"; }
echo strspn("0012300", "0"), strspn("0012300", "0", 5), strspn("0012300", "0", -2), strspn("0012300", "0", 9), "\n";
echo "[", str_repeat("0", 0), str_repeat("ab", 0), str_repeat("x", 1), "]\n";

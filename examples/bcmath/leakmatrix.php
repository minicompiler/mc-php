<?php
// The leak matrix for bcmath_port.so, driven under the debug allocator
// (tests/leaks.sh): every bc_* over every argument shape, for many rounds, so
// a block the module leaks -- an intermediate digit string an error path
// forgot, the nullable scale's borrowed zval, a result not handed back -- is a
// block the debug allocator still holds when the request ends.
//
// bcmath builds many intermediate strings per call and throws on a malformed
// number, a zero divisor, a fractional exponent and a negative scale; each of
// those paths is driven here, with the reference / resource / array / object /
// stringable argument shapes a type-rejection must not leak over either.
declare(strict_types=1);

class Stringy { function __toString(): string { return "7"; } }

// numbers worth feeding: valid (every sign, scale and the empty/dot forms),
// and malformed (the ValueError path, which must free the digits built so far)
$nums = ['0', '-0', '123456.789', '-98765.4321', '1000000000000000000.5',
         '0.000001', '-0.5', '', '.', '5.', '.5', '12.', '+7', '7',
         'xyz', ' 5', '1e3', '5.0.0', '3.1'];
$scales = [null, 0, 2, 8, -1];

$acc = 0;
function tally(callable $f): int {
    try { return strlen((string) $f()); }
    catch (\Throwable $e) { return strlen($e->getMessage()); }
}

for ($r = 0; $r < 120; $r++) {
    // a fresh refcounted (non-interned) string and a reference to it each round
    $big = str_repeat('9', 30) . $r . '.' . $r;
    $ref = $big; $alias = &$ref;
    $res = fopen('php://memory', 'r');
    $obj = new stdClass;
    foreach ($nums as $a) {
        foreach ($scales as $s) {
            $b = $nums[($r + strlen($a)) % count($nums)];
            $acc += tally(fn() => bc_add($a, $b, $s));
            $acc += tally(fn() => bc_sub($a, $b, $s));
            $acc += tally(fn() => bc_mul($a, $b, $s));
            $acc += tally(fn() => bc_div($a, $b, $s));
            $acc += tally(fn() => bc_mod($a, $b, $s));
            $acc += tally(fn() => bc_comp($a, $b, $s ?? 0));
            $acc += tally(fn() => bc_pow($a, (string) (($r % 9) - 3), $s));
            $acc += tally(fn() => bc_powmod($a, (string) ($r % 6), $b === '0' ? '7' : $b, $s));
            $acc += tally(fn() => bc_sqrt(ltrim($a, '-'), $s));
        }
        $acc += tally(fn() => bc_floor($a));
        $acc += tally(fn() => bc_ceil($a));
        $acc += tally(fn() => bc_round($a, ($r % 7) - 3));
    }
    // the borrowed-string path over a reference and a stringable, and the
    // type-rejection path over a resource / array / object (strict TypeError)
    $acc += tally(fn() => bc_add($alias, '1', 2));
    $acc += tally(fn() => bc_mul($big, $big, 4));
    $acc += tally(fn() => bc_scale($r % 5));
    $acc += tally(fn() => bc_add((new Stringy)->__toString(), '2', 1));
    foreach ([$res, [1, 2], $obj, 3.5, true, null] as $bad) {
        $acc += tally(fn() => bc_add($bad, '1', 0));   // string param, wrong type
    }
    fclose($res);
}
bc_scale(0);
echo "acc=$acc\n";

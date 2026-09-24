<?php
// A second oracle for decimal.so: bcmath, php's own arbitrary-precision
// library, where the host php has it. Run with the module loaded:
//
//     php -d extension=build/decimal.so bccheck.php
//
// bcmath TRUNCATES at the scale and this module rounds HALF-EVEN, so the
// comparison is against bcmath's EXACT result rounded by bcmath's own
// bcround(..., RoundingMode::HalfEven): add, sub and mul are exact at the sum of
// the two scales, and a quotient is taken to 80 digits first -- exact for every
// divisor here, since a tie at scale s needs the digits after s to be exactly
// 5000... and bcdiv would show them.
//
// Prints how many it checked and exits 1 on the first wrong answer.
declare(strict_types=1);

if (!extension_loaded('decimal')) { echo "load decimal.so first\n"; exit(2); }
if (!extension_loaded('bcmath')) { echo "no bcmath in this php\n"; exit(2); }

mt_srand(20260923);
function rnd(): string {
    if (mt_rand(0, 7) === 0) { return (mt_rand(0, 1) ? '-' : '') . '0'; }
    $s = mt_rand(0, 3) === 0 ? '-' : '';
    $il = mt_rand(1, 22);
    for ($i = 0; $i < $il; $i++) { $s .= (string) mt_rand(0, 9); }
    $fl = mt_rand(0, 10);
    if ($fl > 0) { $s .= '.'; for ($i = 0; $i < $fl; $i++) { $s .= (string) mt_rand(0, 9); } }
    return $s;
}
function want(string $exact, int $scale): string {
    return bcadd(bcround($exact, $scale, RoundingMode::HalfEven), '0', $scale);
}

$n = 0;
$fixed = [['1', '3', 10], ['2', '3', 4], ['1', '8', 2], ['-1', '8', 2], ['0.125', '1', 2],
          ['99.995', '1', 2], ['123456789.123456789', '-0.000000001', 12]];
$cases = $fixed;
for ($k = 0; $k < 200; $k++) { $cases[] = [rnd(), rnd(), mt_rand(0, 14)]; }
foreach ($cases as [$a, $b, $s]) {
    $got = [dec_add($a, $b, $s), dec_sub($a, $b, $s), dec_mul($a, $b, $s),
            dec_round($a, $s), (string) dec_cmp($a, $b)];
    $exp = [want(bcadd($a, $b, 40), $s), want(bcsub($a, $b, 40), $s),
            want(bcmul($a, $b, 60), $s), want($a, $s), (string) bccomp($a, $b, 40)];
    if (bccomp($b, '0', 40) !== 0) {
        $got[] = dec_div($a, $b, $s);
        $exp[] = want(bcdiv($a, $b, 80), $s);
    }
    foreach ($got as $i => $g) {
        $n++;
        if ($g !== $exp[$i]) {
            echo "WRONG op #$i on ($a, $b, $s): decimal says $g, bcmath says {$exp[$i]}\n";
            exit(1);
        }
    }
}
echo "bcmath agrees: $n results, 0 wrong\n";

<?php
// The bench: the module's cty_* against php's own compiled-in ctype_*, in the
// same process (both are present when ctype.so is loaded), best of nine, the
// two interleaved so neither pays for the other's warm-up. ext/ctype IS the
// reference here, so the printed ratio is cty_* / ctype_* -- the module over
// the real C extension. DONE is < 2.0.
//
//     php -d extension=build/ctype.so bench.php
//
// The workload is ctype's own: validate a batch of short tokens, the shape
// code using ctype has -- a name, a hex colour, a number, an identifier, a
// sentence with spaces -- across the predicates that matter for each. Both
// sides do identical work, so the ratio is the thin glue the port adds over a
// per-byte libc loop that both already share.
declare(strict_types=1);
// The port targets the C locale; set it so the reference ctype_* matches it.
setlocale(LC_CTYPE, "C");

$tokens = ['Name', 'hello_world', 'deadBEEF', '0123456789', 'Mixed123',
           'has space', 'UPPER', 'lower', 'a', 'Z9', 'tab	here', '42'];
$ITERS = 40000;

function work_cty(array $tokens): int {
    $n = 0;
    foreach ($tokens as $t) {
        if (cty_alnum($t))  $n++;
        if (cty_alpha($t))  $n++;
        if (cty_digit($t))  $n++;
        if (cty_upper($t))  $n++;
        if (cty_lower($t))  $n++;
        if (cty_xdigit($t)) $n++;
        if (cty_space($t))  $n++;
        if (cty_punct($t))  $n++;
    }
    return $n;
}

function work_ref(array $tokens): int {
    $n = 0;
    foreach ($tokens as $t) {
        if (ctype_alnum($t))  $n++;
        if (ctype_alpha($t))  $n++;
        if (ctype_digit($t))  $n++;
        if (ctype_upper($t))  $n++;
        if (ctype_lower($t))  $n++;
        if (ctype_xdigit($t)) $n++;
        if (ctype_space($t))  $n++;
        if (ctype_punct($t))  $n++;
    }
    return $n;
}

$ac = 0; $ar = 0;
for ($i = 0; $i < $ITERS; $i++) { $ac += work_cty($tokens); }
for ($i = 0; $i < $ITERS; $i++) { $ar += work_ref($tokens); }
if ($ac !== $ar) { echo "MISMATCH $ac $ar\n"; exit(1); }

$bc = INF; $br = INF;
for ($r = 0; $r < 9; $r++) {
    $t = hrtime(true);
    $s = 0; for ($i = 0; $i < $ITERS; $i++) { $s += work_cty($tokens); }
    $d = (hrtime(true) - $t) / 1e6;
    if ($d < $bc) { $bc = $d; }

    $t = hrtime(true);
    $s2 = 0; for ($i = 0; $i < $ITERS; $i++) { $s2 += work_ref($tokens); }
    $d = (hrtime(true) - $t) / 1e6;
    if ($d < $br) { $br = $d; }

    if ($s !== $ac || $s2 !== $ar) { echo "MISMATCH between runs\n"; exit(1); }
}

printf("cty %.3f ctype %.3f ratio %.3f\n", $bc, $br, $bc / $br);

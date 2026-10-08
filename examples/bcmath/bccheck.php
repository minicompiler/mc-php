<?php
// The correctness oracle for bcmath_port.so: php's own built-in bcmath. Every
// bc_X answer is compared, byte for byte, with the built-in bcX over a large
// random corpus plus the fixed edge cases that exercise bcmath's quirks --
// permissive parsing, truncation, the per-function scale rules, sign of mod,
// negative/zero powers, powmod, sqrt, comparison at a scale, floor/ceil, round
// (HalfAwayFromZero), and every malformed-argument / divide-by-zero error.
//
//     php -d extension=build/bcmath_port.so bccheck.php
//
// Run with the module loaded; it also runs interpreted (require bcmath.php)
// for development. Prints how many it checked and exits 1 on the first wrong
// answer. The only normalization is the function-name prefix in an exception
// message: the port is bc_add where the built-in is bcadd, so a message's
// leading "bc_add()" / "bcadd()" is stripped before comparing.
declare(strict_types=1);

if (!function_exists('bc_add')) { require __DIR__ . '/bcmath.php'; }
if (!extension_loaded('bcmath')) { echo "no bcmath in this php\n"; exit(2); }

$n = 0;
$bad = 0;

// run a thunk, returning either ['v', value] or ['e', ExceptionClass, message]
function cap(callable $f): array {
    try { return ['v', $f()]; }
    catch (\Throwable $e) { return ['e', get_class($e), $e->getMessage()]; }
}

// strip a leading "name(): " so bc_add()/bcadd() compare equal
function norm(string $msg): string {
    return preg_replace('/^bc_?[a-z]+\(\): /', '(): ', $msg, 1);
}

function check(string $label, callable $port, callable $ref): void {
    global $n, $bad;
    $n++;
    $p = cap($port);
    $r = cap($ref);
    $ok = $p[0] === $r[0];
    if ($ok && $p[0] === 'v') { $ok = $p[1] === $r[1]; }
    if ($ok && $p[0] === 'e') { $ok = $p[1] === $r[1] && norm($p[2]) === norm($r[2]); }
    if (!$ok) {
        $bad++;
        $ps = $p[0] === 'v' ? var_export($p[1], true) : "[$p[1]] $p[2]";
        $rs = $r[0] === 'v' ? var_export($r[1], true) : "[$r[1]] $r[2]";
        echo "WRONG $label\n   port: $ps\n   ref:  $rs\n";
        if ($bad >= 30) { echo "... stopping after 30\n"; exit(1); }
    }
}

// ---- all binary ops over a scale, fixed + random ----------------------------
function bincheck(string $a, string $b, ?int $s): void {
    check("add($a,$b,".var_export($s,true).")", fn()=>bc_add($a,$b,$s), fn()=>bcadd($a,$b,$s));
    check("sub($a,$b,".var_export($s,true).")", fn()=>bc_sub($a,$b,$s), fn()=>bcsub($a,$b,$s));
    check("mul($a,$b,".var_export($s,true).")", fn()=>bc_mul($a,$b,$s), fn()=>bcmul($a,$b,$s));
    check("div($a,$b,".var_export($s,true).")", fn()=>bc_div($a,$b,$s), fn()=>bcdiv($a,$b,$s));
    check("mod($a,$b,".var_export($s,true).")", fn()=>bc_mod($a,$b,$s), fn()=>bcmod($a,$b,$s));
    $sc = $s ?? 0;
    check("comp($a,$b,$sc)", fn()=>bc_comp($a,$b,$sc), fn()=>bccomp($a,$b,$sc));
}

$fixed = [
    ['1','3',10],['2','3',4],['1','8',2],['-1','8',2],['0.125','1',2],['99.995','1',2],
    ['123456789.123456789','-0.000000001',12],['0','0',0],['-0','0',2],['10','3',0],
    ['-10','3',0],['10','-3',0],['-10','-3',0],['10.5','3',2],['1','0.3',4],['8.5','3.1',1],
    ['-8.5','3.1',1],['1.5','0.5',2],['0.1','0.1',0],['1.11','1.11',5],['1.5','1.5',0],
    ['1.10','1.10',3],['123456.78','1093.75',2],['123456.78','0.004375',2],['0','5',3],
    ['250000.00','1.004375',2],['','',0],['.5','.5',3],['5.','3.',0],['12.','0.5',4],
];
foreach ($fixed as [$a,$b,$s]) { bincheck($a,$b,$s); }

// division/modulo by zero
check("div/0", fn()=>bc_div('5','0',2), fn()=>bcdiv('5','0',2));
check("mod/0", fn()=>bc_mod('5','0',2), fn()=>bcmod('5','0',2));
check("div/0.0", fn()=>bc_div('5','0.0',2), fn()=>bcdiv('5','0.0',2));

// malformed numbers (both args, and scale)
foreach ([' 5','5 ','1e3','5,0','5.0.0','abc','+-5',"\t5",'0x1','1.2.3'] as $m) {
    check("add bad1 ".var_export($m,true), fn()=>bc_add($m,'1',0), fn()=>bcadd($m,'1',0));
    check("add bad2 ".var_export($m,true), fn()=>bc_add('1',$m,0), fn()=>bcadd('1',$m,0));
}
foreach ([-1, -5, 2147483648] as $bs) {
    check("add scale $bs", fn()=>bc_add('1','1',$bs), fn()=>bcadd('1','1',$bs));
}

// ---- pow / powmod / sqrt ----------------------------------------------------
foreach ([['2','10',0],['1.1','2',1],['1.1','2',5],['2','-2',4],['3','-3',10],['0','0',2],
          ['5','0',3],['0','-1',2],['0','5',2],['-2','3',0],['-2','2',0],['2','2.5',0],
          ['2','2.0',0],['1.5','-2',6],['7','5',3],['1.25','3',4],['10','-1',5],['-3','5',2],
          ['2','0',0],['123','0',4]] as [$a,$e,$s]) {
    check("pow($a,$e,$s)", fn()=>bc_pow($a,$e,$s), fn()=>bcpow($a,$e,$s));
}
foreach ([['2','10','1000',0],['2','10','1000',2],['3','100','7',0],['5','0','7',0],
          ['2','10','1',0],['2.5','10','7',0],['2','-1','7',0],['2','10','0',0],
          ['-3','3','7',0],['7','256','13',0],['10','20','17',0],['123','45','1000000',0]] as [$a,$e,$mo,$s]) {
    check("powmod($a,$e,$mo,$s)", fn()=>bc_powmod($a,$e,$mo,$s), fn()=>bcpowmod($a,$e,$mo,$s));
}
foreach ([['2',10],['0',5],['1',5],['152.2756',4],['2',0],['0.25',5],['9',0],['10',0],
          ['-1',2],['1000000',4],['2',1],['99999999999999999999',0],['15241578750190521',0],
          ['0.0001',8],['1234.5678',6]] as [$a,$s]) {
    check("sqrt($a,$s)", fn()=>bc_sqrt($a,$s), fn()=>bcsqrt($a,$s));
}

// ---- floor / ceil / round ---------------------------------------------------
foreach (['4.3','-4.3','4.0','-4.0','4','0','-0','0.001','-0.001','4.9','-4.9','-0.5','123.0001','-123.0001'] as $a) {
    check("floor($a)", fn()=>bc_floor($a), fn()=>bcfloor($a));
    check("ceil($a)", fn()=>bc_ceil($a), fn()=>bcceil($a));
}
foreach ([['2.5',0],['3.5',0],['-2.5',0],['1.95583',2],['1241757',-3],['0.125',2],['0.135',2],
          ['9.995',2],['-0.5',0],['1234',-2],['5',-1],['45',-1],['0.4',0],['0.5',0],['99.9',0],
          ['0',2],['1.0',0],['12.',0],['0.001',-1],['0.5',-1],['4','-1'],['1.449',2],['1.45',1],
          ['-1.45',1],['999.99',1],['0.00049',3]] as [$a,$p]) {
    $p = (int)$p;
    check("round($a,$p)", fn()=>bc_round($a,$p), fn()=>bcround($a,$p));
}

// ---- random corpus ----------------------------------------------------------
mt_srand(20261007);
function rnd(): string {
    if (mt_rand(0, 9) === 0) { return (mt_rand(0, 1) ? '-' : '') . '0'; }
    $s = mt_rand(0, 3) === 0 ? '-' : '';
    $il = mt_rand(0, 20);
    for ($i = 0; $i < $il; $i++) { $s .= (string) mt_rand(0, 9); }
    if ($il === 0) { $s .= (string) mt_rand(1, 9); }
    $fl = mt_rand(0, 12);
    if ($fl > 0) { $s .= '.'; for ($i = 0; $i < $fl; $i++) { $s .= (string) mt_rand(0, 9); } }
    return $s;
}
for ($k = 0; $k < 600; $k++) {
    $a = rnd(); $b = rnd(); $s = mt_rand(0, 16);
    bincheck($a, $b, $s);
    bincheck($a, $b, null);        // the default scale (0 here)
    check("round($a,".($s-8).")", fn()=>bc_round($a,$s-8), fn()=>bcround($a,$s-8));
    check("floor($a)", fn()=>bc_floor($a), fn()=>bcfloor($a));
    check("ceil($a)", fn()=>bc_ceil($a), fn()=>bcceil($a));
    check("sqrt(|$a|,$s)", fn()=>bc_sqrt(ltrim($a,'-'),$s), fn()=>bcsqrt(ltrim($a,'-'),$s));
    // integer power with small exponent
    $e = (string) mt_rand(-6, 8);
    check("pow($a,$e,$s)", fn()=>bc_pow($a,$e,$s), fn()=>bcpow($a,$e,$s));
}

// ---- bcscale default path ---------------------------------------------------
check("scale() start", fn()=>bc_scale(), fn()=>bcscale());
bc_scale(5); bcscale(5);
check("add null scale @5", fn()=>bc_add('1','3',null), fn()=>bcadd('1','3',null));
check("div null scale @5", fn()=>bc_div('1','3',null), fn()=>bcdiv('1','3',null));
check("scale() after", fn()=>bc_scale(), fn()=>bcscale());
bc_scale(0); bcscale(0);

if ($bad === 0) { echo "bcmath agrees: $n results, 0 wrong\n"; }
else { echo "$bad of $n wrong\n"; exit(1); }

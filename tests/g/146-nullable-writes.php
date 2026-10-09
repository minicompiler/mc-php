<?php
// A native `?int $x` (src/decl.mc) is two locals: the value and a u8 null
// flag. Two things the review of #65 found, both of them silent wrong
// answers before ph_opt_scan:
//
//   * a WRITE left the flag as the call set it, so after `$x = 1` a null
//     argument still read `=== null` true and was passed on as null;
//   * a READ that does not consult the flag saw null as int 0 -- a copy into
//     another variable, a comparison, `=== 0`, a `= 5` default that "not
//     passed" turned into null.
//
// The nat_* functions are the shapes the scan proves (their parameter stays
// the native pair -- tests/fixtures.sh reads the lowering back); every zv_*
// function has a use the scan cannot prove and keeps php's zval.
declare(strict_types=1);

function show(?int $y): string { return $y === null ? "null" : "int($y)"; }

// ---- writes on the native pair ----------------------------------------------
function nat_assign(?int $x): string { $x = 1; return ($x === null ? "N" : "V") . show($x); }
function nat_fill(?int $x): string { if ($x === null) { $x = 2; } return show($x) . ($x * 10); }
function nat_isset(?int $x): string { $x = 3; return isset($x) ? "S" : "U"; }
function nat_guard(?int $x): string {
    if ($x === null) { return "dflt"; }
    $x += 5;
    $x++;
    return show($x) . ($x < 0 ? "-" : "+");
}
function nat_inner(?int $x): string {
    if ($x !== null) { $x = $x * 2; --$x; }
    return show($x);
}

// ---- uses the scan cannot prove: the zval road ------------------------------
function zv_copy(?int $x): string { $y = $x; return show($y); }
function zv_cmp(?int $x): string { return ($x < -1 ? "lt" : "ge") . ($x === 0 ? "Z" : "n"); }
function zv_dflt(?int $x = 5): string { return show($x); }
function zv_compound(?int $x): string { $x += 2; return show($x); }
function zv_inc(?int $x): string { $x++; return show($x); }
function zv_pre(?int $x): string { $y = ++$x; return show($x) . show($y); }

foreach ([null, 4, -5, 0] as $v) {
    echo show($v), ": ",
        nat_assign($v), " ", nat_fill($v), " ", nat_isset($v), " ",
        nat_guard($v), " ", nat_inner($v), " | ",
        zv_copy($v), " ", zv_cmp($v), " ", zv_dflt($v), " ",
        zv_compound($v), " ", zv_inc($v), " ", zv_pre($v), "\n";
}
echo zv_dflt(), "\n";

<?php
// A function `static` that only ever holds an int is a native slot of the
// generated `phsi` (src/decl.mc ph_nst_scan), read and written in place: no
// zval, no call. The nst_* functions are the shapes the scan proves -- each
// must keep php's own semantics, recursion through the static included, and
// tests/fixtures.sh reads back that they use the slot; every zst_* one has a
// use the scan cannot prove and keeps the zval static.
declare(strict_types=1);

function nst_count(): int { static $n = 0; $n++; return $n; }
function nst_pre(): int { static $n = 10; --$n; return $n * 2; }
function nst_swap(int $v): int { static $t = 5; $t += 3; $o = $t; $t = $v; return $o; }
function nst_rec(int $d): int { static $c = 0; ++$c; if ($d > 0) { return nst_rec($d - 1); } return $c; }
function nst_read(): string { static $k = 7; $k *= 2; return "k=$k " . ($k > 20 ? "big" : "small"); }

function zst_str(): string { static $z = 0; $z = $z . "a"; return $z; }
function zst_closure(): int { static $k = 3; $f = fn() => $k; return $f(); }
function zst_neg(): int { static $m = -1; $m++; return $m; }
function zst_expr(int $v): int { static $e = 0; $e = $v * 2; return $e; }
function zst_arg(): int { static $q = 4; return intdiv($q, 2); }
function zst_two(): int { static $a = 1, $b = 2; $a++; $b += 10; return $a + $b; }
function &zst_ref() { static $r = 5; return $r; }
function zst_each(): int { static $e = 0; foreach ([3, 4] as $e) {} return $e; }
function zst_catch(): int { static $c = 0; try { $c++; } catch (Exception $c) {} return $c; }

$rr = &zst_ref();
$rr = 9;
echo zst_ref(), " ", zst_each(), " ", zst_catch(), zst_catch(), "\n";
for ($i = 0; $i < 3; $i++) {
    echo nst_count(), " ", nst_pre(), " ", nst_swap($i * 100), " ", nst_rec(2), " ",
        nst_read(), " ", zst_two(), " | ",
        zst_str(), " ", zst_closure(), " ", zst_neg(), " ", zst_expr($i), " ", zst_arg(), "\n";
}

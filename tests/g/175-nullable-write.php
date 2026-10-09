<?php
// A write to a `?int` parameter the compiler carries natively (a value and a
// null flag, src/decl.mc). The proof used to admit every assignment, so
// `$x = null` made the native int "assigned mixed" and the function no longer
// compiled; `$x = $o` copied the value and dropped $o's null; and a null
// written inside a region an `if ($x === null) return` had proved non-null
// left later reads of that region believing it. Each function below stays
// native (null, another ?int, a `: ?int` call, an int expression) or falls
// back to php's zval (a string, a nullable write a proved read depends on) --
// and every answer is php's.
declare(strict_types=1);

function g(?int $v): ?int { return $v; }
function k(): int { return 3; }

function setnull(?int $x): string {
    if ($x === null) { return "n"; }
    $x = null;
    return $x === null ? "null" : "int";
}
function pair(?int $x, ?int $o): string {
    $x = $o;
    if ($x === null) { return "null"; }
    return (string)$x;
}
function call(?int $x, ?int $o): string {
    $x = g($o);
    if ($x === null) { return "null"; }
    return (string)$x;
}
function intparam(?int $x, int $n): string {
    $x = $n;
    return (string)($x ?? -1);
}
function fill(?int $x, int $n): string {
    if ($x === null) { $x = $n * 2 + k(); }
    return (string)($x + 1);
}
function inblock(?int $x): string {
    if ($x !== null) { $x = null; return $x === null ? "nul" : "int"; }
    return "z";
}
function tostr(?int $x): string { $x = "s"; return gettype($x); }
// a nullable fill is not a proof: the read below must see php's null
function nullfill(?int $x): string {
    if ($x === null) { $x = g(null); }
    return ($x === 0) ? "zero" : "nz";
}
// the region runs again after the null is written
function loopwrite(?int $x, int $n): string {
    if ($x === null) { return "-"; }
    $s = "";
    for ($i = 0; $i < $n; $i++) {
        $s .= ($x === 0) ? "zero " : "nz ";
        $x = null;
    }
    return $s;
}
function blockwrite(?int $x): string {
    if ($x !== null) { $x = null; return ($x === 0) ? "zero" : "nz"; }
    return "-";
}

echo setnull(1), " ", setnull(null), "\n";
echo pair(1, null), " ", pair(null, 7), " ", pair(3, 4), "\n";
echo call(1, null), " ", call(null, 7), "\n";
echo intparam(null, 5), " ", intparam(2, 6), "\n";
echo fill(null, 4), " ", fill(9, 4), "\n";
echo inblock(5), " ", inblock(null), "\n";
echo tostr(null), " ", tostr(1), "\n";
echo nullfill(null), " ", nullfill(0), "\n";
echo loopwrite(0, 3), "|", loopwrite(null, 2), "\n";
echo blockwrite(0), " ", blockwrite(null), "\n";

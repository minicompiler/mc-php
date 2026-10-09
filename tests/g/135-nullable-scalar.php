<?php
// A nullable/optional scalar parameter (`?int $s = null`) is carried as a
// native value plus a null flag (src/decl.mc), not a heap zval. This exercises
// every shape the lowering must get right, byte for byte against php: the
// omitted default, an explicit null, a passed value, a negative value, a
// nullable variable passed on to another nullable parameter (the chain
// bcmath's bc_add -> _bc_scaleof is), and the `=== null` / `!== null` reads.
declare(strict_types=1);

function scaleof(?int $s): int {
    if ($s === null) { return 7; }           // the default
    if ($s < 0) { return -1; }
    return $s * 2;
}

function pub(int $a, ?int $s = null): int {   // $s omitted or null -> the default
    return $a + scaleof($s);
}

// omitted, explicit null, a value, a negative, zero
echo pub(10), "\n";            // 10 + 7  = 17
echo pub(10, null), "\n";      // 10 + 7  = 17
echo pub(10, 3), "\n";         // 10 + 6  = 16
echo pub(10, -5), "\n";        // 10 + -1 = 9
echo pub(10, 0), "\n";         // 10 + 0  = 10

// a nullable variable flowing through the chain
$v = null;
echo pub(100, $v), "\n";       // 100 + 7 = 107
$v = 4;
echo pub(100, $v), "\n";       // 100 + 8 = 108

// the comparison both ways, as a boolean
function tells(?int $s): string {
    $w = $s === null ? 'nil' : 'val';
    $x = $s !== null ? 'val' : 'nil';
    return "$w$x";
}
echo tells(null), "\n";        // nilnil
echo tells(5), "\n";           // valval
echo tells(0), "\n";           // valval   (0 is a value, not null)

// a bare nullable (no default) is required: passed a value and null
function req(?int $s): int { return $s ?? 99; }
echo req(42), "\n";            // 42
echo req(null), "\n";          // 99

// the remaining null-sensitive forms
function forms(?int $s): string {
    $a = is_null($s) ? 'Y' : 'N';
    $b = isset($s) ? 'Y' : 'N';
    $c = empty($s) ? 'Y' : 'N';
    $d = (string) $s;
    $e = "[$s]";
    $f = $s == null ? 'Y' : 'N';     // loose
    return "$a$b$c|$d|$e|$f";
}
echo forms(null), "\n";   // is_null Y, isset N, empty Y, (string)"", "[]", ==null Y
echo forms(0), "\n";      // is_null N, isset Y, empty Y, "0", "[0]", ==null Y (0==null)
echo forms(5), "\n";      // is_null N, isset Y, empty N, "5", "[5]", ==null N

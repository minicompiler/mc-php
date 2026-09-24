<?php
// An elseif whose condition needs statements of its own -- a string
// comparison, a call -- was DROPPED: ph_wrap hands the next if back as a
// statement list, the else branch of an if is one node, and the list's tail
// (the if itself) never ran. Found by examples/decimal, where
// `elseif ($c >= '0' && $c <= '9')` made every number "not a decimal".
function kind(string $c): string {
    if ($c === '.') {
        return 'dot';
    } elseif ($c >= '0' && $c <= '9') {
        return 'digit';
    } elseif (strlen($c) > 1) {
        return 'long';
    } else {
        return 'other';
    }
}
foreach (['.', '7', 'ab', 'x'] as $c) { echo $c, " ", kind($c), "\n"; }

$s = "b";
if ($s === "a") { echo "a\n"; } else if ($s === "b") { echo "b\n"; } else { echo "?\n"; }
if ($s === "z"): echo "z\n"; elseif (str_contains($s, "b")): echo "has b\n"; endif;
$n = 0;
foreach (["x", "y", "x"] as $v) { if ($v === "y") { $n += 10; } elseif ($v === "x") { $n++; } }
echo $n, "\n";

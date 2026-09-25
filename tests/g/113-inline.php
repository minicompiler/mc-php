<?php
// Small functions are copied into their callers (src/opt.mc): every shape a
// copy has to keep -- an early return nested under an if whose other branch
// goes on, a return in both branches, a parameter the callee assigns, the
// arguments' order, a throw inside the copy caught by the caller, a warning
// raised inside the copy and one raised after it on the caller's line, a copy
// on the right of && (which must not run early), a void function, a string
// answered from a parameter or a temporary inside a loop, a copy of a copy,
// and recursion (never copied). The warning on the last line is raised after
// a copy that moved the position, and names the caller's line.
function sgn(int $x): int {
    if ($x > 0) { if ($x > 100) { return 2; } $x = $x * 1; }
    if ($x < 0) { return -1; }
    return $x > 0 ? 1 : 0;
}
function both(int $x): string { if ($x % 2) { return "odd"; } else { return "even"; } }
function bump(int $x): int { $x = $x + 1; return $x * 2; }
$trace = "";
function note(string $s): int { global $trace; $trace .= $s; return strlen($s); }
function two(int $a, int $b): int { return $a * 10 + $b; }
function chk(int $v): int { if ($v < 0) { throw new InvalidArgumentException("neg $v"); } return $v; }
function off(string $s): string { return $s[5]; }
function same(string $s): string { return $s; }
function head(string $s): string { return substr($s, 0, 2) . "!"; }
function twice(string $s): string { return head($s) . head($s); }
function fact(int $n): int { if ($n <= 1) { return 1; } return $n * fact($n - 1); }
function side(): void { global $trace; $trace .= "v"; }
function nonzero(int $x): bool { note("n"); return $x !== 0; }

function run(): void {
    global $trace;
    echo sgn(5), sgn(500), sgn(-3), sgn(0), " ", both(3), both(4), " ", bump(4), "\n";
    echo two(note("ab"), note("c")), " ", $trace, "\n";
    try { echo chk(2), chk(-7), "never\n"; } catch (InvalidArgumentException $e) { echo get_class($e), ": ", $e->getMessage(), "\n"; }
    echo "[", off("abc"), "]\n";
    $x = off("abc") . strlen("x") . (1 / 1);
    $acc = "";
    for ($i = 0; $i < 4; $i++) { $acc .= same("s$i") . twice("xyz$i"); }
    echo $acc, " ", fact(6), "\n";
    side(); side();
    $z = 0;
    if ($z !== 0 && nonzero($z)) { echo "no\n"; }
    echo $trace, " ", nonzero(3) ? "t" : "f", " ", $trace, "\n";
    $y = off("abcdefg") . $undefined;
    echo $y, "\n";
}
run();

<?php
// A `for` whose INITIALIZER throws must not run the condition or the body.
//
// The initializer is lowered with ph_stmt(), which prepends a position and
// appends no check -- so what stops the body is ph_cond_checked, and it fires
// because ph_stmt() restores `raises | save`: the initializer's mark reaches
// the condition, the condition becomes a temporary, and the check goes between
// computing it and branching on it, inside the loop head and before the body.
// A `for` with no condition at all is the one shape that would skip it, and it
// is refused outright ("expected ; in for"), so it cannot reach here.
declare(strict_types=1);

function boom(string $where): int { echo "boom($where) ran\n"; throw new RuntimeException($where); }

// 1. the plain case
try {
    for ($i = boom("init"); $i < 3; $i = $i + 1) { echo "BODY\n"; }
    echo "AFTER\n";
} catch (RuntimeException $e) { echo "caught ", $e->getMessage(), " @", $e->getLine(), "\n"; }

// 2. the condition throws instead, on the first evaluation
try {
    for ($j = 0; boom("cond") < 3; $j = $j + 1) { echo "BODY\n"; }
} catch (RuntimeException $e) { echo "caught ", $e->getMessage(), "\n"; }

// 3. the condition throws on a LATER evaluation, so the loop has run
$n = 0;
try {
    for ($k = 0; ($n = $n + 1) < 3 ? true : boom("late"); $k = $k + 1) { echo "body $k\n"; }
} catch (RuntimeException $e) { echo "caught ", $e->getMessage(), "\n"; }

// 4. the step throws
try {
    for ($m = 0; $m < 3; $m = boom("step")) { echo "body $m\n"; }
} catch (RuntimeException $e) { echo "caught ", $e->getMessage(), "\n"; }

// 5. the initializer throws and the loop carries a `finally` around it
function withFinally(): string {
    try {
        for ($p = boom("in-finally"); $p < 3; $p = $p + 1) { return "BODY"; }
        return "AFTER";
    } catch (RuntimeException $e) { return "caught " . $e->getMessage(); }
    finally { echo "finally ran\n"; }
}
echo withFinally(), "\n";

// 6. the same, in a while whose condition throws
try {
    while (boom("while") < 3) { echo "BODY\n"; }
} catch (RuntimeException $e) { echo "caught ", $e->getMessage(), "\n"; }

// 7. and a do/while, whose condition is evaluated after the body
$q = 0;
try {
    do { $q = $q + 1; echo "do body $q\n"; } while (boom("do") < 3);
} catch (RuntimeException $e) { echo "caught ", $e->getMessage(), "\n"; }

echo "done\n";

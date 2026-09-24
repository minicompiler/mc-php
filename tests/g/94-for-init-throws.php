<?php
// A `for` whose INITIALIZER throws must not run the condition or the body,
// and the same for each of its other two parts.
//
// Each part is checked on its own mark (src/lvalue.mc, the `for` lowering):
// the initializer gets an explicit check right after it, the condition gets
// ph_cond_checked's (between computing it and branching on it), and the step
// gets one right after it, wrapped in a block. None relies on another, so an
// empty condition -- `for (;;)`, or `for ($i = f();; ...)`, whose condition
// is ph_bool(1) -- still stops the body when the initializer throws (case 8).
// Case 9 is the parse this file also found: after a non-empty initializer the
// empty condition's `;` used to be consumed as the initializer's own, and
// `for ($i = 0;; $i = $i + 1)` was refused with "expected ; in for".

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

// 8. the initializer throws and the condition is EMPTY: nothing but the
//    initializer's own check stands between it and the body
try {
    for ($q = boom("init-nocond");; $q = $q + 1) { echo "BODY\n"; break; }
} catch (RuntimeException $e) { echo "caught ", $e->getMessage(), "\n"; }

// 9. an initializer, an empty condition and a step; and the fully empty form
for ($r = 0;; $r = $r + 1) { echo "r $r\n"; if ($r > 1) break; }
for (;;) { echo "forever once\n"; break; }

// 10. the step throws with the condition empty
try {
    for ($s = 0;; $s = boom("step-nocond")) { echo "body $s\n"; }
} catch (RuntimeException $e) { echo "caught ", $e->getMessage(), "\n"; }

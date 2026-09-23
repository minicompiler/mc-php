<?php
// A `return` whose EXPRESSION can throw has two things to do in order: check
// the exception, and then leave the function -- and leaving is not always a
// `return`. Inside a try with a finally beside it, leaving is the flag and
// the break the try's own loop reads, so a direct return there jumps over
// the finally php promises to run.
function g(): int { return 7; }
function boom(): int { throw new RuntimeException("x"); }

function f(): int { try { return g(); } finally { echo "fin f\n"; } }
echo f(), "\n";

function h(): int { try { return boom(); } finally { echo "fin h\n"; } }
try { echo h(), "\n"; } catch (\Throwable $e) { echo "caught ", $e->getMessage(), "\n"; }

// the finally runs on the way out of BOTH edges, and the catch beside it
// still sees the exception the return expression raised
function k(int $n): int {
    try {
        if ($n > 0) { return g(); }
        return boom();
    } catch (RuntimeException $e) {
        echo "catch k\n";
        return -1;
    } finally {
        echo "fin k\n";
    }
}
echo k(1), "\n";
echo k(0), "\n";

// nested: the inner finally first, then the outer
function n2(): int {
    try {
        try { return g(); } finally { echo "inner\n"; }
    } finally { echo "outer\n"; }
}
echo n2(), "\n";

// a plain value in a try still runs the finally (this path never regressed)
function p(): int { try { return 5; } finally { echo "fin p\n"; } }
echo p(), "\n";
echo "end\n";

<?php
// A strict comparison whose answer the static types already know -- an int is
// never null, an int is never identical to a float or a bool -- was folded to
// a constant WITHOUT evaluating the operand (review of #65, src/expr.mc). The
// call did not run, its output did not appear, and its exception vanished.
// ph_pure: the fold is kept for a variable or a literal (the pure_* function,
// which tests/fixtures.sh reads back as call-free) and anything else is
// evaluated.
declare(strict_types=1);

$calls = 0;
function side(): int { global $calls; $calls++; echo "side\n"; return 7; }
function fl(): float { echo "fl\n"; return 1.5; }
function boom(): int { throw new RuntimeException("boom"); }

var_dump(side() === null);
var_dump(null !== side());
var_dump(side() === true);
var_dump(side() !== 7.0);
var_dump(fl() === 1);
echo $calls, "\n";
try {
    var_dump(boom() === null);
    echo "not reached\n";
} catch (RuntimeException $e) {
    echo "caught ", $e->getMessage(), "\n";
}
// short-circuit: the right side runs only when the left does not decide
var_dump(false && side() === null);
var_dump(true || side() === null);
echo $calls, "\n";

function pure_cmp(int $i, float $f): string {
    return ($i === null ? "a" : "b") . ($i === 3.0 ? "c" : "d") . ($f === 1 ? "e" : "f");
}
echo pure_cmp(3, 1.0), "\n";

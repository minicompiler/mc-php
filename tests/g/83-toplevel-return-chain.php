<?php
// A top-level `return` EVALUATES its expression, and an expression with
// pending statements of its own -- a short circuit, a ternary -- carries
// them in a chain whose head is not the expression statement.
function f() { echo "f\n"; return 1; }
function g() { echo "g\n"; return 2; }
function h() { echo "h\n"; return 0; }
echo "before\n";
$x = 0;
return f() && g() && ($x = 3) && h() && g();

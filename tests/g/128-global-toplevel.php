<?php
// A top-level variable that only a function's `global` creates is THE global:
// the top level reads what the function wrote. mc-php read it as an undefined
// variable (a warning and null) when nothing at the top level assigned it.
function set(int $v): void { global $g; $g = $v; }
function seta(): void { global $arr; $arr = [1, 2, 3]; }
function add(): void { global $count; $count = $count + 5; }
function get(): int { global $g; return $g; }
function late(): void { global $h; $h = "late"; }

// read before any `global` ran: php's warning, and `??` without one
echo "before: [", $g ?? "default", "]\n";
echo "early: [", $h, "]\n";

set(42);
echo "read: ", $g, "\n";
echo "interpolated: $g and {$g}\n";
seta();
echo "array: ", count($arr), " ", $arr[1], "\n";

// a top-level write through the name reaches the function's global
$g++;
echo "after ++: ", get(), "\n";
$count++;
add();
echo "count: ", $count, "\n";

// in a loop: each read asks the table, so it sees the latest write
for ($i = 0; $i < 3; $i++) {
    set($i * 10);
    echo "loop $i: ", $g, "\n";
}
late();
echo "late: ", $h, "\n";
$u = $never ?? "none";
echo "never set: ", $u, "\n";

// a closure's `global` names the same table
$c = function (): void { global $viac; $viac = "from a closure"; };
$c();
echo "closure: ", $viac, "\n";

<?php
// php's top-level scope IS the global table. A top-level name some function
// declares `global` is that table's entry for the whole top level -- bound
// once, before the first statement (tests/fixtures.sh reads the binding back
// out of --dump-ast) -- and an entry no one assigned does not exist: a read
// warns, isset is false, ?? is quiet, unset() puts it back.
function set(int $v): void { global $g; $g = $v; }
function seta(): void { global $arr; $arr = [1, 2, 3]; }
function add(): void { global $count; $count = $count + 5; }
function get(): int { global $g; return $g; }
function late(): void { global $h; $h = "late"; }
function show(string $w): void { global $g; echo $w, ": "; var_dump($g); }
function showa(): void { global $app, $keyed; var_dump($app, $keyed); }
function useset(): void { global $u; $u = 42; }
function cnt(): int { global $n; return $n; }

// read before any `global` ran: php's warning, and `??`/isset without one
echo "before: [", $g ?? "default", "] ", isset($g) ? "set" : "unset", "\n";
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

// unset() at the top level removes the GLOBAL: the function's `global`
// finds it gone and makes it null
set(5);
unset($g);
echo "after unset: ", isset($g) ? "set" : "unset", " ", $g ?? "gone", "\n";
show("function after unset");

// the first write through [] or a key makes the global's array
$app[] = 1;
$app[] = 2;
$keyed[0] = "zero";
$keyed["k"] = "kay";
showa();

// a closure's `use` captures the global's value
useset();
$f = function () use ($u) { return $u; };
echo "use: ", $f(), "\n";

// in a loop: the binding is made once, before the loop; each read sees the
// latest write, from the top level or from a function
for ($i = 0; $i < 3; $i++) {
    set($i * 10);
    echo "loop $i: ", $g, "\n";
    $n = ($n ?? 0) + 1;
}
echo "n: ", cnt(), "\n";
late();
echo "late: ", $h, "\n";
$v = $never ?? "none";
echo "never set: ", $v, "\n";

// a closure's `global` names the same table
$c = function (): void { global $viac; $viac = "from a closure"; };
$c();
echo "closure: ", $viac, "\n";

<?php
// unset() removes a BINDING, not the value: at the top level the global's
// entry becomes a new undefined one and a reference still holds the old
// value; in a function only the local name goes, the global stays. mc-php
// cleared the shared value in place, so a live reference saw NULL.
function setg(int $v): void { global $g; $g = $v; }
function readg(string $w): void { global $g; echo $w, ": "; var_dump($g); }
function fn_unset(): void { global $g; unset($g); echo "in function after unset: ", isset($g) ? "set" : "unset", "\n"; }
function doubles(): void { global $list; foreach ($list as &$x) { $x = $x * 2; } unset($x); }
function show_list(): void { global $list; echo implode(",", $list), "\n"; }
setg(5);
$r = &$g;
unset($g);
var_dump($r);
echo "top after unset: ", isset($g) ? "set" : "unset", "\n";
readg("function after top unset");
$r = 7;
readg("the reference does not reach the new entry");
setg(9);
fn_unset();
readg("function unset keeps the global");
echo "top sees: ", $g, "\n";
$list = [1, 2, 3];
foreach ($list as &$item) { $item = $item + 10; }
unset($item);
show_list();
doubles();
show_list();
foreach ($list as $k => &$w) { if ($k == 0) { $w = 100; } }
echo $list[0], " ", $w, "\n";
unset($w);
echo implode(",", $list), "\n";

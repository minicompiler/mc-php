<?php
function counter(): int { static $n = 0; $n++; return $n; }
echo counter(), counter(), counter(), "\n";
$g = 10;
function useg(): int { global $g; $g = $g + 1; return $g; }
echo useg(), " ", useg(), "\n";
$a = 1; $b = &$a; $b = 7; echo $a, " ", $b, "\n";
$arr = [1,2,3];
foreach ($arr as &$v) { $v = $v * 10; }
unset($v);
print_r($arr);

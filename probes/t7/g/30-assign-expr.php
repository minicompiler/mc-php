<?php
// php's assignment IS an expression; `if (!($fp = f()))` is all over the corpus
function f() { return 7; }
if (!($x = f())) { echo "falsy\n"; } else { echo "got $x\n"; }
$a = $b = 3;
echo "$a $b\n";
$n = 0;
while (($n = $n + 1) < 4) { echo "n=$n\n"; }
$s = ($t = "hi") . "!";
echo "$s $t\n";
echo (($q = 5) + 1), " $q\n";
$i = 0;
while (($c = $i * 2) < 6) { echo "c=$c\n"; $i = $i + 1; }
for ($j = 0; ($k = $j) < 3; $j = $j + 1) { echo "k=$k\n"; }
echo "end\n";

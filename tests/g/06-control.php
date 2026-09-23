<?php
$i = 0;
while ($i < 3) { echo $i; $i++; }
echo "\n";
for ($j = 0; $j < 3; $j++) { echo $j; }
echo "\n";
$k = 0;
do { $k += 2; } while ($k < 5);
echo $k, "\n";
if ($k > 5) { echo "gt\n"; } elseif ($k == 5) { echo "eq\n"; } else { echo "lt\n"; }
for ($m = 0; $m < 5; $m++) { if ($m == 2) { continue; } if ($m == 4) { break; } echo $m; }
echo "\n";

<?php
$n = 0;
if ($n == 0) { echo "zero\n"; } else { echo "nonzero\n"; }
$i = 0;
while ($i < 3) { echo $i; $i = $i + 1; }
echo "\n";
for ($j = 0; $j < 3; $j += 1) { echo $j; }
echo "\n";
foreach ([10, 20, 30] as $v) { echo $v; echo ","; }
echo "\n";

<?php
$n = "world";
$a = <<<EOT
hello $n
  indented
EOT;
echo $a, "|\n";
$b = <<<'RAW'
no $n here \n
RAW;
echo $b, "|\n";
$c = <<<"DQ"
    x=$n
    y
    DQ;
echo $c, "|\n";

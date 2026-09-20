<?php
// int / int is int|float in php: a union, so a zval (D4 (c)) -- T5 refused it
echo 7 / 2, " ", 10 / 2, " ", intdiv(7, 2), "\n";
var_dump(7/2, 10/2);

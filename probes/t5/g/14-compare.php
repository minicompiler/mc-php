<?php
var_dump(1 < 2, 2 <= 2, 3 > 4, "a" == "a", "a" === "b", 1 != 2);
var_dump(1 <=> 2, "b" <=> "a");
var_dump(true && false, true || false, !true);
$s = "";
var_dump((bool) $s, (bool) "0", (bool) "x", (bool) 0, (bool) 1.5);

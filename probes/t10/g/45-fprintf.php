<?php
$f = fopen("php://stdout", "w");
fprintf($f, "%s-%d\n", "a", 5);
vfprintf($f, "%s|%s\n", ["x","y"]);

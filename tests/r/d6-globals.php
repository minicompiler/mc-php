<?php
// $GLOBALS, php's global table as an array: refused by name (D6) until it is
// built -- the top level reaches the table through its own variables
$a = 1;
function f(): int { return $GLOBALS["a"]; }
echo f(), "\n";

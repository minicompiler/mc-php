<?php
// `require __DIR__ . "/x.php"` is php-src's own spelling and the path is
// known at COMPILE time, so D1's "an include of a computed path" does not
// describe it. It was refused, and that is why D8's mc-php half -- every
// bench/run.php and bench/main.php opens with one -- had never run.
require __DIR__ . "/inc.php";
require_once __DIR__ . '/inc.php';
include_once __DIR__ . "/inc.php";
echo inc_answer(), "\n";
echo basename(__DIR__), "\n";

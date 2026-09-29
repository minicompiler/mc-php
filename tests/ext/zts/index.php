<?php
// The script FrankenPHP runs for each request (tests/frankenphp.sh): a
// function the module calls through php's function table, then one call, and
// what the module echoes, caught by an output buffer this script opened.
function zts_helper(int $x): int { return $x + 1000; }
$n = (int) ($_GET['n'] ?? 0);
ob_start();
zts_say($n);
$said = ob_get_clean();
echo work($n), $said, "\n";

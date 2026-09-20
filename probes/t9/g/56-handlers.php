<?php
set_error_handler(function($no, $str, $file, $line) { echo "H[$no]: $str\n"; return true; });
echo $undefined;
trigger_error("boom", E_USER_WARNING);
restore_error_handler();
echo $undefined2;
echo "done\n";
set_exception_handler(function($e) { echo "X: ", get_class($e), " ", $e->getMessage(), "\n"; });
echo "before\n";
throw new RuntimeException("oops");

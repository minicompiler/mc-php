<?php
// php EVALUATES a top-level return's expression and then ends the script,
// so `return f();` still calls f() -- and one that THROWS inside a try does
// not end anything, because the return never happened. mc-php parsed the
// expression and threw the node away.
function f() { echo "side\n"; return 9; }
function t() { throw new Exception("x"); }
echo "a\n";
try { return t(); } catch (Exception $e) { echo "caught\n"; } finally { echo "fin\n"; }
echo "after\n";
register_shutdown_function(function () { echo "shutdown\n"; });
return f();

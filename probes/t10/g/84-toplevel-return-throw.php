<?php
// The unwinding check goes at the END of that chain: attached to its head
// it took the rest of the chain with it and the catch never ran.
function f() { echo "f\n"; return 1; }
function boom() { throw new Exception("b"); }
try { return f() && boom(); } catch (Exception $e) { echo "caught ", $e->getMessage(), "\n"; }
echo "after\n";
try { return f() ? boom() : 0; } catch (Exception $e) { echo "caught2\n"; }
echo "end\n";

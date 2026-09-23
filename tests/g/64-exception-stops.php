<?php
// a pending exception stops the statement it is in: neither arm of an `if`
// whose CONDITION threw may run, and a prologue that raised must not fall
// into the body
function t() { throw new Exception("boom"); }
try { if (t()) { echo "then\n"; } else { echo "else\n"; } } catch (Exception $e) { echo "c1\n"; }
try { while (t()) { echo "w\n"; } } catch (Exception $e) { echo "c2\n"; }
try { for ($i = 0; t(); $i++) { echo "f\n"; } } catch (Exception $e) { echo "c3\n"; }
try { do { echo "d\n"; } while (t()); } catch (Exception $e) { echo "c4\n"; }
function need($a, $b) { echo "body\n"; return 1; }
try { need(1); } catch (ArgumentCountError $e) { echo "c5\n"; }
class C { function m($a, $b) { echo "mbody\n"; return 1; } }
try { (new C)->m(1); } catch (ArgumentCountError $e) { echo "c6\n"; }
// and an ordinary condition still runs its branch
$n = 0;
while ($n < 3) { $n++; }
echo $n, "\n";

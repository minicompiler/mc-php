<?php
// The spread flag belongs to ONE call. It used to be restored from the
// enclosing value when a call had no spread, which made it sticky: after
// any `...` in the file every later call read it as spread.
function v(...$a) { return count($a); }
function two($a, $b) { return $a + $b; }
echo v(...[1, 2]), "\n";
// a two-argument max AFTER a spread still takes the two-argument road
echo max(3, 4), " ", min(3, 4), "\n";
// and a nested call inside a spreading call does not inherit it either
echo v(...[two(1, 2), two(3, 4)]), "\n";
echo two(1, 2), "\n";
// max/min name the type they were given
try { max(5); } catch (\Throwable $e) { echo get_class($e), ": ", $e->getMessage(), "\n"; }
try { min("x"); } catch (\Throwable $e) { echo get_class($e), ": ", $e->getMessage(), "\n"; }

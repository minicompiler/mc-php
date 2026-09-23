<?php
// A spread argument that throws must unwind AT the throw: php never enters
// the callee and never reports anything about its arguments. Before the
// compute-then-check boundary was added to the spread path, mc-php ran
// php_unpack_at and the body first, so the catch saw a later error.
function boom() { throw new Exception("boom"); }
function f(...$a) { echo "body\n"; return count($a); }
try {
    echo f(...boom()), "\n";
} catch (Exception $e) {
    echo "caught ", $e->getMessage(), "\n";
}
// and the ordinary case still works
echo f(...[1, 2, 3]), "\n";
// a throw in the SECOND of two arguments, the first a spread
function g($x, ...$r) { echo "g body\n"; return $x + count($r); }
try {
    echo g(1, ...boom()), "\n";
} catch (Exception $e) {
    echo "caught2 ", $e->getMessage(), "\n";
}

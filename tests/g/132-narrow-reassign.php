<?php
// Narrowing must drop when the guarded variable is reassigned: inside
// is_string($t) the port borrows a bare $t as a string, but after `$t = 5`
// it is an int, so the later (string)$t must do the full coercion, not the
// stale string borrow. Compiled must equal interpreted.
function f(mixed $t): string {
    if (is_string($t)) {
        $t = 5;
        return "[" . (string) $t . "]";
    }
    return "no";
}
function g(mixed $t): string {
    if (is_int($t)) {
        $t = "hi";
        return "[" . (int) $t . "]";   // "hi" is int 0 in php
    }
    return "no";
}
echo f("abc"), "\n";
echo g(42), "\n";

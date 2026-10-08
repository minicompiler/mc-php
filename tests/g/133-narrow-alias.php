<?php
// Narrowing must drop when the guarded variable is aliased by reference and
// mutated through the alias: after `$a = &$t; $a = 9;` the variable $t is an
// int, so (string)$t must not take the stale string borrow.
function f(mixed $t): string {
    if (is_string($t)) {
        $a = &$t;
        $a = 9;
        return "[" . (string) $t . "]";
    }
    return "no";
}
echo f("xy"), "\n";

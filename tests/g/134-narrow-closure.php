<?php
// A closure/function defined inside a guarded branch starts with clean
// narrowing: its own mixed $t (same name) must not inherit the outer branch's
// string/int narrowing. The outer $t keeps its narrowing after the closure.
function h(mixed $t): string {
    if (is_string($t)) {
        $c = function (mixed $t): string { return (string) $t; };
        return $c(7) . "/" . (string) $t;
    }
    return "no";
}
echo h("Q"), "\n";

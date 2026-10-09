<?php
// `return EXPR;` in a function declared `: void` is php's compile-time fatal,
// raised whether or not the function is ever called (src/lvalue.mc); it was
// accepted and the value dropped.
echo "not reached\n";
function quiet(int $x): void {
    if ($x > 0) {
        return $x * 2;
    }
}

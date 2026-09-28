<?php
// extB -- calls a function extension A publishes, which this source does not
// declare. php resolves a call when it RUNS, in its own function table; so
// does the compiled extB: the call is looked up there once per request and
// made with zend_call_known_function, which is what c/extB.c, its C twin,
// does (README.md). With A absent it throws php's own Error.
function b_use(int $a, int $b): int {
    return a_add($a, $b);
}

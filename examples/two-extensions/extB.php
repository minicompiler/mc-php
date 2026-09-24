<?php
// extB -- the SOURCE extB.mc stands in for. B calls a function A publishes,
// resolved when the call runs, as php resolves any function call. mc-php
// refuses it today, by name, and tests/examples.sh pins that refusal:
//
//   extB.php:8: mc-php: a php function mc-php does not have: a_add is not implemented yet
function b_use(int $a, int $b): int {
    return a_add($a, $b);
}

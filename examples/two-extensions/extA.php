<?php
// extA -- the SOURCE extA.mc stands in for. This half compiles with mc-php
// today (it is examples/hello's shape); the pair does not, because extB.php
// calls into it (README.md).
function a_add(int $a, int $b): int { return $a + $b; }

<?php
// mc-php: semantics=c-debug
// C semantics with the checks back as a trap (docs/semantics.md): a string
// offset read outside the string stops the program and names the line.
function at(string $s, int $i): int {
    $t = 0;
    for ($k = 0; $k < 3; $k++) { $t = $t + ord($s[$i + $k]); }
    return $t;
}
echo at("abcdef", 1), "\n";
echo at("abc", 2), "\n";
echo "not reached\n";

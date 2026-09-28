<?php
// `[php] checked_reads = true` (03-trap-str.toml, docs/semantics.md): the
// reads C leaves unchecked are checked again, and a string offset read outside
// the string stops the program and names the line.
function at(string $s, int $i): int {
    $t = 0;
    for ($k = 0; $k < 3; $k++) { $t = $t + ord($s[$i + $k]); }
    return $t;
}
echo at("abcdef", 1), "\n";
echo at("abc", 2), "\n";
echo "not reached\n";

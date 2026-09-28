<?php
// extA -- one function, compiled by mc-php into build/extA.so (ext*.toml).
// c/extA.c is its C twin: the same function written as an ordinary C
// extension, measured beside it (README.md).
function a_add(int $a, int $b): int { return $a + $b; }

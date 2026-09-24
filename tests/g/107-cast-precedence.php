<?php
// A cast binds as tightly as unary minus: `(int) $s - 1` is ((int) $s) - 1.
// The compiler parsed the operand at `+`'s precedence, so `+ - * / %` after
// it went INSIDE the cast -- `(int) "1.9" + 0.5` was int(2) where php says
// float(1.5), and `(bool) 0 + 1` was bool(true) where php says int(1).
var_dump((int) "1.9" + 0.5, (int) "5" - 2, (string) 1 . 2, (float) "1.5" * 2);
var_dump((int) "7" * 3, (bool) 0 + 1, (int) 2.9 ** 2, -(int) "3" + 1);
function f(string $s, int $b): int { return (int) substr($s, 0, 2) - $b; }
var_dump(f("12x", 5), f("9", 10));

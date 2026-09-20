<?php
echo 0b101, " ", 0o17, " ", 017, " ", 1_000, " ", 0x1F, "\n";
echo intdiv(7, 2), " ", 7 % 3, " ", 2 ** 10, "\n";
echo abs(-3), " ", max(1, 2), " ", min(1, 2), "\n";
echo 1.5 + 2.25, " ", 10.0 / 4, "\n";
var_dump(intval("12abc"), floatval("3.5x"), strval(12), (int) 1.9, (float) 3, (string) true);
var_dump(is_int(1), is_string("s"), is_float(1.0), is_bool(true), is_array([1]));

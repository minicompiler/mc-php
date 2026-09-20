<?php
function f($a = 0, $b = 0, $c = 0) { return func_num_args(); }
var_dump(f(1), f(1,2), f(1,2,3), f());
function g($a, $b) { return func_get_arg(1); }
var_dump(g("x", "y"));
function h($a = 1) { try { return func_get_arg(5); } catch (ValueError $e) { return "caught"; } }
var_dump(h(1));

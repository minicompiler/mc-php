<?php
// A parameter's default that is an array or a string literal, on a function
// and on a method, and a default computed from a constant. Found while
// fixing PR #65's defects.
function g(array $a = ["k" => [1, 2]], int $n = 3) { var_dump($a, $n); } g();
function f2(array $a = []) { var_dump($a); } f2();
class P { function f($a = "s") { var_dump($a); } } (new P)->f();
const K = 4; function k($v = K * 2, $w = [K => "x"]) { var_dump($v, $w); } k();

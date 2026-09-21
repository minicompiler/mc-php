<?php
// php runs a finally on the way out of a return in the try OR in a catch
function a() { try { return 1; } finally { echo "f1\n"; } }
echo a(), "\n";
function b() { try { throw new Exception("x"); } catch (Exception $e) { return 2; } finally { echo "f2\n"; } }
echo b(), "\n";
function c() { try { try { return 3; } finally { echo "inner\n"; } } finally { echo "outer\n"; } }
echo c(), "\n";
function d() { foreach ([1, 2] as $v) { try { if ($v == 2) return $v; } finally { echo "f$v\n"; } } return 0; }
echo d(), "\n";
// a return in the finally itself wins
function e() { try { return 5; } finally { return 6; } }
echo e(), "\n";
// a try with no return at all is unchanged
function g() { try { echo "t\n"; } finally { echo "f\n"; } return 7; }
echo g(), "\n";
class K { function m() { try { return 8; } finally { echo "fm\n"; } } }
echo (new K)->m(), "\n";

<?php
// php's trace, built when a throwable is CREATED (lib/php_rt.mc § the trace):
// a frame per call not yet returned -- functions, methods (the declaring class,
// -> or ::), constructors, closures ({closure:FILE:LINE}) -- with the call's
// file and line and the arguments as getTraceAsString writes them; the private
// `string` and `trace` properties; __toString with its "Next" chain and the
// "and defined in" rule; a parameter TypeError placed where the parameter is
// declared; and the uncaught output built from all of it.
class MyEx extends InvalidArgumentException {}
function a(int $n) { try { b($n); } catch (RuntimeException $e) { throw new MyEx("wrapped", 7, $e); } }
function b(int $n) { throw new RuntimeException("inner $n"); }
function c() { try { a(1); } catch (MyEx $e) { return $e; } }
$e = c();
echo $e, "\n---\n";
echo count($e->getTrace()), " ", count($e->getPrevious()->getTrace()), "\n";
var_dump(new RuntimeException("x", 3));
function t($a, $b = null, $c = null, $d = null, $e = null) { return (new Exception("m"))->getTraceAsString(); }
echo t("a\nb\tc\\d'e\"f\x01\x7f\xc3\xa9", "0123456789abcde", "0123456789abcdef", 1.5, 0.1), "\n";
echo t(1/3, 1.0, -0.0, 1e100, 2.5e-7), "\n";
echo t(NAN, INF, -INF, PHP_INT_MIN, true), "\n";
echo t(false, null, [1], new stdClass, "\r\f\v\e"), "\n";
class A { public function m($x) { return new Exception("e"); } public static function s($y) { return (new B)->m($y); } }
class B extends A { public function m($x) { return parent::m($x + 1); } }
echo A::s(3)->getTraceAsString(), "\n";
class T { public function __construct(int $n) { throw new LogicException("in ctor $n"); } }
try { new T(5); } catch (LogicException $l) { echo $l->getTraceAsString(), "\n"; }
$f = function ($z) { return new Exception("c"); };
echo $f(9)->getTraceAsString(), "\n";
function takes_int(int $i): int { return $i * 2; }
try { takes_int("abc"); } catch (TypeError $te) { echo $te->getLine(), " ", $te, "\n"; }
function outer(string $s): int { return takes_int($s); }
echo outer("abc"), "\n";

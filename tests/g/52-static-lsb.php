<?php
class A { public static function create() { return new static(); } public static function who() { return static::class; } public function n() { return static::NAME; } const NAME="A"; }
class B extends A { const NAME="B"; }
var_dump(get_class(B::create()));
var_dump(A::who(), B::who());
var_dump((new B)->n());
$f = static function() { return 7; };
var_dump($f());
class C2 extends A { }
function cc() { return C2::gcc(); }
class A2 { public static function w() { return get_called_class(); } }
class B2 extends A2 {}
echo B2::w(),"\n",A2::w(),"\n";

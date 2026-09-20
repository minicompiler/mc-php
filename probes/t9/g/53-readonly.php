<?php
class C { public function __construct(public readonly int $x) {} }
class D extends C {}
$o = new C(1);
try { $o->x = 2; } catch (Error $e) { echo get_class($e), ": ", $e->getMessage(), "\n"; }
$d = new D(3);
try { $d->x = 4; } catch (Error $e) { echo $e->getMessage(), "\n"; }
class E { public readonly int $y; function set() { $this->y = 1; } function again() { $this->y = 2; } }
$e = new E; $e->set(); echo $e->y, "\n";
try { $e->again(); } catch (Error $er) { echo $er->getMessage(), "\n"; }

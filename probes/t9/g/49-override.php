<?php
class P { public function m(): void {} }
class C extends P { #[\Override] public function m(): void { echo "ok\n"; } }
interface I { public function q(); }
class D implements I { #[\Override] public function q() { echo "q\n"; } }
(new C)->m();
(new D)->q();
echo "Done\n";
abstract class A { abstract public function z(); }
class B extends A { #[\Override] public function z() { echo "z\n"; } }
(new B)->z();

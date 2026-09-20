<?php
// D7 has no refcount: the destructor point this implements is the end of the
// program, in php's own reverse creation order.
class A {
    public $n;
    function __construct($n) { $this->n = $n; }
    function __destruct() { echo "destruct {$this->n}\n"; }
}
class B extends A { }
$a = new A(1);
$b = new B(2);
$c = new A(3);
echo "end of main\n";

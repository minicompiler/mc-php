<?php
// two findings of the pull request's own review, both older than T10.
// readonly used the VALUE as the "has it been written" mark, so a property
// deliberately initialised to null could be written a second time; and
// sscanf's outputs were read rather than taken by reference, with a null
// standing for "not passed" -- which is every undefined $out at first use.
class C {
    public readonly ?int $x;
    public readonly int $y;
    function __construct() { $this->x = null; $this->y = 3; }
    function again() { $this->x = 5; }
}
$c = new C();
try { $c->again(); echo "x written twice\n"; } catch (Error $e) { echo $e->getMessage(), "\n"; }
try { $c->y = 9; } catch (Error $e) { echo $e->getMessage(), "\n"; }
var_dump($c->x, $c->y);
$n = sscanf("age 25", "%s %d", $w, $v);
var_dump($n, $w, $v);
var_dump(sscanf("age 25", "%s %d"));
$m = sscanf("1 2 3", "%d %d %d", $a, $b, $q);
var_dump($m, $a, $b, $q);

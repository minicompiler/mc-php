<?php
// a method's declared parameter type is CHECKED and CONVERTED
class C {
    function m(int $x, string $s, float $f, bool $b, array $a) {
        var_dump($x, $s, $f, $b, count($a));
    }
}
$o = new C();
$o->m("7", 5, "1.5", 1, [1, 2]);
try { $o->m([], "a", 1.0, true, []); } catch (TypeError $e) { echo get_class($e), "\n"; }
try { $o->m(1, "a", 1.0, true, "no"); } catch (TypeError $e) { echo "TE2\n"; }
try { $o->m("abc", "a", 1.0, true, []); } catch (TypeError $e) { echo "TE3\n"; }

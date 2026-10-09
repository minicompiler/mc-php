<?php
// A never-returning function that runs off its end: php's TypeError -- for an
// arrow function too, whose body php RUNS before refusing the implicit
// return, where a compile-time fatal used to be raised (PR #65 defect 4)
$f = fn(): never => var_dump("ran");
try { $f(); } catch (Throwable $e) { echo get_class($e), ": ", $e->getMessage(), " @", $e->getLine(), "\n"; }
class C {
  function n(): never { }
  function m() {
    $g = function (): never { };
    try { $g(); } catch (TypeError $e) { echo $e->getMessage(), "\n"; }
    $h = function (): int { };
    try { $h(); } catch (TypeError $e) { echo $e->getMessage(), "\n"; }
  }
}
try { (new C)->n(); } catch (Throwable $e) { echo get_class($e), ": ", $e->getMessage(), " @", $e->getLine(), "\n"; }
(new C)->m();

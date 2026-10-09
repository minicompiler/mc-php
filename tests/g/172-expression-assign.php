<?php
// An assignment, ++ and op= on a property used as a VALUE, the typed check's
// TypeError stopping it before the read; a static property the same way; a
// builtin with no value (var_dump) used as one; print as an expression.
// Found while fixing PR #65's defects.
class P { public int $n = 0; public $u; public array $a; public static int $s = 1; }
$o = new P;
var_dump($o->n = "5", $o->u = [1], ($o->n = 7) + 1);
echo $o->n++, " ", ++$o->n, " ", $o->n--, " ", $o->n += 2, "\n";
$x = $o->u = $o->n = 3; var_dump($x);
try { $x = ($o->a = null); var_dump($x); } catch (Throwable $e) { echo get_class($e), ": ", $e->getMessage(), "\n"; }
$f = fn() => $o->a = null;
try { $f(); } catch (Throwable $e) { echo get_class($e), ": ", $e->getMessage(), "\n"; }
$g = fn() => $o->n = 1.5;
try { var_dump($g()); } catch (Throwable $e) { echo get_class($e), ": ", $e->getMessage(), "\n"; }
function t($f) { try { $f(); } catch (Throwable $e) { echo get_class($e), ": ", $e->getMessage(), "\n"; } }
t(fn() => P::$s = "x");
t(fn() => var_dump(P::$s));
var_dump(P::$s = 4, P::$s++, P::$s);
$v = var_dump(1);
var_dump($v);
function id($v) { return $v; }
var_dump(id(var_dump(2)));
$h = fn() => var_dump(3);
var_dump($h());
print "hi\n";
$r = print "y\n";
echo $r, "\n";
$z = 0;
$z && print "no\n";
$z || print "yes\n";

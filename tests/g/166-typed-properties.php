<?php
// A typed property: its declared type checked on every write (coercion, the
// deprecations, the TypeError), the uninitialized state php reads as an
// Error and prints as uninitialized(T), promoted parameters, and the
// increment past PHP_INT_MAX. Found while fixing PR #65's defects.
class P1 { public int $n = 0; public ?string $s = null; }
$o = new P1;
try { $o->n = "x"; } catch (TypeError $e) { echo $e->getMessage(), "\n"; }
$o->n = "5"; var_dump($o->n);
$o->n = 2.0; var_dump($o->n);
try { $o->s = []; } catch (TypeError $e) { echo $e->getMessage(), "\n"; }
$o->s = 5; var_dump($o->s);
class P2 { public int $n; public ?string $s = null; public float $f = 1; public array $a = []; public bool $b = false; }
$o = new P2;
print_r($o); echo "\n";
try { echo $o->n; } catch (Error $e) { echo get_class($e), ": ", $e->getMessage(), "\n"; }
$o->n = 3; $o->f = 2; var_dump($o->n, $o->f);
try { $o->b = "x"; var_dump($o->b); } catch (TypeError $e) { echo $e->getMessage(), "\n"; }
try { $o->a = 1; } catch (TypeError $e) { echo $e->getMessage(), "\n"; }
try { $o->n = true; var_dump($o->n); } catch (TypeError $e) { echo $e->getMessage(), "\n"; }
$o->n++; var_dump($o->n);
$o->n += 1.5; var_dump($o->n);
class Q {}
class P { public int $n; public array $a; public ?Q $q; public int $m = 5; public static int $s = 1; public readonly int $r;
  public static int $u; public float $f = 1; public ?string $o = null; public int|string $us = 0; public bool $b = false; }
function t($f) { try { $f(); } catch (Throwable $e) { echo get_class($e), ": ", $e->getMessage(), "\n"; } }
$o = new P;
t(function () use ($o) { $o->n = true; var_dump($o->n); });
t(function () use ($o) { $o->a = null; });
t(function () use ($o) { $o->q = new stdClass; });
t(function () use ($o) { $o->n = 1.5; var_dump($o->n); });
t(function () use ($o) { $o->n = "1e3"; var_dump($o->n); });
t(function () { P::$s = "x"; });
t(function () { var_dump(P::$s); P::$s = "7"; var_dump(P::$s); echo P::$s++, "\n"; var_dump(P::$s); });
t(function () { var_dump(P::$u); });
t(function () use ($o) { $o->f = 3; var_dump($o->f); $o->o = 5; var_dump($o->o); $o->us = 1.0; var_dump($o->us); $o->us = "a"; var_dump($o->us); $o->b = "x"; var_dump($o->b); });
$p = new P;
print_r($p); echo "\n"; var_export($p); echo "\n"; echo json_encode($p), "\n"; foreach ($p as $k => $v) echo "$k\n";
var_dump(isset($p->n), $p->n ?? "d", serialize($p));
$p->a[] = 1; var_dump($p->a);
t(function () use ($p) { $p->n[] = 1; });
var_dump($p == new P);
$c = clone $p; print_r($c); echo "\n";
t(function () use ($p) { $p->n++; });
$p->n = PHP_INT_MAX; t(function () use ($p) { $p->n++; }); t(function () use ($p) { $p->n += 1; });
$p->n = PHP_INT_MIN; t(function () use ($p) { $p->n--; });
t(function () use ($p) { echo $p->r; });
class PP { public function __construct(public int $x, protected ?string $y = null, private readonly array $z = []) {} function g() { $this->y = 5; var_dump($this->y); $this->z = [1]; } }
$pp = new PP(3); print_r($pp); echo "
"; try { $pp->x = "q"; } catch (TypeError $e) { echo $e->getMessage(), "
"; } $pp->g();

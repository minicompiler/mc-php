<?php
// (array) and (object) casts php's way -- the mangled keys of non-public
// properties, uninitialized ones left out, a scalar boxed -- and the
// compile-time deprecation of the non-canonical cast names. Found while fixing
// PR #65's defects.
declare(strict_types=1);
class P { public int $a = 1; protected string $b = "x"; private ?float $c = 2.5; public int $u; }
var_dump((integer)"1", (boolean)1, (double)"2", (binary)3);
$o = new P;
var_dump((array)$o, (array)null, (array)5, (array)[1]);
var_dump((object)["x" => 1, 7 => "s"], (object)5, (object)null);
$m = "q";
$a = (array)$m;
$a[] = 2;
var_dump($a, $m);
$s = (object)["7" => 1];
foreach ((array)$s as $k => $v) var_dump($k);
print_r($s); echo "\n"; $o2 = (object)["a" => [1]]; $o2->a[] = 2; var_dump($o2->a);

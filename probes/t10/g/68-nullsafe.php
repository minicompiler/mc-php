<?php
// `?->` on a null receiver answers null and does not access anything
class C { public $p = 1; public ?C $n = null; function m() { return 2; } }
$x = null;
var_dump($x?->p);
var_dump($x?->m());
$c = new C();
var_dump($c?->p);
var_dump($c?->m());
var_dump($c->n?->p);
var_dump($c?->n?->p);

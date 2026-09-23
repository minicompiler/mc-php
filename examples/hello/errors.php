<?php
// What php does when an INTERNAL function is called wrongly, which is not
// what it does for a userland one: an extension's function carries no
// "called in FILE on line N" tail, and an extra argument is an error rather
// than being ignored. So this file is NOT differential against the
// interpreted source -- it is graded against errors.expect, which
// tests/ext/refx.c measures from a reference extension built the ordinary C
// way (tests/ext.sh re-measures it wherever a C compiler and php-config are
// there).
declare(strict_types=1);

foreach ([
    fn() => hello_addone("41"),
    fn() => hello_addone(),
    fn() => hello_addone(1, 2),
    fn() => hello_addone(1.5),
    fn() => hello_addone(true),
    fn() => hello_addone(null),
    fn() => hello_addone([]),
    fn() => hello_addone(new stdClass),
    fn() => hello_greet(7),
    fn() => hello_not(1),
    fn() => hello_half("2.5"),
    fn() => hello_sum(1, 2),
    fn() => hello_sum(1, 2, 3, 4),
] as $f) {
    try { var_dump($f()); }
    catch (Throwable $e) { echo get_class($e), ": ", $e->getMessage(), "\n"; }
}

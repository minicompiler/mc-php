<?php
// The differential driver: this file is run TWICE and the two runs must print
// the same bytes -- once with hello.so loaded, and once with hello.php
// required, so the functions are php's own. It is the whole claim of the
// extension back end reduced to one comparison.
//
// It must not print anything that can tell the two apart for a legitimate
// reason. `extension_loaded` is exactly that, which is why it guards the
// require and is never printed.
declare(strict_types=1);

if (!extension_loaded('hello')) {
    require __DIR__ . '/hello.php';
}

var_dump(hello_addone(41));
var_dump(hello_addone(-1));
var_dump(hello_addone(PHP_INT_MAX - 1));
var_dump(hello_greet("world"));
var_dump(hello_greet(""));
var_dump(hello_greet("\x00\xff binary \x00 safe"));
var_dump(hello_half(5.0));
var_dump(hello_half(5));                 // the one widening strict mode allows
var_dump(hello_half(-0.5));
var_dump(hello_not(true), hello_not(false));
var_dump(hello_sum(1, 2, 3));
var_dump(hello_sum(-1, 0, 1));
var_dump(hello_pos(3));
var_dump(hello_zero());

echo "A\n";
hello_say("B");
echo "C\n";
var_dump(hello_say("D"));                // a void function answers null

try { hello_pos(-1); } catch (Throwable $e) {
    echo get_class($e), ": ", $e->getMessage(), "\n";
}

$z = new ReflectionFunction('hello_zero');
echo $z->getNumberOfParameters(), " ", $z->getReturnType(), "\n";

$r = new ReflectionFunction('hello_sum');
echo $r->getNumberOfParameters(), " ",
     $r->getNumberOfRequiredParameters(), " ",
     $r->getReturnType(), " ",
     $r->getParameters()[1]->getType(), " ",
     $r->getParameters()[1]->getName(), "\n";

$n = 0;
foreach (["a", "bb", "ccc"] as $s) { $n += strlen(hello_greet($s)); }
echo $n, "\n";

// output buffering: what the module echoes goes through php's own output
// layer, so ob_start() captures it in order with php's own echo
ob_start();
echo "A";
hello_say("B");
echo "C";
$x = ob_get_clean();
echo "captured: ", json_encode($x), "\n";
ob_start();
ob_start();
hello_say("inner");
$in = ob_get_clean();
$out = ob_get_clean();
echo "nested: ", json_encode($in), " ", json_encode($out), "\n";

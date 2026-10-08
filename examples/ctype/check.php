<?php
// The gate: run with ctype.so loaded, each of the eleven cty_* is compared
// against php's own ctype_* (the compiled-in reference) over a thorough corpus,
// and the output is deterministic -- tests/examples.sh grades it against
// check.expect. The reference here is the built-in ctype extension itself (the
// port is pure runtime: strspn over compile-time literal sets, chr, strlen).
//
// E_DEPRECATED is off: php 8.5 emits "Argument of type int will be interpreted
// as string in the future" for every non-string argument to ctype_*. That is a
// transitional notice about a future php, not a return-value difference; the
// port reproduces the RETURN semantics of 8.5 (ext/ctype/ctype.c), which is
// what a ctype port is. The notice is noted in README.md, not replicated.
declare(strict_types=1);
error_reporting(E_ALL & ~E_DEPRECATED);
// The port targets the C locale (7-bit ASCII classes); set it so both the
// module and the reference ctype_* classify 128..255 the same way (README.md).
setlocale(LC_CTYPE, "C");

$fns = ['alnum', 'alpha', 'cntrl', 'digit', 'graph', 'lower', 'print', 'punct', 'space', 'upper', 'xdigit'];

// The corpus: every one of the 256 byte values as a one-character string, the
// empty string, multi-character strings (all-pass and one-fail), ints across
// and outside the -128..255 char-code window, and the non-int/non-string types.
$inputs = [];
for ($b = 0; $b < 256; $b++) { $inputs[] = chr($b); }
$inputs[] = '';
$inputs[] = 'abc';          // all alpha/lower
$inputs[] = 'ABCDEF';       // all upper, all xdigit
$inputs[] = '0123456789';   // all digit
$inputs[] = 'deadBEEF';     // all xdigit, mixed case
$inputs[] = 'ab1';          // alnum but not alpha
$inputs[] = 'hello world';  // a space fails graph/alnum, passes print
$inputs[] = "\t\n\r\v\f";   // all cntrl and all space
$inputs[] = '   ';          // all space, not graph
$inputs[] = 'abc!';         // one punct fails alpha
$inputs[] = "ab\x00";       // an embedded NUL fails everything but cntrl
foreach ([0, 1, 47, 48, 57, 58, 64, 65, 90, 91, 96, 97, 122, 123, 127, 128, 255,
          256, 300, 1000, -1, -2, -128, -129, -1000, PHP_INT_MAX, PHP_INT_MIN] as $i) {
    $inputs[] = $i;
}
$inputs[] = 1.5;
$inputs[] = 48.0;
$inputs[] = 0.0;
$inputs[] = true;
$inputs[] = false;
$inputs[] = null;
$inputs[] = [1, 2, 3];
$inputs[] = 1e300;
// the types the argument borrow (phx_zarg_ro) exposes in place without a copy
// or a proxy: a resource and an object reach the body as their own type (never
// string or int) and must answer exactly as php's ctype does -- false, not a
// throw. A __toString object is NOT stringified (ctype never calls it).
$inputs[] = fopen('php://memory', 'r');
$inputs[] = new stdClass;
$inputs[] = new class { function __toString(): string { return '42'; } };

$cases = 0;
$mismatches = 0;
foreach ($inputs as $v) {
    foreach ($fns as $f) {
        $cases++;
        $got = ('cty_' . $f)($v);
        $want = ('ctype_' . $f)($v);
        if ($got !== $want) {
            $mismatches++;
            if ($mismatches <= 40) {
                $label = is_array($v) ? 'array' : var_export($v, true);
                echo "MISMATCH cty_$f(", substr($label, 0, 24), ") got ",
                     var_export($got, true), " want ", var_export($want, true), "\n";
            }
        }
    }
}

echo "cases $cases\n";
echo "mismatches $mismatches\n";
echo $mismatches === 0 ? "all byte for byte php's own ctype\n" : "FAILED\n";

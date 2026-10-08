<?php
// The no-UAF matrix for the borrowing argument path (phx_zarg_ro, lib/php_ext.mc):
// every cty_* is a plain mixed, field-read-only parameter, so its argument is
// borrowed from the engine in place rather than copied. This drives each one
// with every value shape the borrow treats specially -- a reference (followed),
// a resource (refused, php's Error), an array and an object (type read, never
// proxied or accessed), a string (escaped), null/int/bool/float -- for many
// rounds, so a wrong borrow (a double free, a leak, a missing escape) shows as
// a block the debug allocator still holds at the request's end.
setlocale(LC_CTYPE, "C");
$fns = ['cty_alnum', 'cty_alpha', 'cty_cntrl', 'cty_digit', 'cty_graph',
        'cty_lower', 'cty_print', 'cty_punct', 'cty_space', 'cty_upper', 'cty_xdigit'];
class Stringy { function __toString(): string { return "42"; } }
$acc = 0;
for ($r = 0; $r < 300; $r++) {
    $res = fopen("php://memory", "r");          // a fresh resource each round
    $obj = new stdClass; $obj->x = $r;
    $str = str_repeat("7", 40) . $r;            // a non-interned (refcounted) string
    $ref = $str; $alias = &$ref;                // a reference to it
    $shapes = ["0", "9", "", "a9z", "12\x0034", $str, 48, -1, -200, 300, 0,
               null, true, false, 1.5, [1, 2, 3], $obj, new Stringy, $res, $alias];
    foreach ($fns as $f) {
        foreach ($shapes as $v) {
            try { $acc += (int) @$f($v); }
            catch (\Throwable $e) { $acc += strlen($e->getMessage()); }
        }
    }
    fclose($res);
}
echo "acc=$acc\n";

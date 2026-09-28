<?php
// B WITHOUT A: the call finds nothing in php's function table and throws
// php's own Error, compiled as interpreted and as the C twin. Run with extB
// loaded and extA not, or with neither (extB.php is required then, and
// extA.php never is).
declare(strict_types=1);

if (!extension_loaded('extB')) { require __DIR__ . '/extB.php'; }

var_dump(function_exists('a_add'));
for ($i = 0; $i < 2; $i++) {
    try {
        var_dump(b_use(2, 3));
    } catch (Error $e) {
        echo get_class($e), ": ", $e->getMessage(), "\n";
    }
}

<?php
// php runs a `finally` on the way out of a TOP-LEVEL return too, innermost
// first, and then the shutdown functions and the destructors. mc-php did not
// create the deferred-return flag at the top level at all, so the flag the
// return raised was read by nobody and the script carried on past the try.
class D { function __destruct() { echo "dtor\n"; } }
$d = new D();
register_shutdown_function(function () { echo "shutdown\n"; });
echo "a\n";
try {
    try {
        echo "t\n";
        return 7;
    } finally {
        echo "inner\n";
    }
} finally {
    echo "outer\n";
}
echo "never\n";

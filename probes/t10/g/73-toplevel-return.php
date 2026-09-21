<?php
// php's top-level `return` ENDS THE SCRIPT: the shutdown functions and the
// destructors run, the output is flushed and the status is 0 -- a value
// returned here does not set it. mc-php returned from the generated `main`
// instead, so nothing was flushed and the status was junk (54, 82, 94, 142
// and 178 on five runs of the same source).
class D { function __destruct() { echo "destruct\n"; } }
$d = new D();
register_shutdown_function(function () { echo "shutdown\n"; });
echo "before\n";
if (true) {
    return 7;
}
echo "never\n";

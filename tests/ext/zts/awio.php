<?php
// tests/frankenphp.sh, step 6b: a compiled worker drives the event loop inside
// a request under the threaded SAPI -- a fiber awaits a timer, another a
// non-blocking pipe read. At the worker's reap the loop is torn down and every
// fiber stack unmapped, so the loop leaves nothing across requests. The answer
// is $n + 7 (zts_await_io), the request's own.
$n = (int) ($_GET['n'] ?? 0);
echo zts_await_io($n), "\n";

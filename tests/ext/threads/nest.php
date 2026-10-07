<?php
// tests/ext.sh: a nested thread -- a worker that starts and joins a thread of
// its own. The nested thread's record used to be allocated in the worker's
// arena; the request's free loop (lib/php_rt.mc php_thr_endall) releases that
// arena before the record is read, so the shutdown after this call was a
// use-after-free (SIGSEGV). The record now lives in its own arena
// (php_thr_start), so every record is freed by its own reap entry and the free
// order cannot dangle one. nest_run(41) returns 42 and the request ends clean.
function _leaf(int $x): int { return $x + 1; }
function _worker(int $x): int {
    $h = mcphp_thread_start(fn(int $y): int => _leaf($y), $x);
    return (int) mcphp_thread_join($h);
}
function nest_run(int $x): int {
    $w = mcphp_thread_start(fn(int $z): int => _worker($z), $x);
    return (int) mcphp_thread_join($w);
}

<?php
// examples/bcmath's default scale (bc_scale) is php's BCG(bc_precision): one
// per request, and under ZTS one per php thread. The port keeps it in a
// `global`, so it lives in the module's global table -- per php thread and
// copied fresh at each request under ZTS (docs/threads.md, "What each request
// starts from"), and SHARED with the request's own worker threads. The review
// of #65 asked whether such a worker can race it. bcmath.php starts no thread
// (mcphp_thread_* are intrinsics compiled into the module that calls them,
// never published), so the only road in is ANOTHER module's worker -- this
// one's, tests/ext/threads -- and that road goes through php's engine:
//
//   * a php callable on a worker: an NTS php refuses it; a ZTS php runs it as
//     a php request of its own, whose global table is a fresh copy, so its
//     bc_scale(5) answers that request's 0 and leaves this one's 3 alone;
//   * a compiled worker calling bc_scale: a call through php's function table
//     from a worker, which throws (tests/ext.sh step 20, "a worker reaching
//     php's engine gets an Error").
//
// Either way nothing but this request writes this request's default scale.
bc_scale(3);
try {
    $r = th\prun1(fn($s) => bc_scale($s), 5);
    echo "a php worker: ran in a request of its own, saw $r\n";
} catch (Error $e) {
    $m = $e->getMessage();
    $p = strpos($m, "; not cached: ");
    echo "a php worker: ", $p === false ? $m : substr($m, 0, $p), "\n";
}
echo "this request's scale: ", bc_scale(), "\n";

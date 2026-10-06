<?php
// Step 6b self-test (docs/threads.md § Step 6b): MANY socket fetches on ONE
// thread, driven by the event loop -- the shape http_get_many takes on the
// program road, where the blocking worker of 6a is replaced by a fiber per
// fetch. A blocking loopback peer on another thread serves N connections; the
// main thread spawns N fibers that each connect and read, then drives the loop
// once. Every connect is outstanding at the same time (the loop interleaves the
// fibers), so this is concurrency on a single OS thread, no engine. Graded
// against 23-http.out.

$N = 4;
$lp = mcphp_tcp_listen(0);
$lfd = $lp >> 32;
$port = $lp & 0xffffffff;

// the peer: serve N connections, each a fixed reply, on a thread of its own
$srv = mcphp_thread_start(function (int $lfd): int {
    for ($i = 0; $i < 4; $i++) {
        mcphp_tcp_accept_send($lfd, "ok");
    }
    return 0;
}, $lfd);

// one fiber per fetch: connect and read, both suspending on the loop
$fetch = function (int $port): string {
    $fd = mcphp_connect(0x7f000001, $port);
    $b = mcphp_io_read($fd, 16);
    mcphp_tcp_close($fd);                    // a connected socket: closesocket on Windows, not close()
    return $b;
};

$h = [];
for ($i = 0; $i < $N; $i++) $h[$i] = mcphp_spawn($fetch, $port);
mcphp_loop_run();                            // drive all N fetches to completion

$out = [];
for ($i = 0; $i < $N; $i++) $out[$i] = mcphp_await($h[$i]);
echo "fetched ", count($out), ": ", implode(" ", $out), "\n";

mcphp_thread_join($srv);
mcphp_tcp_close($lfd);
echo "done\n";

<?php
// Step 5 self-test (docs/threads.md § Step 5): the event loop, stackful fibers
// and await of real I/O -- on the program road, no php engine on the fiber.
// Graded against 18-await.out (mcphp_* exist only in compiled code, so this is
// C-behaviour, not run under php). It exercises: a timer await, a future
// completed and failed, fibers spawned that await a timer (so ph_ctx_swap
// really suspends and resumes them), and a non-blocking pipe read awaited on a
// fiber (so the kqueue/epoll/IOCP backend drives the completion).

// --- a top-level timer await: the nested-loop drive-to-completion bridge ----
$t0 = mcphp_timer(10);
mcphp_await($t0);
echo "timer done\n";

// --- a future, completed and failed, awaited at top level --------------------
$f = mcphp_future();
mcphp_future_complete($f, 42);
echo "future value: ", mcphp_await($f), "\n";

$g = mcphp_future();
mcphp_future_fail($g, new RuntimeException("boom"));
try {
    mcphp_await($g);
    echo "no throw\n";
} catch (\Throwable $e) {
    echo "future fail caught: ", $e->getMessage(), "\n";
}

// --- fibers that await a timer: the real suspend/resume over ph_ctx_swap -----
$work = function (int $x): int {
    mcphp_await(mcphp_timer(5));     // on a fiber: parks, the loop resumes it
    return $x + 1;
};
$a = mcphp_spawn($work, 2);
$b = mcphp_spawn($work, 6);
$c = mcphp_spawn($work, 10);
mcphp_loop_run();                    // drive until the three fibers finish
echo "spawn results: ", mcphp_await($a), " ", mcphp_await($b), " ", mcphp_await($c), "\n";

// --- a pipe read awaited on a fiber: the backend's arm/completion path -------
$p = mcphp_pipe();                   // (read_fd << 32) | write_fd  (test scaffolding)
$rfd = $p >> 32;
$wfd = $p & 0xffffffff;
$reader = function (int $fd): string {
    return mcphp_io_read($fd, 64);   // suspends until the pipe has bytes
};
$rd = mcphp_spawn($reader, $rfd);
mcphp_fd_write($wfd, "hello pipe");
mcphp_loop_run();
echo "pipe read: ", mcphp_await($rd), "\n";
mcphp_fd_close($rfd);
mcphp_fd_close($wfd);

echo "done\n";

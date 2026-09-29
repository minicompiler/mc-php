<?php
// A thread neither joined nor detached is waited for when the program ends,
// and the throwable it ended on is the program's uncaught one -- handed to
// set_exception_handler here, so the recording holds no path
// (docs/threads.md § Step 3; graded against 12-thread-unjoined.out).
function slow(int $ms): int { usleep($ms * 1000); echo "the slow thread finished\n"; return 1; }
function fail(int $x): int { usleep(20000); throw new LogicException("lost $x"); }
set_exception_handler(function (Throwable $e) {
    echo "uncaught from a thread: ", get_class($e), " ", $e->getMessage(), "\n";
});
mcphp_thread_start(fn(int $m): int => slow($m), 60);
mcphp_thread_start(fn(int $x): int => fail($x), 3);
echo "the program's last line\n";

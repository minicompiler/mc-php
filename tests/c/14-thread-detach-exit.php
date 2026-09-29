<?php
// A detached thread does not keep the program alive: the program's end does
// not wait for it, and the process's exit ends it, as std::thread::detach
// does (docs/threads.md § Step 3). The thread below never returns; the gate
// runs this under tests/lim.sh, so a program that waited for it would time out.
function forever(int $x): int {
    $n = 0;
    while (true) { $n++; usleep(1000); }
    return $n;
}
$t = mcphp_thread_start(fn(int $x): int => forever($x), 1);
mcphp_thread_detach($t);
echo "detached; running: ", mcphp_thread_running(), "\n";
echo "the program ends without it\n";

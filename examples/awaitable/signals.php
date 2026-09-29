<?php
// parallel() while signals arrive: a SIGCHLD handler installed WITHOUT
// SA_RESTART (pcntl_signal's third argument), so a read() or a waitpid() the
// parent is blocked in returns EINTR when one of the faster children exits.
// Every answer must still come home, and no child may be left unreaped.
// tests/examples.sh runs it against the C twin and the compiled module when
// this php has pcntl.
pcntl_async_signals(true);
$seen = 0;
pcntl_signal(SIGCHLD, function () use (&$seen) { $seen++; }, false);
function nap(string $ms): string { usleep((int) $ms * 1000); return "slept $ms"; }
$r = \awaitable\parallel('nap', '400', '10', '20', '30', '40', '50');
echo implode(', ', $r), "\n";
echo "SIGCHLD seen: ", var_export($seen > 0, true), "\n";
echo "a child left unreaped: ", var_export(pcntl_waitpid(-1, $st, WNOHANG) > 0, true), "\n";
// the handler php's manual recommends: it reaps whatever child has exited
// (pcntl_waitpid(-1, ..., WNOHANG)), so a child parallel() is waiting for
// may be reaped by it, and parallel()'s own waitpid() then answers ECHILD --
// an error to stop on, not one to ask again (EINTR is the only one)
pcntl_signal(SIGCHLD, function () { while (pcntl_waitpid(-1, $st, WNOHANG) > 0) {} }, false);
$r = \awaitable\parallel('nap', '300', '10', '20');
echo implode(', ', $r), "\n";
// and children the kernel reaps itself: a waitpid() for one answers ECHILD
pcntl_signal(SIGCHLD, SIG_IGN);
$r = \awaitable\parallel('nap', '200', '10');
echo implode(', ', $r), "\n";
pcntl_signal(SIGCHLD, SIG_DFL);
echo "done\n";

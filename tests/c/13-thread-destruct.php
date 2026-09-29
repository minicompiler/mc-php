<?php
// A copy made for another thread is a distinct object and is destructed once,
// by the thread that owns it (docs/threads.md § Step 3, as ext/parallel):
// a worker destructs what it created -- its copies of the arguments included
// -- when it ends; the joiner destructs its copy of the result at its own end.
// Graded against 13-thread-destruct.out: php has no thread API.
final class D {
    public function __construct(public int $n) {}
    public function __destruct() { echo "dtor ", $this->n, "\n"; }
}
function peek(D $d): int { return $d->n; }
function make(int $n): D { return new D($n); }
function pass(D $d): D { return $d; }

$a = new D(1);
// the worker's copy of $a: destructed when the worker ends ("dtor 1")
$r1 = mcphp_thread_join(mcphp_thread_start(fn(D $x): int => peek($x), $a));
// the worker's own D(2) at its end ("dtor 2"), and main's copy at main's end
$r2 = mcphp_thread_join(mcphp_thread_start(fn(int $n): D => make($n), 2));
// one source copied twice -- into the argument, then into the result: two
// objects, each destructed once ("dtor 1" now, "dtor 1" at main's end)
$r3 = mcphp_thread_join(mcphp_thread_start(fn(D $x): D => pass($x), $a));
echo "results: ", $r1, " ", $r2->n, " ", $r3->n, "\n";
echo "the copies are distinct: ", ($r3 === $a) ? "no" : "yes", "\n";
echo "end of main\n";
// main's end: its copy of pass()'s result, its copy of make()'s, then $a

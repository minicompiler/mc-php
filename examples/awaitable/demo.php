<?php
// The owner's demonstration (reference/aw6.php, translated): eight heavy
// calls sequentially and then through parallel(), timed. Not a gate -- the
// times are the host's -- but tests/examples.sh runs it and requires the
// "same results: true" line.
//
//     php -d extension=build/awaitable.so demo.php
//
// ANY callable the developer already has. Its body stays interpreted and is
// never compiled.
function heavy(string $n): array {
    $k = (int) $n; $s = 0;
    for ($i = 1; $i <= 4_000_000; $i++) { $s += ($i * $k) % 7; }
    return ['arg' => $n, 'sum' => $s, 'pid' => getmypid()];
}
class Service { public function method(string $x): string { return strtoupper($x) . "!"; } }

$args = ['1', '2', '3', '4', '5', '6', '7', '8'];

$t = hrtime(true);
$seq = array_map('heavy', $args);
$tseq = (hrtime(true) - $t) / 1e6;

\awaitable\reset();
$t = hrtime(true);
$par = \awaitable\parallel('heavy', ...$args);
$tpar = (hrtime(true) - $t) / 1e6;

printf("sequential  %8.1f ms\n", $tseq);
printf("parallel    %8.1f ms   %.1fx   distinct pids: %d\n", $tpar, $tseq / $tpar,
   count(array_unique(array_column($par, 'pid'))));
printf("same results: %s\n", var_export(
   array_column($seq, 'sum') === array_column($par, 'sum'), true));

// a closure, an arrow fn, an object's method, an internal function -- all callables
$svc = new Service;
$r = \awaitable\parallel(fn(string $s) => "[$s]", 'a', 'b');
$m = \awaitable\parallel([$svc, 'method'], 'hi', 'bye');
$i = \awaitable\parallel('strrev', 'abc', 'xyz');
var_dump($r, $m, $i);

// one that throws
$e = \awaitable\parallel(function (string $x) { throw new RuntimeException("blew up on $x"); }, 'q');
printf("error: %s   errors()=%d\n", var_export($e[0], true), \awaitable\errors());

// and it is still await(...) handing back an Intent
$w = \awaitable\await('awaitable\parallel', 'heavy', '1', '2');
printf("via await: failed=%s sums=%s\n", var_export($w->failed, true),
   implode(',', array_column($w->data, 'sum')));

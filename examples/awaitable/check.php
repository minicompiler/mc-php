<?php
// What awaitable.so does, printed so that a run can be compared with
// check.expect byte for byte. Nothing here depends on the clock, a pid's
// value or the network: parallelism is measured by what it CAN be seen to do
// (distinct pids, a concurrency peak under a semaphore), and the threads
// fetch file:// urls the script writes itself.
//
//     php -d extension=build/awaitable.so check.php
//
// It is graded against a recorded expectation and not differentially: there
// is no interpreted awaitable to compare with -- awaitable.src.php declares
// the API with empty bodies, and that is the point of it.
declare(strict_types=1);

use awaitable\Intent;
use awaitable\Semaphore;
use awaitable\WaitGroup;
use awaitable\Mutex;

echo "loaded: ", var_export(extension_loaded('awaitable'), true), "\n";
foreach (['awaitable\Intent', 'awaitable\Semaphore', 'awaitable\WaitGroup', 'awaitable\Mutex'] as $c) {
    echo $c, ": ", var_export(class_exists($c), true), "\n";
}

// --- await: suspends, runs, and ALWAYS hands back an Intent ------------------
$w = \awaitable\await(fn(int $a, int $b) => $a + $b, 2, 40);
echo get_class($w), " done=", var_export($w->done, true), " failed=", var_export($w->failed, true),
     " data=", var_export($w->data, true), " exception=", var_export($w->exception, true), "\n";
$w = \awaitable\await('strtoupper', 'intent');
echo "internal callable: ", $w->data, "\n";
$w = \awaitable\await(function (): void { throw new RuntimeException("boom"); });
echo "a callable that throws: failed=", var_export($w->failed, true), " ",
     get_class($w->exception), ": ", $w->exception->getMessage(), "\n";
try {
    \awaitable\await('no_such_function');
} catch (TypeError $e) {
    echo "TypeError: ", $e->getMessage(), "\n";
}

// --- parallel: any php callable, one forked child per argument ---------------
function heavy(string $n): array {
    $k = (int) $n;
    $s = 0;
    for ($i = 1; $i <= 200000; $i++) { $s += ($i * $k) % 7; }
    return ['arg' => $n, 'sum' => $s, 'pid' => getmypid()];
}
$args = ['1', '2', '3', '4', '5', '6'];
\awaitable\reset();
$par = \awaitable\parallel('heavy', ...$args);
$seq = array_map('heavy', $args);
$pids = array_unique(array_column($par, 'pid'));
echo "parallel: ", count($par), " results, the same sums as sequential: ",
     var_export(array_column($par, 'sum') === array_column($seq, 'sum'), true),
     ", distinct pids: ", count($pids), ", none of them this process: ",
     var_export(!in_array(getmypid(), $pids, true), true), "\n";
echo "sums: ", implode(',', array_column($par, 'sum')), "\n";

class Service { public function shout(string $x): string { return strtoupper($x) . "!"; } }
var_dump(\awaitable\parallel(fn(string $s) => "[$s]", 'a', 'b'));
var_dump(\awaitable\parallel([new Service, 'shout'], 'hi', 'bye'));
var_dump(\awaitable\parallel('strrev', 'abc', 'xyz'));
$e = \awaitable\parallel(function (string $x): string { throw new RuntimeException("failed on $x"); }, 'q');
echo "a child that throws: ", var_export($e[0], true), ", errors() = ", \awaitable\errors(), "\n";
$w = \awaitable\await('awaitable\parallel', 'heavy', '1', '2');
echo "await(parallel): failed=", var_export($w->failed, true), " sums=",
     implode(',', array_column($w->data, 'sum')), "\n";

// --- threads: native work on OS threads, capped by a semaphore ---------------
$dir = sys_get_temp_dir() . '/mcphp-awaitable-' . getmypid();
@mkdir($dir);
$urls = [];
$want = [];
for ($i = 0; $i < 6; $i++) {
    $body = str_repeat(chr(97 + $i), 1000 * ($i + 1));
    file_put_contents("$dir/f$i.txt", $body);
    $urls[] = "file://$dir/f$i.txt";
    $want[] = $body;
}
\awaitable\reset();
$sem = new Semaphore(2);
$sem->bind();
$got = \awaitable\http_get_many(...$urls);
$sem->unbind();
echo "http_get_many: ", count($got), " bodies, all as written: ", var_export($got === $want, true),
     ", completed() = ", \awaitable\completed(),
     ", peak concurrency within the semaphore's 2: ", var_export(\awaitable\peak() >= 1 && \awaitable\peak() <= 2, true), "\n";
echo "http_get: ", strlen(\awaitable\http_get($urls[2])), " bytes\n";
try {
    \awaitable\http_get("file://$dir/missing.txt");
} catch (Exception $x) {
    echo "http_get of a missing file throws ", get_class($x), "\n";
}
foreach (glob("$dir/*") as $f) { unlink($f); }
rmdir($dir);

// --- the sync primitives from php ------------------------------------------
$wg = new WaitGroup();
$wg->add(2);
$wg->done();
$wg->done();
$wg->wait();
$m = new Mutex();
$m->lock();
$m->unlock();
$s = new Semaphore(1);
$s->acquire();
$s->release();
echo "WaitGroup, Mutex and Semaphore: every call returned\n";
// the native handle is not the caller's to write
try {
    $s->__h = 0;
} catch (Error $e) {
    echo get_class($e), ": ", $e->getMessage(), "\n";
}
$s->acquire();
$s->release();
echo "and the semaphore still works\n";

<?php
// tests/frankenphp.sh: a ZTS module under a threaded SAPI. Every request calls
// work($n) once and prints what it answered; tests/frankenphp.sh checks each
// answer against the formula below and counts the php threads the load
// landed on. What MINIT builds here -- a global array, an object, a static
// property, a constant -- every request starts from; what a request writes to
// them is its own, and a request on another thread at the same moment must
// never see it (lib/php_zts.mc, docs/threads.md § ZTS).
final class _Box {
    public static int $count = 0;
    public array $items = [];
    public function add(int $x): int { $this->items[] = $x; return count($this->items); }
}

$zts_g = ['a' => 1, 'list' => [1, 2]];
$zts_box = new _Box();
define('ZTS_K', 7);

// echoed, not returned: it has to pass through php's output layer on every
// php thread, into the ob_start() level index.php opened
function zts_say(int $n): void {
    echo "|", 3 * $n;
}

// a thread of the API (docs/threads.md § Step 3) started by a request shares
// THAT request's module state: it reads the global this request just wrote
function zts_shared(int $x): int { global $zts_g; return $x * 3 + (int) $zts_g['a']; }

// n|calls|a|list|count|items|K|s|f|R|helper|boom:rev|api|thread
function work(int $n, callable $boom): string {
    global $zts_g, $zts_box;
    static $calls = 0;
    $calls++;
    $zts_g['a'] += $n;
    $zts_g['list'][] = $n;
    _Box::$count += 1;
    $k = $zts_box->add($n);
    $s = str_repeat(chr(97 + $n % 26), 3) . ":" . json_encode(['n' => $n]);
    try {
        if ($n % 2) throw new RuntimeException("odd $n");
        $s .= "!even";
    } catch (RuntimeException $e) {
        $s .= "!" . $e->getMessage();
    }
    $f = fn(int $x): int => $x * 2;
    if (!defined('ZTS_R')) define('ZTS_R', $n);
    $h = zts_helper($n);
    // php's engine called through a callable -- one that throws, and one of
    // php's own functions that does not: after each the module reads
    // EG(exception) at the offset THIS thread measured, and
    // MCPHP_ZTS_EGX_WRONG makes that offset wrong until the thread measures
    // it (a wrong one reads a pending exception where there is none)
    $rev = 'strrev';
    try { $boom($n); $b = "none"; } catch (LogicException $x) { $b = (string) $x->getMessage(); }
    $b = $b . ":" . (string) $rev("z$n");
    $tv = (int) mcphp_thread_join(mcphp_thread_start(fn(int $x): int => zts_shared($x), $n));
    return $n . "|" . $calls . "|" . $zts_g['a'] . "|" . count($zts_g['list']) . "|" . _Box::$count
        . "|" . $k . "|" . ZTS_K . "|" . $s . "|" . $f($n) . "|" . ZTS_R . "|" . $h . "|" . $b . "|" . $tv . "|" . mcphp_thread();
}

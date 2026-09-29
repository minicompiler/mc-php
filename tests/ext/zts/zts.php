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

// n|calls|a|list|count|items|K|s|f|R|helper|thread
function work(int $n): string {
    global $zts_g, $zts_box;
    static $calls = 0;
    $calls++;
    $zts_g['a'] += $n;
    $zts_g['list'][] = $n;
    _Box::$count += 1;
    $k = $zts_box->add($n);
    $s = str_repeat(chr(97 + $n % 26), 3) . ":" . json_encode(['n' => $n]);
    // the arrow function comes before the try on purpose: mc-php's arrow
    // function captures every enclosing variable, and a $e the catch never
    // assigned is an unset slot (reported separately; not a ZTS defect).
    $f = fn(int $x): int => $x * 2;
    try {
        if ($n % 2) throw new RuntimeException("odd $n");
        $s .= "!even";
    } catch (RuntimeException $e) {
        $s .= "!" . $e->getMessage();
    }
    if (!defined('ZTS_R')) define('ZTS_R', $n);
    $h = zts_helper($n);
    return $n . "|" . $calls . "|" . $zts_g['a'] . "|" . count($zts_g['list']) . "|" . _Box::$count
        . "|" . $k . "|" . ZTS_K . "|" . $s . "|" . $f($n) . "|" . ZTS_R . "|" . $h . "|" . mcphp_thread();
}

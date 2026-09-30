<?php
// tests/frankenphp.sh: php callables on threads of their own (threads step
// 3b), two per request. The first names the request's own class and
// function and echoes -- its output lands in this response at its join --
// and the second returns an array. Without opcache the start is refused, by
// name, and that is the answer.
class FpPt {
    public function __construct(public int $x, public int $y) {}
    public function sum(): int { return $this->x + $this->y; }
}
function fp_helper(int $x): int { return $x * 2; }
$n = (int) ($_GET['n'] ?? 0);
try {
    $a = zts_pstart(function (int $n): int { echo "w", $n, ";"; return (new FpPt($n, fp_helper($n)))->sum(); }, $n);
    $b = zts_pstart(fn(int $n): array => [$n, str_repeat("q", $n % 5)], $n + 1);
    $ra = zts_pjoin($a);
    $rb = zts_pjoin($b);
    echo "|", $ra, "|", json_encode($rb), "\n";
} catch (Error $e) {
    $m = $e->getMessage();
    $p = strpos($m, "; not cached: ");
    echo "E:", $p === false ? $m : substr($m, 0, $p), "\n";
}

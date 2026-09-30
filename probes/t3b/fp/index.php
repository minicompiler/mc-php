<?php
// probes/t3b under FrankenPHP: each request starts workers that run a closure
// naming this request's function and class (?m=mode&n=workers&l=loops)
final class Pt {
    public function __construct(public int $x, public int $y) {}
    public function sum(): int { return $this->x + $this->y; }
}
function helper(int $i): int { return $i * 3; }
$m = (int) ($_GET['m'] ?? 3); $n = (int) ($_GET['n'] ?? 2); $l = (int) ($_GET['l'] ?? 20);
$named = function (int $i): string {
    $p = new Pt($i, helper($i));
    $s = 0; for ($k = 0; $k < 500; $k++) { $s += $p->sum() + $k % 5; }
    return "named " . $p->sum() . " " . $s;
};
$want = function (int $i): string { $s = 0; for ($k = 0; $k < 500; $k++) $s += $i * 4 + $k % 5; return "named " . ($i * 4) . " " . $s; };
$r = t3b_run($named, $m, $n, $l);
$bad = 0; foreach ($r as $i => $v) if ($v !== $want($i)) $bad++;
echo $bad ? "BAD " . implode(" | ", $r) : "ok", "\n";

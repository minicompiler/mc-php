<?php
// probes/t3b: a php callable run on a worker thread in a php context of its
// own, naming a function and a class the starting request declared.
// argv: mode n loops
final class Pt {
    public static int $made = 0;
    public function __construct(public int $x, public int $y) { self::$made++; }
    public function sum(): int { return $this->x + $this->y; }
}
function helper(int $i): int { static $calls = 0; $calls++; return $i * 3; }
$mode = (int) ($argv[1] ?? 0); $n = (int) ($argv[2] ?? 4); $loops = (int) ($argv[3] ?? 0);
$self = function (int $i): string { $t = 0; for ($k = 0; $k < 2000; $k++) $t += $k % 7; return "self $i $t"; };
$named = function (int $i): string {
    $p = new Pt($i, helper($i));
    $s = 0; for ($k = 0; $k < 2000; $k++) { $s += $p->sum() + strlen(str_repeat("x", $k % 5)); }
    return "named " . $p->sum() . " " . $s;
};
$want = function (int $i): string { $p = [$i, $i * 3]; $s = 0; for ($k = 0; $k < 2000; $k++) $s += $p[0] + $p[1] + $k % 5; return "named " . ($p[0] + $p[1]) . " " . $s; };
$r1 = t3b_run($self, $mode, $n, $loops);
$r2 = t3b_run($named, $mode, $n, $loops);
$bad1 = 0; foreach ($r1 as $i => $v) if ($v !== $self($i)) { $bad1++; if ($bad1 < 3) echo "  self[$i]: $v\n"; }
$bad2 = 0; foreach ($r2 as $i => $v) if ($v !== $want($i)) { $bad2++; if ($bad2 < 3) echo "  named[$i]: $v\n"; }
echo "mode $mode n $n loops $loops: self ", count($r1) - $bad1, "/", count($r1), " named ", count($r2) - $bad2, "/", count($r2), "\n";
if (($argv[4] ?? "") === "cost") {
    $empty = function (int $i): int { return $i; };
    printf("cost mode %d: empty %.1f us, self %.1f us, named %.1f us per start\n", $mode, t3b_cost($empty, $mode, 300), t3b_cost($self, $mode, 300), t3b_cost($named, $mode, 300));
    $t = hrtime(true); for ($k = 0; $k < 300; $k++) $self($k); printf("  the self closure on the starting thread: %.1f us per call\n", (hrtime(true) - $t) / 300 / 1000);
}

<?php
// tests/ext.sh step 20c (threads.php says what): PHP callables on threads of
// their own, a ZTS php with opcache on, one request, graded against its
// recording. Without opcache the first start is refused, by name.
class Pt {
    public function __construct(public int $x, public int $y) {}
    public function sum(): int { return $this->x + $this->y; }
}
function helper(int $x): int { return $x * 2; }
class Acc {
    public array $log = [];
    public function __construct(public int $base) {}
    public function adder(): Closure { return function (int $x): int { $this->log[] = $x; return $this->base + $x + count($this->log); }; }
}
function err(Closure $f): string {
    try { $f(); return "no error"; }
    catch (Error $e) { return get_class($e) . ": " . $e->getMessage(); }
}
function counter(): int { static $n = 0; return ++$n; }

try { echo "a closure: ", th\prun0(fn() => 42), "\n"; }
catch (Error $e) { $m = $e->getMessage(); echo substr($m, 0, strpos($m, "; not cached: ")), "\n"; exit(0); }
echo "arguments: ", th\prun2(fn($a, $b) => $a . $b, "left", 7), "\n";
echo "the request's code: ", th\prun1(function (int $i): int { $p = new Pt($i, helper($i)); return $p->sum(); }, 5), "\n";
$c = 7;
echo "a capture: ", th\prun0(function () use ($c) { return $c * 3; }), "\n";
$a = new Acc(100);
echo "\$this, copied: ", th\prun1($a->adder(), 5), ", here still ", count($a->log), "\n";
echo "\$this refused: ", err(fn() => th\prun0(Closure::bind(function () { return 1; }, new ArrayObject([])))), "\n";
echo "a string: ", th\prun1(fn(int $n) => str_repeat("ab", $n), 3), "\n";
echo "an array: ", json_encode(th\prun1(fn(int $n) => [$n, "s$n", ["k" => [$n, $n + 1]]], 9)), "\n";
$o = new stdClass;
$o->me = $o;
$o->n = 3;
$r = th\prun1(fn($p) => [$p, $p, new Pt(1, 2)], $o);
echo "objects: ", $r[0] === $r[1] ? "one" : "two", ", ", $r[0]->me === $r[0] ? "a cycle" : "no cycle", ", ", $r[0]->n, ", ", get_class($r[2]), " ", $r[2]->sum(), "\n";
echo "an argument refused: ", err(fn() => th\prun1(fn($x) => 1, new DateTime("2020-01-01"))), "\n";
echo "a closure argument refused: ", err(fn() => th\prun1(fn($x) => 1, fn() => 2)), "\n";
echo "a result refused: ", err(fn() => th\prun0(fn() => new ArrayObject([]))), "\n";
try { th\prun0(function () { throw new DomainException("boom", 7); }); }
catch (DomainException $e) { echo "rethrown: ", get_class($e), " ", $e->getMessage(), " ", $e->getCode(), "\n"; }
$t = th\pstart1(fn(int $x) => declared_late($x), 2);
if (true) { function declared_late(int $x): int { return $x * 10; } }
echo "declared after the start: here ", declared_late(3), ", there ", err(fn() => th\pjoin($t)), "\n";
// a class autoloaded after the start: the worker's request registers no
// autoloader and has only the tables as they were at the start, so php's own
// "Class not found" Error comes back from the join -- not a crash
spl_autoload_register(function (string $c): void { if ($c === "LateAuto") require __DIR__ . "/late.php"; });
$t = th\pstart1(fn(int $x) => (new LateAuto($x))->v, 4);
echo "autoloaded after the start: here ", (new LateAuto(5))->v, ", there ", err(fn() => th\pjoin($t)), "\n";
counter();
counter();
echo "statics: here ", counter(), ", there ", th\prun0(fn() => counter() . counter()), ", here ", counter(), "\n";
echo "a module global, a compiled worker: ", th\gcompiled("compiled"), "\n";
echo "a module global, a php worker: ", th\prun0(fn() => th\gget() . ", then " . th\gset("php")), "\n";
echo "a module global afterwards: ", th\gget(), "\n";
// a fatal error unwinds to php's zend_try; on Windows that unwind is SEH's and
// cannot cross the module's frames (docs/threads.md § 3b), so it is not made
if (PHP_OS_FAMILY === "Windows") echo "a fatal error: not on Windows\n";
else {
    $f = err(fn() => th\prun0(function () {
        ini_set("display_errors", "0");
        ini_set("log_errors", "0");
        ini_set("memory_limit", "4M");
        return str_repeat("x", 8 << 20);
    }));
    echo "a fatal error: ", substr($f, 0, strpos($f, " (tried")), "\n";
}
echo "exit(): ", var_export(th\prun0(function () { exit(3); }), true), "\n";
$ts = [];
for ($i = 0; $i < 8; $i++) {
    $ts[] = th\pstart1(function (int $i): int { for ($k = 0; $k < 3; $k++) echo "w$i.$k "; echo "\n"; return $i; }, $i);
}
echo "8 workers echo, joined in reverse:\n";
$s = 0;
foreach (array_reverse($ts) as $t) $s += th\pjoin($t);
echo "their sum: $s\n";
th\pdetach(th\pstart1(function (string $x) { echo "the detached php thread says $x\n"; }, "goodbye"));
// and one neither joined nor detached, which ends on a throwable: the end of
// the request waits for it and reports it as a warning (php_thr_endall's
// php-thread branch, which mc before 1.3.1 miscompiled with opt = 1)
th\pstart1(function (string $m): int { throw new LogicException($m); }, "never joined");
// last of the starts: once a class that extends one of php's own is declared,
// a Windows php refuses every start (docs/threads.md § 3b, opcache links
// such a class at run time, in the request's memory)
if (true) {
    class Ao extends ArrayObject { public function f(): Closure { return fn() => 1; } }
}
echo "\$this of a class extending php's own: ", err(fn() => th\prun0((new Ao)->f())), "\n";
echo "the script's last line\n";

<?php
// tests/ext.sh step 18: a module that PUBLISHES classes (lib/php_ext.mc
// § published classes) -- typed, nullable and private properties with their
// defaults, a constructor with defaults, methods that read and write $this,
// a final class, one made by the module and one by php, instanceof, and
// php's own errors for a private member. check.php runs it loaded and
// interpreted and the two must agree byte for byte.
namespace pc;
final class Box {
    public int $n = 0;
    public ?string $label = null;
    private int $secret = 7;
    public function __construct(int $n = 1, string $label = "box") { $this->n = $n; $this->label = $label; }
    public function add(int $k): int { $this->n = $this->n + $k; return $this->n; }
    public function peek(): int { return $this->secret + $this->n; }
    public function describe(): string { return $this->label . ":" . $this->n; }
    private function hidden(): int { return 1; }
}
class Pair { public $a; public $b = 2; }
function make(int $n): Box { $b = new Box($n, "made"); $b->add(1); return $b; }
function bump(Box $b): int { return $b->add(10); }
function kind(object $o): string { return get_class($o) . ($o instanceof Box ? " box" : ""); }
// a __destruct that is the module's own method: an object the module makes
// and drops runs it while the module's call is being left, as a call nested
// in that leave. With the call already torn down, a destructor that allocated
// (the string below) wrote into the call's freed memory and the next call
// found php's heap corrupted; phx_leave_slow now releases what the call held
// with the call still open (phx_esc_open). The moment it runs is the call's
// end, not php's (docs/php-extension.md § What differs), so it prints nothing.
class Res {
    public int $n = 0;
    public function __destruct() { $s = "d" . $this->n; }
    public function touch(): int { $this->n = $this->n + 1; return $this->n; }
}
function _use(): int { $r = new Res(); for ($i = 0; $i < 3; $i++) { $r->touch(); } return $r->n; }
function churn(): int { return _use() + _use(); }
function _bare(): void { $r = new Res(); }
function plain(): int { _bare(); return 1; }

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

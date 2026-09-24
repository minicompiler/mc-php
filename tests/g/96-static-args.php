<?php
// A static method WITH parameters. Every method -- static too -- takes the
// receiver first, because every caller in the runtime passes it first; a
// static one declared without the slot read its first argument out of it
// and `C::f($x)` said "Too few arguments" (found by examples/decimal).
class Num {
    public static function add(int $a, int $b): int { return $a + $b; }
    public static function twice(string $s): string { return self::cat($s, $s); }
    private static function cat(string $a, string $b): string { return $a . $b; }
    public static function make(int $n): static { return new static($n); }
    public function __construct(public int $n) {}
    public static function __callStatic(string $name, array $args): string {
        return $name . ":" . implode(",", $args);
    }
}
class Sub extends Num {
    public static function add(int $a, int $b): int { return parent::add($a, $b) * 10; }
}
echo Num::add(2, 3), "\n";
echo Sub::add(2, 3), "\n";
echo Num::twice("ab"), "\n";
echo get_class(Sub::make(7)), " ", Sub::make(7)->n, "\n";
echo Num::nothing(1, 2, 3), "\n";
$o = new Num(1);
echo $o->add(4, 5), "\n";
function via(int $x): int { return Num::add($x, $x); }
echo via(21), "\n";

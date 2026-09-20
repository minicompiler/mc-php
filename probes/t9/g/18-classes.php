<?php
interface Shape { public function area(): float; }
abstract class Base implements Shape {
    protected string $name;
    public const KIND = "shape";
    public static int $count = 0;
    public function __construct(string $n) { $this->name = $n; self::$count++; }
    public function getName(): string { return $this->name; }
    abstract public function area(): float;
    public function __toString(): string { return $this->name . "(" . $this->area() . ")"; }
}
class Rect extends Base {
    public function __construct(private float $w, private float $h) { parent::__construct("rect"); }
    public function area(): float { return $this->w * $this->h; }
}
class Circle extends Base {
    public function __construct(public float $r) { parent::__construct("circle"); }
    public function area(): float { return 3.0 * $this->r * $this->r; }
}
$shapes = [new Rect(2.0, 3.0), new Circle(1.5)];
foreach ($shapes as $s) {
    echo $s->getName(), " ", $s->area(), " ", $s, "\n";
    var_dump($s instanceof Shape, $s instanceof Rect);
}
echo Base::$count, " ", Base::KIND, " ", Rect::class, "\n";
$r = new Rect(1.0, 1.0);
$c = clone $r;
var_dump($r == $c, $r === $c, get_class($c));

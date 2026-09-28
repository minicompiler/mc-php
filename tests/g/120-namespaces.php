<?php
// Namespaces, php's rules (src/ns.mc): a declaration is `ns\name`; a class
// name has no fallback and a function or a constant falls back to the global
// one; `use` imports a class, a namespace, a function or a constant, alone,
// aliased or grouped; `namespace\x` is relative to the file's namespace; and a
// second `namespace` statement starts over, imports and all.
namespace app\util;

const SCALE = 10;
interface Shape { public function area(): int; }
class Box implements Shape {
    public ?\Throwable $last = null;
    public function __construct(public int $w = 2, public int $h = 3) {}
    public function area(): int { return $this->w * $this->h * SCALE; }
    public static function unit(): static { return new static(1, 1); }
}
function twice(int $x): int { return $x * 2; }
function strlen(string $s): int { return 100 + \strlen($s); }   // shadows the global one here
class Oops extends \RuntimeException {}

echo twice(21), " ", \app\util\twice(1), " ", namespace\twice(2), " ", strlen("abc"), " ", \strlen("abc"), "\n";
echo SCALE, " ", \app\util\SCALE, " ", PHP_INT_SIZE, " ", __NAMESPACE__, "\n";
$b = new Box();
echo get_class($b), " ", Box::class, " ", $b->area(), " ", Box::unit()->area(), " ", var_export($b instanceof Shape, true), "\n";
try { throw new Oops("bad"); } catch (\RuntimeException $e) { echo get_class($e), ": ", $e->getMessage(), "\n"; }
echo abs(-5), " ", str_repeat("=", 3), "\n";                       // global functions, the fallback

namespace app;

use app\util\Box;
use app\util\Box as Crate, app\util\Shape;
use function app\util\twice;
use function app\util\twice as dbl;
use const app\util\SCALE;
use app\util\{Oops, Shape as Form};
use app\util;

$c = new Crate(4, 5);
echo get_class($c), " ", Crate::class, " ", Form::class, " ", $c->area(), " ", twice(4), " ", dbl(5), " ", SCALE, "\n";
echo util\twice(7), " ", util\SCALE, " ", get_class(new util\Box()), " ", var_export($c instanceof Shape, true), "\n";
try { throw new Oops("again"); } catch (Oops $e) { echo get_class($e), ": ", $e->getMessage(), "\n"; }
function thrice(int $x): int { return $x * 3; }
echo \app\thrice(2), " ", namespace\thrice(3), " ", thrice(4), " ", twice(4), " ", __NAMESPACE__, "\n";

<?php
// The TestCase both worlds compile (D8). PHPUnit is not installed on this
// machine (`php -r 'echo class_exists("PHPUnit\\Framework\\TestCase");'`
// answers nothing), so the php side runs the SAME test file against this
// shim; with the real phpunit on the include path this declaration has to
// be guarded, which is the `class_exists` below -- with the real phpunit
// loaded this file is a no-op and the test runs against phpunit's own
// TestCase, which is what D8 asks for.
//
// D6: nothing here enumerates methods. The runner names them (run.php).
namespace PHPUnit\Framework;

// The real phpunit wins: `false` keeps the autoloader out of it, so this asks
// "is it already loaded", not "can it be loaded".
//
// The guard is a CONDITIONAL DECLARATION and not an early `return`, which is
// what it was until T10. php hoists an unconditional class declaration, so
// `class_exists` above the declaration in the same file was already TRUE and
// the file returned at its first statement -- correct under php only because
// the hoist had already run. A class declared inside an `if` is NOT hoisted
// and is declared when the branch runs, which is php's own idiom for exactly
// this, and it needs no top-level `return` in an included file: php ends the
// include there and the caller continues, and an mc-php include is INLINED,
// so it cannot express that (it is refused by name).
//
// And the lookup AUTOLOADS. With `false` it asked only what is already
// loaded, so a real PHPUnit run that has registered its autoloader but not
// yet touched `TestCase` answered "not there" and got the shim -- the one
// case the guard exists to lose. mc-php has no autoloader, so its answer is
// the same either way and the shim still wins there.
if (!class_exists('PHPUnit\Framework\TestCase')) {

class AssertionFailed extends \Exception {}

abstract class TestCase
{
    public function assertSame($want, $got): void
    {
        if ($want === $got) {
            return;
        }
        throw new AssertionFailed(
            "assertSame failed: want " . \var_export($want, true)
            . ", got " . \var_export($got, true)
        );
    }

    public function assertTrue($got): void { $this->assertSame(true, $got); }
    public function assertFalse($got): void { $this->assertSame(false, $got); }
    public function assertEquals($want, $got): void { $this->assertSame($want, $got); }
    public function assertCount(int $n, $got): void { $this->assertSame($n, \count($got)); }
}

}

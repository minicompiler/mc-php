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
if (class_exists('PHPUnit\Framework\TestCase', false)) {
    return;
}

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

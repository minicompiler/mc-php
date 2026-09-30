<?php
// tests/ext/threads/php.php: the class its autoloader loads after a php
// thread started, which that thread must not see.
final class LateAuto {
    public function __construct(public int $v) {}
}

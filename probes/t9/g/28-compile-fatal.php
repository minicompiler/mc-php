<?php
// a php COMPILE-TIME Fatal error: php reports it while parsing, on stdout,
// and exits 255 -- so mc-php does too, from the compiler.
class T {
    static public public function foo() {}
}
echo "not reached\n";

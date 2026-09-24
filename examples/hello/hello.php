<?php
// hello -- the first mc-php extension.
//
// It is ordinary PHP and nothing else. `php hello.php` defines these seven
// functions and does nothing; `mc-php build` beside mcphp.toml turns the same
// file into hello.so, which `php -d extension=hello.so` loads. Neither tool
// reads anything the other does not.

function hello_addone(int $n): int { return $n + 1; }

function hello_greet(string $who): string { return "hi " . $who; }

function hello_half(float $x): float { return $x / 2.0; }

function hello_not(bool $b): bool { return !$b; }

function hello_say(string $s): void { echo "[$s]\n"; }

function hello_sum(int $a, int $b, int $c): int { return $a + $b + $c; }

function hello_zero(): string { return "no arguments at all"; }

function hello_pos(int $n): int {
    if ($n < 0) throw new InvalidArgumentException("negative: $n");
    return $n;
}

<?php
// #[Extern] on the program road (src/extern.mc): C functions of the C library
// declared in php, graded by tests/fixtures.sh against 08-extern.out -- php
// reads the attribute as inert and the empty bodies as the functions, so this
// is not a differential. On Windows it is refused by name (08-extern.win.*).
#[Extern('c')] function atoi(string $s): int {}
#[Extern('c')] function abs(int $n): int {}
#[Extern('c')] function strlen(string $s): Ptr {}
#[Extern('c')] function strerror(int $e): string {}
#[Extern('c')] function malloc(Ptr $n): Ptr {}
#[Extern('c')] function free(Ptr $p): void {}
#[Extern('c')] function strcat(Ptr $d, string $s): string {}
// one item of a list, fully qualified: still #[Extern]
#[Pure, \Extern('c')] function labs(Ptr $n): Ptr {}
// `name:` is the C symbol, so php may call it by another name; two aliases
// of one symbol are one C declaration (tests/fixtures.sh counts it)
#[Extern('c', name: 'atoi')] function c_atoi(string $s): int;   // `;` for a body is not php, `{}` is
#[Extern('c', name: 'strtol')] function dec(string $s, Ptr $end, int $base): Ptr {}
#[Extern('c', name: 'strtol')] function hex(string $s, Ptr $end, int $base): Ptr {}
#[Extern('c', variadic: 2)] function snprintf(Ptr $b, Ptr $n, string $f, mixed $a, mixed $c): int {}
echo atoi("-42"), " ", abs(-7), " ", strlen("hello"), " ", strerror(2), "\n";
// a C int is sign-extended from bit 31, whatever the callee left above it
echo atoi("-1"), " ", atoi("2147483647"), " ", labs(-5), "\n";
echo c_atoi("-9"), " ", dec("42", 0, 10), " ", hex("ff", 0, 16), "\n";
$b = malloc(64);
$n = snprintf($b, 64, "%d-%s", 42, "x");
echo $n, " ", strcat($b, ""), "\n";
free($b);
try { snprintf(0, 0, "%d", [1], 0); } catch (TypeError $e) { echo get_class($e), ": ", $e->getMessage(), "\n"; }

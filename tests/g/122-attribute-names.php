<?php
// An attribute is inert to php, and to mc-php every attribute but #[Extern]
// is too (src/extern.mc). Which one is #[Extern] is decided by the NAME at
// the start of an item of the list -- not by the word appearing anywhere in
// it -- and the list is split at the commas outside parentheses and strings.
#[Doc("Extern")] function f(): int { return 7; }
#[Doc("a, ] Extern"), Pure] function g(int $n): int { return $n * 2; }
#[ExternLike('c')] function h(): string { return "h"; }
class K { #[Doc("Extern")] public function m(): int { return 1; } }
echo f(), " ", g(21), " ", h(), " ", (new K)->m(), "\n";

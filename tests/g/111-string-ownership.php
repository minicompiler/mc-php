<?php
// Who owns a string (lib/php_rt.mc, src/rc.mc): the shapes that decide when a
// string may be written in place and when it must be copied, and when one
// may be freed. On the program road nothing is counted; compiled with
// MCPHP_RC=check every string is, and one freed under a live name reads back
// as a length no string has -- so this file is the same bytes as php's in
// both builds, or it is not.
function grow(int $n): string {
    $s = "";
    for ($i = 0; $i < $n; $i++) { $s .= chr(97 + $i % 26); }
    return $s;
}

// a second name on the same string: the append must not reach it
function alias(): string {
    $a = str_repeat("a", 3);
    $b = $a;
    $a .= "b";
    $a[0] = "z";
    return "$a/$b";
}

// appending a string to itself, and a chain that starts with it
function self_cat(string $p): string {
    $s = $p . "";
    $s .= $s;
    $s = $s . $s . "|";
    $s = $s . "<" . $p . ">";
    return $s;
}

// a parameter assigned in the body is the function's own copy
function param(string $p): string {
    $p .= "!";
    $p[0] = strtoupper($p[0]);
    return $p;
}

// the argument handed straight back, and one that is not
function same(string $p): string { return $p; }
function keep_last(string $a, string $b): string { $t = $a; $t = $b; return $t; }

// strings kept by an array, a closure and a static outlive the statements
// that built them
function keepers(): string {
    $parts = [];
    for ($i = 0; $i < 4; $i++) { $parts[] = str_repeat((string) $i, $i + 1); }
    $key = "k" . count($parts);
    $map = [$key => implode("-", $parts)];
    $f = function () use ($key, $map) { return $key . "=" . $map[$key]; };
    return $f();
}

function counter(string $tag): string {
    static $all = "";
    $all .= $tag;
    return $all;
}

// an exception in the middle of a loop that builds strings
function thrower(int $at): string {
    $acc = "";
    for ($i = 0; $i < 5; $i++) {
        $acc .= "[" . $i . "]";
        if ($i === $at) { throw new RuntimeException("stopped at $i with $acc"); }
    }
    return $acc;
}

echo strlen(grow(1000)), " ", substr(grow(1000), 990), "\n";
echo alias(), "\n";
echo self_cat("ab"), "\n";
$x = "arg";
echo param($x), " ", $x, "\n";
echo same($x), same("lit"), keep_last("one", "two"), "\n";
echo keepers(), "\n";
echo counter("a"), counter("b"), counter("c"), "\n";
try { echo thrower(2), "\n"; } catch (RuntimeException $e) { echo $e->getMessage(), "\n"; }
echo thrower(9), "\n";
$t = "q";
for ($i = 0; $i < 3; $i++) { $u = $t; $t .= $i; echo $u, ">", $t, " "; }
echo "\n";

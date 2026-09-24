<?php
// The string lowerings batch E made native (docs/plan.md § 7): strspn and
// strcspn over native strings with a literal or a computed set, the trim
// family with a mask (ranges included), $s[$i] === 'c' compared in place,
// (int) substr(...) read without building the substring, strlen loaded in
// place, and str_replace with a one-byte search. Every answer is php's.
$s = "0012.3400";
$set = "0123456789";
$offs = [0, 2, 4, -3, 20, -20];
foreach ($offs as $o) {
    echo strspn($s, '0123456789', $o), " ", strspn($s, $set, $o), " ", strcspn($s, '.', $o), "\n";
}
$os = [0, 1, -4, 2, 5];
$ls = [3, -2, 2, 0, 100];
for ($k = 0; $k < 5; $k++) {
    echo strspn($s, '0123456789', $os[$k], $ls[$k]), " ", strcspn($s, '.', $os[$k], $ls[$k]), "\n";
}
echo strspn("", '0123456789'), strcspn("", "x"), "\n";

$t = "  xxhello worldxx  ";
var_dump(trim($t), ltrim($t), rtrim($t), trim($t, ' x'), ltrim($t, ' x'), rtrim($t, ' x'));
var_dump(trim("abcXYZcba", "a..c"), ltrim("0007", '0'), ltrim("000", '0'), rtrim("1.500", '0'), chop("q\n"));
$mask = "a..z";
var_dump(trim("hello, World", $mask), trim("", "x"), ltrim("nothing", "z"));

$w = "-12.5";
var_dump($w[0] === '-', $w[0] !== '-', '.' === $w[3], $w[1] === '-', $w[-1] === '5', $w[40] === '5', $w[-40] !== '5');
$n = 0;
for ($i = 0; $i < strlen($w); $i++) { if ($w[$i] === '.') { $n = $i; } }
echo $n, " ", strlen($w), " ", strlen(""), "\n";

$d = "  -123abc 45";
var_dump((int) substr($d, 0), (int) substr($d, 2, 4), (int) substr($d, -2), (int) substr($d, 3, 0),
         (int) substr($d, 100), (int) substr($d, -100, 5), (int) substr("+9", 0), (int) substr("0012", 1, 2));

var_dump(str_replace('.', '', "1.2.3."), str_replace('-', '', "123"), str_replace('.', ',', "1.5"),
         str_replace('.', '::', "a.b"), str_replace('ab', 'X', "abcab"), str_replace('a', 'bb', "aaa"),
         str_replace('', 'x', "abc"), str_replace('.', '', ""));
var_dump(strpos("a.b", "."), strpos("abc", "."), strpos("a.b.", ".", 2), strpos("abc", "bc"), strpos("abc", ""));
// `??` reads a string offset the way isset does: absent is null, no warning
var_dump($w[1] ?? "d", $w[99] ?? "d", $w[-99] ?? "d");

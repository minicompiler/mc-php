<?php
// str_replace's whole signature: string|array for search, replace and subject.
// An array search used to be a wrong answer -- the array converted to the
// text "Array" and that searched for (docs/plan.md § 7).
var_dump(str_replace(['-', '.'], '', '-012.30'));
var_dump(str_replace(['a', 'b'], ['1', '2'], 'aabbc'));
var_dump(str_replace(['a', '', 'b'], ['1', '2'], ['x' => 'aab', 5 => 'bbq', 7 => 12], $c), $c);
var_dump(str_replace('o', '0', ['foo', 'bar', 'boo'], $n), $n);
var_dump(str_replace(['a', 'aa'], ['aa', 'b'], 'aaa'));
var_dump(str_replace([], 'x', 'abc'));
$search = ['cat', 'dog'];
$subject = 'cat and dog';
var_dump(str_replace($search, 'pet', $subject));
try {
    str_replace('a', ['b'], 'abc');
} catch (TypeError $e) {
    echo $e->getMessage(), "\n";
}

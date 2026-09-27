<?php
// The semantics comment counts only as a line comment of its own: the same
// bytes in a string, a heredoc, a nowdoc or a block comment are text, so this
// file keeps the default, C's rules -- the element product below wraps.
echo "// mc-php: semantics=php\n";
echo '// mc-php: semantics=bad', "\n";
$h = <<<EOT
    // mc-php: semantics=php
    EOT;
$n = <<<'EOT'
// mc-php: semantics=bad
EOT;
/* // mc-php: semantics=bad */
echo $h, "\n", $n, "\n";
function el(int $n): int {
    $x = array_fill(0, 2, 0);
    $x[0] = $n;
    $x[1] = $x[0] * 2;
    return $x[1];
}
echo el(PHP_INT_MAX), "\n";

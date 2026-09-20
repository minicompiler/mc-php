<?php
echo strlen("hello"), "\n";
echo str_repeat("ab", 3), "\n";
echo substr("abcdef", 2, 3), "|", substr("abcdef", -2), "\n";
var_dump(strpos("hello", "ll"));
var_dump(strpos("hello", "z"));
var_dump(strpos("hello", "z") === false);
echo str_replace("a", "X", "banana"), "\n";
echo strtoupper("mc"), strtolower("PHP"), ucfirst("php"), "\n";
echo trim("  pad  "), "|", str_pad("7", 3, "0", STR_PAD_LEFT), "\n";
echo strrev("abc"), chr(65), ord("A"), "\n";
var_dump(str_contains("abc", "b"), str_starts_with("abc", "a"), str_ends_with("abc", "c"));
var_dump(strcmp("a", "b"));

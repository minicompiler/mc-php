<?php
// Out-of-range offsets, empty needles and separators, zero lengths and steps:
// php's ValueError, its exact message, or the warning range() gives. Found
// while fixing PR #65's defects.
function t($f) { try { var_dump($f()); } catch (Throwable $e) { echo get_class($e), ": ", $e->getMessage(), "\n"; } }
t(fn() => strpos("abc", "b", 9)); t(fn() => strpos("abc", "b", -9)); t(fn() => strpos("abc", "c", -1)); t(fn() => strpos("abc", "b", 3));
t(fn() => stripos("abc", "B", 9)); t(fn() => strrpos("abc", "b", 9)); t(fn() => strrpos("abc", "b", -9)); t(fn() => strripos("abc", "b", -4));
t(fn() => substr_count("abcb", "b", 9)); t(fn() => substr_count("abcb", "b", 1, 9));
t(fn() => strpos("abc", "")); t(fn() => strpos("abc", "", 3)); t(fn() => strrpos("abc", "", -1));
t(fn() => str_contains("abc", "")); t(fn() => substr_compare("abc", "b", 9));
t(fn() => strspn("abc", "a", 9)); t(fn() => strcspn("abc", "a", 1, -9));
t(fn() => str_pad("a", 5, "")); t(fn() => explode("", "a")); t(fn() => str_split("a", 0)); t(fn() => array_fill(0, -1, 1));
t(fn() => range(1, 2, 0)); t(fn() => array_chunk([1], 0)); t(fn() => str_repeat("a", -1)); t(fn() => wordwrap("abc", 0, "", true));
t(fn() => substr_count("abc", "")); t(fn() => substr_compare("abc", "b", 0, -1)); t(fn() => str_pad("a", 5, " ", 9));
t(fn() => explode("", "a")); t(fn() => wordwrap("abc", 0, "x", true)); t(fn() => wordwrap("abc", 2, ""));
t(fn() => str_split("a", 0)); t(fn() => range(1, 2, 0)); t(fn() => array_chunk([1], 0)); t(fn() => substr_count("abcb", "b", -9));
t(fn() => substr_count("abcb", "b", 1, -9)); t(fn() => strrpos("abc", "b", -4)); t(fn() => strrpos("abc", "b", -3)); t(fn() => strpos("abc", "b", -3));
t(fn() => str_pad("a", 5, ""));
function tj($f) { try { echo json_encode($f()), "\n"; } catch (Throwable $e) { echo get_class($e), ": ", $e->getMessage(), "\n"; } }
t(fn() => range(1, 2, 5)); t(fn() => range(1, 2, -1)); t(fn() => range(5, 1, 2)); t(fn() => range(1, 2, 0.0)); t(fn() => range(1, 3, 1.5)); t(fn() => range('a', 'c', 0));
t(fn() => range(1, 1, 0)); t(fn() => range(0, 1, 0.25)); t(fn() => range("a","c",1.5)); t(fn() => range("ab","c")); t(fn() => range("", 2)); t(fn() => range("1", "3")); t(fn() => range("a", 3));
t(fn() => range(0, 2000000000)); t(fn() => range(0.0, 2e9, 1.0)); t(fn() => range(10, 1)); t(fn() => range(1, 10, 3)); t(fn() => range(1.5, 4)); t(fn() => range('z', 'a', 5)); t(fn() => range("5", "1", 2)); t(fn() => range(1, INF)); t(fn() => range(0, 10, -2)); t(fn() => range(10, 0, -2));

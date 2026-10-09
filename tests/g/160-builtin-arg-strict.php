<?php
declare(strict_types=1);
// A builtin given an argument of the wrong type under strict_types: php's
// ZPP TypeError, its exact message and the builtin's own frame in the trace
// -- and the coercions strict mode still allows (int to float). (PR #65 defect 2)
function t($f) { try { $r = $f(); echo var_export($r, true), "\n"; } catch (Throwable $e) { echo get_class($e), ": ", $e->getMessage(), "\n", $e->getTraceAsString(), "\n"; } }
t(fn() => strtoupper(true));
t(fn() => strtoupper(1));
t(fn() => str_repeat("a", 2.0));
t(fn() => round(2));
t(fn() => strtoupper(null));
t(fn() => array_merge([1], 5));
t(fn() => str_pad("a", 5, null));
t(fn() => implode(",", null));
t(fn() => max("a", 5));
t(fn() => strlen([]));
t(fn() => count(5));
t(fn() => intdiv("4", 2));
t(fn() => str_contains("abc", 1));
t(fn() => abs("3"));
echo strtoupper("a"), "\n";
echo str_repeat("a", 2.0), "\n";

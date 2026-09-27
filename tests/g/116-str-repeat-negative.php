<?php
// str_repeat with a negative count is php's ValueError, and a count of 0 or a
// one-byte string once is the shared empty or one-byte string: the fast paths
// in php_str_repeat (lib/php_rt.mc) must not answer "" for a negative count.
// The echo's first argument is written before the throw, as php writes it.
function rep(string $s, int $n): string { return str_repeat($s, $n); }
function show(string $s, int $n): void {
    try { echo "[", rep($s, $n), "]\n"; } catch (ValueError $e) { echo get_class($e), ": ", $e->getMessage(), "\n"; }
}
show("0", -1);
show("ab", -2);
show("", -1);
show("x", 0);
show("x", 1);
show("ab", 0);
show("ab", 2);

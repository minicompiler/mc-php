<?php
class MyEx extends Exception {}
function risky(int $n): int {
    if ($n < 0) { throw new InvalidArgumentException("negative: " . $n); }
    if ($n == 0) { throw new MyEx("zero"); }
    return 100 / $n;
}
foreach ([4, 0, -1, 5] as $n) {
    try {
        echo "got ", risky($n), "\n";
    } catch (MyEx $e) {
        echo "myex: ", $e->getMessage(), "\n";
    } catch (InvalidArgumentException | RangeException $e) {
        echo get_class($e), ": ", $e->getMessage(), "\n";
    } finally {
        echo "  done ", $n, "\n";
    }
}
try { $x = 1 % 0; } catch (DivisionByZeroError $e) { echo "div: ", $e->getMessage(), "\n"; }
echo "end\n";
echo "done\n";

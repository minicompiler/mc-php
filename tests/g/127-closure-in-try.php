<?php
// A closure written inside a try block is a function of its own: the try
// is not around its body. mc-php compiled a throw in such a body as a break
// out of the enclosing try and refused the file ("break out of range").
function boom(string $m): int { throw new LogicException($m); }

// defined in a try, throwing from its body, caught by the try around the call
try {
    $f = function (int $x): int { throw new LogicException("m$x"); };
    echo $f(1), "\n";
} catch (LogicException $e) {
    echo "caught ", $e->getMessage(), "\n";
}

// the same inside a function, and a return from the try after the call
function r(string $m): string {
    try {
        $f = function (string $m): int { if ($m === "ok") return 1; throw new LogicException($m); };
        return "ret " . $f($m);
    } catch (LogicException $e) {
        return "caught " . $e->getMessage();
    }
}
echo r("ok"), "\n", r("bad"), "\n";

// in a loop, with the closure's own try and finally, inside a try with a
// finally of its own
for ($i = 0; $i < 3; $i++) {
    try {
        $g = function (int $x): string {
            try {
                if ($x == 1) throw new RuntimeException("inner $x");
                if ($x == 2) return "early $x";
                return "plain $x";
            } catch (RuntimeException $e) {
                return "inner caught: " . $e->getMessage();
            } finally {
                echo "inner finally $x\n";
            }
        };
        echo $g($i), "\n";
        if ($i == 2) boom("outer $i");
    } catch (LogicException $e) {
        echo "outer caught: ", $e->getMessage(), "\n";
    } finally {
        echo "outer finally $i\n";
    }
}

// an arrow function in a try, calling a function that throws
try {
    $h = fn(string $m): int => boom($m);
    $h("arrow");
} catch (LogicException $e) {
    echo "caught ", $e->getMessage(), "\n";
}

// a closure whose own try has only a finally, so its throw leaves the
// closure; the finally of a function around it must not be the closure's
// (mc-php named its flag in the closure: "unknown name")
function wrap(): string {
    try {
        $c = function (int $m): int { try { throw new LogicException("through $m"); } finally { echo "closure finally\n"; } };
        try { $c(3); } catch (LogicException $e) { return "wrap caught " . $e->getMessage(); }
        return "none";
    } finally {
        echo "wrap finally\n";
    }
}
echo wrap(), "\n";

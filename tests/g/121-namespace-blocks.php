<?php
// The braced form of a namespace: each block's declarations are its own, the
// global block is `namespace { }`, and a block's `use` imports end with it.
namespace shapes {
    const SIDES = 4;
    class Square { public function __construct(public int $s) {} public function area(): int { return $this->s * $this->s; } }
    function describe(Square $q): string { return __NAMESPACE__ . ": " . SIDES . " sides, area " . $q->area(); }
}

namespace report {
    use shapes\Square;
    use function shapes\describe;
    function line(int $s): string { return describe(new Square($s)) . " (" . __FUNCTION__ . ")"; }
}

namespace {
    require 'inc-ns.inc';
    echo incns\tag(), " [", __NAMESPACE__, "]\n";
    echo report\line(3), "\n";
    echo \shapes\describe(new shapes\Square(2)), "\n";
    echo shapes\SIDES, " ", get_class(new shapes\Square(1)), " [", __NAMESPACE__, "]\n";
    echo strlen("global"), "\n";
    // a global function called before its declaration in this block: the
    // forward scan puts it in the global namespace, not in `report`
    echo later(), " ", (new shapes\Square(5))->area(), "\n";
    function later(): string { return __FUNCTION__; }
}

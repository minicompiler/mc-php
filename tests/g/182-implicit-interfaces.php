<?php
// php implements two interfaces by itself: Stringable on every class that
// declares __toString, and Traversable on every class implementing Iterator
// or IteratorAggregate. instanceof, a return type and a parameter type all
// answered false for them.
class S { function __toString(): string { return "s"; } }
class It implements IteratorAggregate { function getIterator(): Iterator { return new ArrayIterator([1]); } }
$s = new S; var_dump($s instanceof Stringable, new It instanceof Traversable);
function b($x): Stringable { return $x; }
var_dump(b($s));

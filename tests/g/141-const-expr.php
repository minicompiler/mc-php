<?php
// `const` with a value that is not a literal: arithmetic over int literals is
// folded (src/consts.mc), and anything else is a statement run once, where
// the const is -- never glued to the first function after it, which used to
// re-run it on every call of that function.
const NEG = -1;
const SQ = 60 * 60;
const WIDE = 1073741824 * 4;           // not folded: computed where it is
const CAT = 'a' . 'b';
function f(): string { return str_repeat('x', 2) . CAT; }
echo NEG, ' ', SQ, ' ', WIDE, ' ', CAT, ' ', f(), ' ', f(), "\n";
var_dump(NEG, SQ, WIDE, defined('CAT'));

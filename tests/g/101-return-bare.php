<?php
// `return;` in a function declared int is php's compile-time fatal (the
// review of #19); the native return used to hand back whatever the register
// held.
echo "x\n";
function f(): int { return; }
echo f();

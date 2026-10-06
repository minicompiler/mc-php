<?php
// Step 5 (docs/threads.md § Step 5): a fiber's stack is unmapped when it
// finishes (ph_fib_resume), so the live-fiber count returns to zero and the
// address space is given back. 1500 fibers spawned across 5 rounds is well past
// the 1024 ceiling (PH_FIB_MAX) -- it only succeeds because each round's stacks
// were unmapped. The process's virtual size must not have grown by anything
// like 1500 * 128 KiB, which proves the unmap (the leaks gate's program-road
// equivalent; tests/leaks.sh covers the extension road's Zend blocks).
$base = mcphp_vm();
for ($r = 0; $r < 5; $r++) {
    for ($i = 0; $i < 300; $i++) mcphp_spawn(fn(): int => 0);
    mcphp_loop_run();
}
$grew = mcphp_vm() - $base;
echo "1500 fibers over 5 rounds: ", ($grew < 33554432 ? "stacks unmapped" : "LEAKED $grew bytes"), "\n";

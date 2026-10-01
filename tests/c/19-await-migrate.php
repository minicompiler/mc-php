<?php
// Step 5, condition 1 (docs/threads.md § Step 5): a fiber may be resumed only
// by the thread that created it. mcphp_test_migrate() (test scaffolding)
// resumes a fiber as if from another thread; the no-migration guard must fail
// LOUDLY -- a named abort, never a silent wrong-arena corruption. This program
// aborts with exit 255 and the message below on stderr.
echo "before\n";
mcphp_test_migrate();
echo "after\n";

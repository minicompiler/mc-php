<?php
// Step 6b self-test (docs/threads.md § Step 6b): the SUSPEND branch of the
// userland await() wrapper, on the program road where mcphp_can_suspend() is
// true -- the branch examples/awaitable/check.php cannot reach, because there
// await() runs under a live php engine (extension road) and takes the inline
// branch. This mirrors examples/awaitable's await() body (spawn a fiber, await
// its future, wrap the result or the thrown exception in an Intent) so that
// branch, and its exception path, is exercised. Graded against 24-await.out
// (mcphp_* exist only in compiled code: C-behaviour, not run under php).

final class Intent {
    public bool $done = false;
    public bool $failed = false;
    public ?\Throwable $exception = null;
    public mixed $data = null;
}

// the awaitable\await() suspend branch, verbatim: on the program road the loop
// may suspend, so run $fn on a fresh fiber and await its future.
function await(callable $fn, mixed ...$args): Intent {
    $i = new Intent();
    if (\mcphp_can_suspend()) {
        try {
            $i->data = \mcphp_await(\mcphp_spawn(function () use ($fn, $args) { return $fn(...$args); }));
        } catch (\Throwable $e) {
            $i->failed = true;
            $i->exception = $e;
        }
    } else {
        try {
            $i->data = $fn(...$args);
        } catch (\Throwable $e) {
            $i->failed = true;
            $i->exception = $e;
        }
    }
    $i->done = true;
    return $i;
}

echo "can_suspend: ", var_export(mcphp_can_suspend(), true), "\n";

// success: await a callable on a fiber and get its return value back
$w = await(fn(int $a, int $b): int => $a + $b, 2, 40);
echo "ok done=", var_export($w->done, true), " failed=", var_export($w->failed, true),
     " data=", var_export($w->data, true), "\n";

// the exception path: the callable throws, the Intent carries the throwable
$w = await(function (): int { throw new RuntimeException("boom"); });
echo "throw done=", var_export($w->done, true), " failed=", var_export($w->failed, true),
     " ", get_class($w->exception), ": ", $w->exception->getMessage(), "\n";

echo "done\n";

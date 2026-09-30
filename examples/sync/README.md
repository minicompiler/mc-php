# examples/sync -- native sync on the program road

A bounded producer/consumer queue on eight OS threads, built only from
mc-php's native sync (docs/threads.md § Step 4):

- a **mutex** and two **condition variables** guard the queue (`not empty`,
  `not full`);
- a **semaphore** bounds how many producers run at once;
- a **wait group** lets the main thread await every producer;
- **atomics** carry the head, tail and the checksum.

The queue is a bounded count -- the i-th item consumed is worth `i + 1`, so
the checksum is `T*(T+1)/2` for `T = producers * items`, a number the program
must reach exactly. No data crosses a thread; the synchronisation is the point.

```
mc-php --exe sync.php -o sync
./sync                       # checksum 80000200000 expected 80000200000 ok
```

`c/sync.c` is the same workload in C, with POSIX threads and C11 atomics; its
counting semaphore and wait group are built from a mutex and a condition
variable, because POSIX unnamed semaphores are unavailable on macOS -- the same
shape mc-php builds on `futex`, `__ulock_wait` and `WaitOnAddress`.

```
cc -O2 -pthread c/sync.c -o sync-c
./sync-c                     # the same checksum
```

`tests/examples.sh` builds both, checks the checksums match and prints the
wall-clock ratio (mc-php against the C twin). mc-php runs about 1.9x the C
twin here (Apple M-series): its atomics are out-of-line `#opcode` functions
where C's are inlined, and it sleeps on `futex`/`__ulock` where the C twin
sleeps on the same primitives through pthreads. The extension road's own sync
coverage is in `tests/ext.sh` (steps 20b and 20c), which runs on Linux and
Windows too.

# mc-php

PHP 8.5, compiled to a native binary by a compiler taught to [mc](https://github.com/minicompiler/mc).

The rule that makes the project meaningful: **a `.php` source is PHP**. It runs under `php` and it
compiles with `mc-php`, and the two must agree -- the oracle is php-src's own `.phpt` corpus, run
under both. No dialect, no annotations, no "mc-php mode".

What a compiled program is: one binary (no `php`, no `.ini`, no `url/file.php`, no CGI/FCGI). The
web shape is a server the runtime provides (SAPI is ours). Multithreading, async and anything PHP
does not offer today come AFTER everything PHP already provides works.

Status: **proof of concept**. `docs/plan.md` is the plan and the test grid; `probes/` holds the
preliminary measurements (T1..T5) that decide the design before any of the compiler exists.

Consumer of mc 1.0.0 (frozen surface, `docs/reference/hooks.md` § 8 there): nothing here edits
mc's `src/`; a gap in mc's surface is reported to mc, never worked around here.

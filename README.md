# mc-php

PHP 8.5, compiled to a native binary by a compiler taught to [mc](https://github.com/minicompiler/mc).

The rule that makes the project meaningful: **a `.php` source is PHP**. It runs under `php` and it
compiles with `mc-php`, and the two must agree -- the oracle is php-src's own `.phpt` corpus, run
under both. No dialect, no annotations, no "mc-php mode".

What a compiled program is: one binary (no `php`, no `.ini`, no `url/file.php`, no CGI/FCGI). The
web shape is a server the runtime provides (SAPI is ours). Multithreading, async and anything PHP
does not offer today come AFTER everything PHP already provides works.

Status: **proof of concept**. `docs/plan.md` is the plan and the test grid; `probes/` holds the
measurements, in order: T1..T4 decided the design before any of the compiler existed, T5 built
the first compiler and runtime, and T6..T10 worked the wrong-reason table down. The compiler is
`probes/t10/php.mc` (the module mc is taught) plus `probes/t10/php_rt.txt` (the runtime), and
the number it answers with is the phpt grid's green/total.

Consumer of mc's 1.0 frozen surface (`docs/reference/hooks.md` § 8 there): nothing here edits
mc's `src/`; a gap in mc's surface is reported to mc, never worked around here. Built with
whatever 1.x is installed -- the freeze is additive, so a later minor keeps every name 1.0.0
published -- and each probe records the version it measured on (mc 1.1.0 for T10).

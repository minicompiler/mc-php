# examples

Empty on purpose, for now.

The examples this directory is for are **PHP extensions**: a `.php` source, an `mcphp.toml`
beside it, and `mc-php build` producing a `.so` that `php -d extension=...` loads. The schema is
written down in [`docs/mcphp-toml.md`](../docs/mcphp-toml.md) and the reader that acts on it does
not exist yet, so an example here would be a file nothing can build.

The programs that DO run today are not examples, they are gates, and they live where their
obligation is:

* [`tests/g/`](../tests/g) -- 89 differential fixtures, each byte for byte what `php` prints
* [`tests/bench/`](../tests/bench) -- the D8 workload, run under `php` and as an mc-php binary

`docs/plan.md` D8 is why a `.php` cannot land here without a test in both worlds and a bench row,
and `tests/d8check.py` is what enforces it: a `.php` outside `tests/` is in no regime and fails
the gate. When the first example lands, it brings its regime with it.

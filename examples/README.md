# examples

A PHP extension, one directory each: a `.php` source, an `mcphp.toml` beside it, and
`mc-php build` producing a `.so` that `php -d extension=...` loads. The schema is
[`docs/mcphp-toml.md`](../docs/mcphp-toml.md); what is implemented of it today is
[`docs/php-extension.md`](../docs/php-extension.md).

| | |
|---|---|
| [`hello/`](hello) | seven functions with declared scalar parameters and a declared scalar return -- `int`, `string`, `float`, `bool`, `void`, three arguments, and one that throws |

## The regime

`docs/plan.md` D8 is why a `.php` cannot land here without an obligation, and
[`tests/d8check.py`](../tests/d8check.py) enforces it: a `.php` outside `tests/` is in no regime
and fails the gate, **unless** it is under `examples/<name>/` and
[`tests/ext.sh`](../tests/ext.sh) names that directory. That is the seventh regime, `extension`,
and its obligation is a differential:

* the source is built into a `.so`, and `php` loads it;
* `check.php` runs twice -- once with the module loaded, once with the source `require`d -- and
  the two must print the same bytes on **each** stream and exit the same;
* `errors.php` is graded against `errors.expect`, which [`tests/ext/refx.c`](../tests/ext/refx.c)
  measures from an extension of the same signatures built the ordinary C way. It cannot be a
  differential against the interpreted source: an extension's function is an *internal*
  function, and php does not report a bad call to one the way it reports a bad call to a
  userland one.

That is a stronger obligation than a bench row, which is the same exemption D8 already gives a
fixture.

The programs that are not extensions are gates and live where their obligation is:

* [`tests/g/`](../tests/g) -- 89 differential fixtures, each byte for byte what `php` prints
* [`tests/bench/`](../tests/bench) -- the D8 workload, run under `php` and as an mc-php binary

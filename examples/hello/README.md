# hello -- a PHP extension

Seven functions, one `mcphp.toml`, and a `.so` that `php` loads.

```sh
mc-php build examples/hello --config examples/hello/mcphp.toml
php -d extension=examples/hello/build/hello.so -r 'echo hello_greet("world"), "\n";'
# hi world
```

`hello.php` is ordinary PHP and nothing else. `php hello.php` defines the seven functions and
does nothing; `php -r 'require "hello.php"; echo hello_addone(41);'` prints 42, and so does the
compiled module. Neither tool reads anything the other does not -- there is no annotation, no
directive and no "mc-php mode".

| file | |
|---|---|
| `hello.php` | the extension. `int`, `string`, `float`, `bool`, `void`, three arguments, and one that throws |
| `mcphp.toml` | macOS. `mcphp.linux.toml` is the same file with the Linux `[linker]` |
| `check.php` | the DIFFERENTIAL: run once with the module loaded and once with `hello.php` required, and the two must print the same bytes |
| `errors.php` | the wrong calls, graded against `errors.expect` |
| `errors.expect` | measured from an extension of the same signatures built the ordinary C way (`tests/ext/refx.c`) |

## Why `errors.php` is not differential

An extension's function is an **internal** function, and php does not report a bad call to one
the way it reports a bad call to a userland function: no `called in FILE on line N` tail, and an
extra argument is an `ArgumentCountError` rather than being ignored. So the interpreted source is
the wrong oracle for it, and a C extension of the same signatures is the right one.
`tests/ext.sh` rebuilds that reference and re-measures the file wherever `php-config` and a C
compiler are there.

## What `check.php` may not print

Anything that can tell the two runs apart for a legitimate reason. `extension_loaded('hello')` is
exactly that, which is why it guards the `require` and is never printed.

[`docs/php-extension.md`](../../docs/php-extension.md) is what the back end implements, what it
refuses by name, and the four places the two runs would differ if `check.php` went looking for
them.

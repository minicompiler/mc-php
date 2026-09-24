# two-extensions -- HAND-WRITTEN mc, not mc-php output: two extensions that call each other

**`extA.mc` and `extB.mc` are written by hand in mc. mc-php does not produce them.** They are
here because the example is worth gating before the compiler can write it: `extB.php` is the PHP
source they stand in for, and mc-php refuses it by name today --

```
extB.php:8: mc-php: a php function mc-php does not have: a_add is not implemented yet
```

`b_use` calls `a_add`, which extension A publishes and B's own source does not declare. php
resolves a call when it RUNS, in its own function table; mc-php resolves it when it COMPILES, in
the source it was given, and a name that is in neither the source nor its library table is not
built. What the compiler is waiting for is exactly that: **a call to a function the source does
not declare, lowered to a lookup in php's function table at call time**. The two neighbouring
spellings are no way round it today -- `call_user_func('a_add', ...)` is refused by design
(`docs/plan.md` D6), and a variable function `$f(...)` does not parse yet.

The hand-written pair shows the mechanism a compiled extB will need: B reaches A's symbol through
the loader LATE, with `dlsym` at call time rather than at load, so the order php loads the two in
does not matter, and with A absent `b_use` answers -1 instead of failing to load.

## How it is checked -- `tests/examples.sh`

| step | macOS, linux/aarch64, linux/x86_64 | windows/x86_64, windows/arm64 |
|---|---|---|
| **(a)** the pair: `extA.mc` and `extB.mc` compiled by plain mc and linked, loaded into one php **in both orders**, and `check.php` compared byte for byte with the same script run over `extA.php` + `extB.php` interpreted; then B alone answers -1 | yes | SKIPPED, the reason printed: `dlsym` is POSIX, and a DLL publishes only what `-export` names |
| **(b)** two mc-php extensions -- `examples/hello` and `examples/decimal` -- loaded into one php in both orders, each answering | yes | yes |
| **(c)** the build this example waits for, `mcphp.toml` over `extB.php`, refused with exactly the message above | yes | yes |

(b) is a measurement `docs/php-extension.md` § Two extensions in one process did not have: each
mc-php module carries the whole runtime and exports every name in it, and still each one keeps
using its OWN -- mc calls a function and takes an address with a direct `bl`/`adrp`, and the Linux
link is `-Bsymbolic`, so nothing inside a module goes through the loader. What is still true is
that the names are exported: a third module that looked one up would find the first one loaded.

(c) is how the example retires: the day the compiler builds `extB.php`, the gate fails and says
so, and `extB.mc` goes back to `reference/`.

The hand-written files are compiled by plain mc and not by mc-php, because every source mc-php
compiles has the php runtime pushed into it. They are TEMPLATES: the gate fills the target php's
four module-header values from `php -i`, as `reference/extgen.sh` does, and `dlsym`'s
"every global image" handle from the host -- `(void *)-2` on macOS, `(void *)0` on Linux.

| file | |
|---|---|
| `extA.mc`, `extB.mc` | the hand-written pair, from `reference/extA.mc` and `reference/extB.mc` |
| `extA.php`, `extB.php` | the PHP source of the pair: A compiles today, B is refused |
| `mcphp.toml` | the build over `extB.php` that the gate pins. One file: the refusal comes while parsing, before any host's link is read |
| `check.php` | the differential |

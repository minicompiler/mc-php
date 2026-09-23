# The layout, and the one rule

```
mc.toml              the mc project that builds the compiler:  mc build -> build/mc-php
src/*.mc             the compiler -- one mc Tier 3 module, 17 files, plus one entry
                     per host it can be built for
lib/php_rt.mc        the runtime, #embed'ed into the compiler and pushed into every
                     program it compiles
lib/rt_host_*.mc     the runtime's system layer, one file per host, #embed'ed beside
                     it and pushed ahead of it
tests/               the fixtures, the .phpt grid driver and the gates
examples/            (empty; the extension road is what will fill it)
docs/                the plan, the decisions, this
probes/              the measurement record, T0..T10. FROZEN.
php-src/             php's own source, cloned, not committed (the .phpt corpus is the oracle)
```

## `src/` -- the compiler

Everything hangs off ONE registration, `syntax("<?php", &ph_program)`, because an mc word
registration reserves its word for the whole program and PHP has about seventy keywords. They
stay ordinary identifiers matched by `str_eq`.

mc is single pass, so `src/php.mc` includes the parts in order and the order is load-bearing.

| file | lines | what it owns |
|---|---|---|
| `php.mc` | 39 | the umbrella: the include list, in order |
| `mc-php.mc` | 11 | the entry point for the host it is built ON: mc's core through `<mc/host>`, `<float>`, the two float machines, the module |
| `mc-php-linux-aarch64.mc` | 22 | the same, for CROSS-building to linux/aarch64: `<mc/host_linux_aarch64>` in place of `<mc/host>` |
| `mc-php-linux-x86_64.mc` | 22 | the same, for linux/x86_64 |
| `host_extra_linux.mc` | 14 | the one name mc's Linux host layer does not declare and this compiler calls: `realpath(3)` |
| `decls.mc` | 276 | the php type codes (D10), the visibility codes, the mc type handles, every forward declaration, and the named refusals |
| `lex.mc` | 606 | the byte stream, which is the module's own: `tok_add` for what the core lexer can be taught, `p_skip_to` for the four regions it cannot |
| `node.mc` | 152 | mc AST helpers, and the hoisting of every php local to the top of its mc function |
| `vars.mc` | 243 | D4: one type per variable, its first assignment's |
| `consts.mc` | 206 | `const`, `define()`, and php's predefined constants |
| `tables.mc` | 133 | the library table (one row per php function) and the function table |
| `types.mc` | 139 | php's type words on the surface (D9) and the conversions |
| `expr.mc` | 1113 | the expression grammar and php's precedence, both the module's own |
| `builtin.mc` | 1278 | the names the COMPILER lowers to instructions rather than to a library call |
| `stmt.mc` | 377 | statements, unwinding (a pending-exception flag, D7), and the line php reports |
| `lvalue.mc` | 1685 | the lvalue chain, `isset`/`empty`, and `list()` destructuring |
| `closure.mc` | 263 | closures, arrow functions, `use (&$x)` |
| `class.mc` | 787 | classes, interfaces, traits, enums; members; a method body |
| `decl.mc` | 533 | the top-level declarations, and php's hoisting of a global function |
| `program.mc` | 418 | the one registration, the byte scan that runs before the first token, `#embed` of the runtime, and `user_init` |

## `lib/php_rt.mc` -- the runtime

Not a library the program links: there is no linker on that road. It is mc source, `#embed`ed
into the compiler and pushed into every program with `p_push_source`. It implements D10's
lowering table (`string` is a `zend_string`-shaped handle, binary-safe and never
encoding-validated; `float` is `<float>`'s `f64`; `array` is php's ordered hash) over one arena
that is never freed (D7).

### `lib/rt_host_*.mc` -- the runtime's system layer, one file per host

The runtime is about the programs mc-php WRITES, and what those programs call the system with is
not what the compiler calls it with. Until the hosts branch `lib/php_rt.mc` opened with
`#include <sys>` -- mc's libSystem layer -- and declared fourteen more libSystem names and six
macOS `fcntl.h` numbers further down, so every program it wrote was a macOS program and nothing
else. Those declarations are now one file per host, chosen at run time by `src/program.mc` from
`host_os()`/`host_arch()` and pushed AHEAD of the runtime (a push puts its source on top of the
lexer's stack, so the last push is the first thing parsed).

| file | lines | what it answers |
|---|---|---|
| `rt_host_macos.mc` | 86 | libSystem: the six `<sys>` declares, the fourteen php's streams need, `fcntl.h`'s numbers, and `struct stat`'s two offsets |
| `rt_host_linux.mc` | 61 | the same names in musl and glibc, and `asm-generic/fcntl.h`'s numbers, which are NOT macOS's |
| `rt_host_linux_aarch64.mc` | 22 | `struct stat` on arm64: `st_mode` at 16, `st_size` at 48 |
| `rt_host_linux_x86_64.mc` | 22 | `struct stat` on x86-64: `st_mode` at **24**, `st_size` at 48 |

Two consequences worth stating rather than leaving to be found.

**A released mc-php needs nothing installed beside it.** `<sys>` is a library name resolved out
of a tree since mc's M52, so while the runtime carried it, every program mc-php compiled needed
that tree too -- `#include <sys>: not in this compiler and mc 1.1.0's library tree was not
found`. The host files declare their own calls, so they do not. (Building the COMPILER still
needs mc's tree: `src/mc-php.mc` includes `<float>` and the two float machines.)

**One name has no host file and asks the host instead.** `setlocale(3)` is declared in every
layer and `php_f_setlocale` calls it, because "what does this system do with a locale it does not
have" is not a fact a table here can hold: macOS and glibc answer NULL and musl accepts any name
and hands it back. php calls the same function, so asking it is the only way the two agree on
every host. php's `LC_*` category numbers go with it and they are the host's too
(`src/consts.mc`, `ph_lc_bsd` and `ph_lc_gnu`: BSD and the Microsoft CRT number from `LC_ALL`,
glibc and musl from `LC_CTYPE` with `LC_ALL` last).

## `probes/` -- FROZEN

`probes/` is the measurement record. **Nothing under it is ever edited.** A probe's value is
that it still answers the number it published, and a probe that gets fixed has stopped being a
record.

`src/`, `lib/` and `tests/` were carved out of `probes/t10/`, which still holds its own copies
and still runs. That is deliberate duplication and it has one rule: **`src/` is the living
compiler and `probes/t10/php.mc` is the record.** A change goes to `src/` and never to the probe.

`tests/carve.sh` was the proof that the carve moved nothing: it built both and compared the two
binaries byte for byte. Its own header said it dies with the first commit that changes what the
compiler does, and the hosts branch is that commit -- `lib/php_rt.mc` no longer carries a system
layer, so `probes/t10/php_rt.txt` and it are different files by design. The script and its CI
step are deleted. The proof it gave has been made and cannot be made twice.

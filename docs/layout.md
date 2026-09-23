# The layout, and the one rule

```
mc.toml              the mc project that builds the compiler:  mc build -> build/mc-php
src/*.mc             the compiler -- one mc Tier 3 module, 15 files
lib/php_rt.mc        the runtime, #embed'ed into the compiler and pushed into every
                     program it compiles
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
| `mc-php.mc` | 11 | the entry point: mc's core, `<float>`, the two float machines, the module |
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

## `probes/` -- FROZEN

`probes/` is the measurement record. **Nothing under it is ever edited.** A probe's value is
that it still answers the number it published, and a probe that gets fixed has stopped being a
record.

`src/`, `lib/` and `tests/` were carved out of `probes/t10/`, which still holds its own copies
and still runs. That is deliberate duplication and it has one rule: **`src/` is the living
compiler and `probes/t10/php.mc` is the record.** A change goes to `src/` and never to the probe.

`tests/carve.sh` is the proof that the carve moved nothing: it builds both and compares the two
binaries byte for byte. It dies with the first commit that changes what the compiler does, and
it says so in its own header.

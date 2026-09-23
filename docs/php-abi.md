# The Zend ABI, measured

Every number [`lib/php_ext.mc`](../lib/php_ext.mc) depends on, what it was read off, and how to
re-read it. **The compiler never opens a php header** -- that is the whole claim of this
repository. These numbers are baked into mc source and a GATE checks them against the headers
wherever the headers happen to be installed, which is the same arrangement
[`probes/t3`](../probes/t3) has had since the first zval was laid by hand.

Read off **PHP 8.5.10**, macOS 26 / arm64, Homebrew, NTS, `API20250925,NTS`, on **2026-09-22**
and re-measured on **2026-09-23**. The oracle is [`tests/ext/abi.c`](../tests/ext/abi.c):

```sh
cc -o abi tests/ext/abi.c $(php-config --includes) && ./abi
```

and [`tests/ext.sh`](../tests/ext.sh) step 1 diffs its 55 lines against the `#define`s in
`lib/php_ext.mc`, failing on any that disagree. Where `php-config` or a C compiler is absent --
every Linux container this repository grades in -- the step says so and skips; a gate's oracle is
not a dependency of the thing it grades.

## `zend_module_entry` -- 168 bytes (`Zend/zend_modules.h`)

| offset | width | field | what mc-php puts there |
|---|---|---|---|
| 0 | u16 | `size` | 168 |
| 4 | u32 | `zend_api` | `[php].api` |
| 8 | u8 | `zend_debug` | `[php].debug` |
| 9 | u8 | `zts` | `[php].thread_safety` |
| 16 | ptr | `ini_entry` | 0 |
| 24 | ptr | `deps` | 0 -- `[[extension.deps]]` is designed and not implemented |
| 32 | ptr | `name` | `[extension].name` |
| 40 | ptr | `functions` | the `zend_function_entry` table |
| 48 | ptr | `module_startup_func` | `mc_php_minit`, which is the source's top-level statements |
| 56 | ptr | `module_shutdown_func` | 0 |
| 88 | ptr | `version` | `[extension].version` |
| 160 | ptr | `build_id` | `[php].build_id` |

The four fields the loader compares against its own are `zend_api`, `zend_debug`, `zts` and
`build_id`; get one wrong and php answers `Unable to initialize module` and nothing else, which
is what the gate's step 2 exists to prevent. `module_started`, `type`, `handle` and
`module_number` (136, 140, 144, 152) are the ENGINE's and start at zero -- the engine COPIES the
whole record into its own registry the moment `get_module` hands it over, so the static one is
read exactly once.

**`get_module` is the one name outside every rule.** `php-src/ext/standard/dl.c` fetches
`get_module`, then `_get_module`, and nothing else. mc's Mach-O writer prefixes the underscore
and its ELF writer does not, so one mc function called `get_module` answers both.

## `zend_function_entry` -- 48 bytes (`Zend/zend_API.h`)

| offset | width | field |
|---|---|---|
| 0 | ptr | `fname` |
| 8 | ptr | `handler` |
| 16 | ptr | `arg_info` |
| 24 | **u32** | `num_args` |
| 28 | **u32** | `flags` |

`num_args` and `flags` are **two** fields and not one 64-bit word; a table that wrote one over
both would put an arity where a flag belongs. A zeroed row terminates the table.

## `zend_internal_arg_info` -- 32 bytes

| offset | field | entry 0 | entry i |
|---|---|---|---|
| 0 | `name` | the **required argument count**, as an integer in a pointer field | the parameter's name |
| 8 | `type.ptr` | 0 | 0 for a simple type |
| 16 | `type.type_mask` (u32) | the RETURN type's mask | the parameter's mask |
| 24 | `default_value` | 0 | 0 |

`zend_type` is 16 bytes (`{ void *ptr; uint32_t type_mask; }`), which is why the mask a parameter
declares sits at 16 and not at 8. A mask for one simple type is `1 << tag`: `int` (`IS_LONG` 4)
is 16, `string` (6) is 64, `float` (5) is 32, `bool` is `MAY_BE_FALSE|MAY_BE_TRUE` = 12, `void`
is 16384. `lib/php_ext.mc`'s `phx_mask` is the one place that knows this; the compiler names a
type by `docs/plan.md` D10's own code and never by a Zend mask.

**Entry 0 is declarative and the engine does not act on it.** Measured against a reference
extension built the ordinary C way: `arg_info` is what `ReflectionFunction` reports and what
`zend_argument_count_error` reads, and **the engine coerces nothing** -- a `zend_long` parameter
handed the string `"41"` arrives as the `zend_string *`. ZPP is what enforces in C; here the
generated handler does it, in `phx_arity` and `phx_chk`.

## The call -- `zend_execute_data` and `zval`

| | |
|---|---|
| handler signature | `void (zend_execute_data *ex, zval *return_value)` |
| argument N (1-based) | `ex + 80 + (N-1) * 16` (`ZEND_CALL_FRAME_SLOT` 5 x `sizeof(zval)` 16) |
| `num_args` | u32 at `ex + 44` |
| `$this` | `ex + 32` |
| a `zval` | `value` at 0, `type_info` (u32) at 8 |

**A type check reads the LOW BYTE of `type_info`.** A string zval carries `0x106`
(`IS_STRING` | `IS_TYPE_REFCOUNTED << 8`) and an object `0x308`; only `IS_LONG` is exactly 4. A
whole-word comparison answers no for both.

Tags: `IS_UNDEF` 0, `IS_NULL` 1, `IS_FALSE` 2, `IS_TRUE` 3, `IS_LONG` 4, `IS_DOUBLE` 5,
`IS_STRING` 6, `IS_ARRAY` 7, `IS_OBJECT` 8, `IS_RESOURCE` 9, `IS_REFERENCE` 10.

`return_value` arrives `IS_NULL`, so a `void` function writes nothing at all.

## `zend_string`

`refcount` u32 at 0, `type_info` u32 at 4, `h` u64 at 8, `len` u64 at 16, `val[]` at 24, NUL
after. That is **the same record the runtime's own strings use** (`lib/php_rt.mc`, from
`probes/t3`), which is why a php string can be read where it stands -- and why it is nevertheless
COPIED into the arena on the way in: the engine frees its own when the call returns.

**Returning one**: `zend_string_alloc` is inline and unexported, so the header is laid by hand
over `_emalloc` -- refcount 1, `type_info` `0x16` (`GC_STRING`, not interned), hash 0, the length,
the bytes, a NUL -- and the zval's `type_info` is `0x106`. Anything else and the engine either
leaks it or frees something it does not own.

## The four symbols an extension reaches out to

All exported from the php binary, all reached as ordinary `extern`s:

| | |
|---|---|
| `void *_emalloc(size_t)` | the engine's allocator, for a returned `zend_string` |
| `void zend_type_error(const char *fmt, ...)` | a `TypeError` |
| `void zend_argument_count_error(const char *fmt, ...)` | an `ArgumentCountError` -- **not** a `TypeError`; php distinguishes them and so does the gate |
| `zend_object *zend_throw_exception(zend_class_entry *, const char *, zend_long)` | with a null class entry it is `Exception` |
| `zend_class_entry *zend_lookup_class(zend_string *)` | so a php-level `throw` crosses the boundary as its own class |

The first two are variadic. A call with **no** varargs and a format carrying no `%` is safe on
every ABI here, because the named argument travels in a register and only varargs go on the
stack -- and every message `lib/php_ext.mc` builds is made of identifiers and decimals, so a `%`
cannot appear in one.

## Objects, for the one message that needs them

`zend_object.ce` is at 16 and `zend_class_entry.name` at 8, so the class NAME php puts after
"given" in a `TypeError` is two loads from the zval's value. Measured: php says `stdClass given`
and `Closure given`, not `object given` -- and for a bool it says `true`/`false`, not `bool`.

## The link

There is no object-format work here: `mc` already writes Mach-O, ELF and COFF. What php wants is
a **loadable module**, which is not what mc's `--exe` writes, so the `[linker]` road is the road
(`probes/t2` and `probes/t3` made the same call for the same reason).

| host | line |
|---|---|
| macOS | `ld -bundle -undefined dynamic_lookup -arch arm64 -platform_version macos 13.0 13.0 -syslibroot {sdk} -lSystem -o {out} {obj}` |
| Linux | `ld.lld -shared -Bsymbolic -o {out} {obj}` |

`-Bsymbolic` is **not optional**. mc takes the address of its own functions with `adrp`/`add` (and
`lea` on x86-64), and in a shared object a default-visibility symbol is preemptible, so the link
is refused without it.

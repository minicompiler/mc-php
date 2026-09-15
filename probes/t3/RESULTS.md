# T3 -- a real extension function on our zval

Question (`docs/plan.md` § 4): does a real php extension run on a zval built in mc?

Run: `sh probes/t3/run.sh` (after `probes/t1/run.sh`, which builds `ctype.so`).

## Answer: yes

php-src's own `ext/ctype/modules/ctype.so`, built by `phpize` against the installed PHP 8.5.10
headers, loaded into a binary written in mc, with `ctype_digit`'s real handler called on a
`zend_execute_data` and a `zval` that mc laid out itself:

```
layout: 39 facts match the php headers
module: ctype 8.5.10
ctype_digit handler found
  ctype_digit("123") -> true  OK
  ctype_digit("12a") -> false  OK
  ctype_digit("") -> false  OK
    [php_error_docref type=8192 fmt="Argument of type %s will be interpreted as string in the future" arg1="int"]
  ctype_digit(53) -> true  OK
    [php_error_docref type=8192 fmt="Argument of type %s will be interpreted as string in the future" arg1="int"]
  ctype_digit(97) -> false  OK
php_error_docref calls: 2
T3 OK
oracle: php agrees on all 5 inputs
mc --exe: dlopen failed: ... symbol not found in flat namespace '_php_error_docref'
T3: yes -- a real ctype.so ran ctype_digit on a zval built in mc
```

`php` itself is the oracle and agrees on every input:

```
$ php -d display_errors=0 -r 'foreach (["123","12a","",53,97] as $v) { echo ctype_digit($v)?"true":"false","\n"; }'
true
false
false
true
false
```

and it emits exactly the two deprecations mc counted, from the same `php_error_docref` call site.

## Zend symbols: implemented vs stubbed

`ctype.so` imports seven (T1). All seven must be **defined** in the host, because
`dlopen(RTLD_NOW)` resolves every one of them or fails -- that is why five of them exist here at
all.

| symbol | in this probe | reached? |
|---|---|---|
| `zend_zval_type_name` | **implemented** (a type-id to name table) | yes, twice, on the `IS_LONG` path |
| `php_error_docref` | **implemented** (prints the message) | yes, twice, on the `IS_LONG` path |
| `php_info_print_table_start` | stub: prints its own name, `exit(7)` | never |
| `php_info_print_table_row` | stub | never |
| `php_info_print_table_end` | stub | never |
| `zend_wrong_parameter_error` | stub | never |
| `zend_wrong_parameters_count_error` | stub | never |

The stubs are loud on purpose: an unexpected path names the symbol and stops, instead of returning
a wrong answer quietly. None of them fired.

**The string path calls nothing at all.** `ZEND_PARSE_PARAMETERS_START(1,1) / Z_PARAM_ZVAL(c)` is
expanded in `zend_API.h` into inline code that reads `ZEND_NUM_ARGS()` and
`ZEND_CALL_ARG(execute_data, 1)` straight out of the frame; the loop calls libc's `isdigit`; and
`RETURN_TRUE`/`RETURN_FALSE` just write the return zval. So for `ctype_digit("123")` the host
provides **zero** functions -- it only has to get the memory layout right.

`php_error_docref` is declared `(const char *docref, int type, const char *format, ...)` and the
extension really calls it variadically. The mc definition takes the format's `%s` argument as
**parameter 9** -- T2's mechanism, proved here against a real caller rather than a hand-written
one, and it reads back `"int"`, the string this host's own `zend_zval_type_name` returned.

`module_startup_func` is **not** called: ctype's `MINIT` registers nothing `ctype_digit` needs. A
probe, not a runtime.

## Layout facts verified against the headers

`probes/t3/layout.c` prints every one of these with `offsetof`/`sizeof` from
`/opt/homebrew/opt/php/include/php`, and `run.sh` fails if any `#define` in `zend.mc` disagrees.
**39 checked.**

| fact | value | header |
|---|---|---|
| `sizeof(zval)` | 16 | `Zend/zend_types.h:355` `struct _zval_struct` |
| `zval.value` / `u1.type_info` / `u2` | 0 / 8 / 12 | same |
| `IS_FALSE` `IS_TRUE` `IS_LONG` `IS_STRING` | 2 3 4 6 | `zend_types.h:620..627` |
| `IS_TYPE_REFCOUNTED` | 1 (bit 0 of `type_flags`, i.e. `type_info >> 8`) | `zend_types.h:825` |
| `sizeof(zend_string)` | 32 | `zend_types.h:393` `struct _zend_string` |
| `gc.refcount` / `gc.u.type_info` / `h` / `len` / `val` | 0 / 4 / 8 / 16 / **24** | same |
| `GC_STRING` | 22 (`IS_STRING | GC_NOT_COLLECTABLE`) | `zend_types.h:817` |
| `IS_STR_INTERNED` | 64 (`GC_IMMUTABLE`, `1 << 6`) | `zend_types.h:849, 812` |
| `sizeof(zend_execute_data)` | 80 | `Zend/zend_compile.h:625` |
| `opline`/`call`/`return_value`/`func`/`This`/`prev` | 0/8/16/24/32/48 | same |
| `This.u2.num_args` (`ZEND_CALL_NUM_ARGS`) | **44** | `zend_compile.h:691` |
| `ZEND_CALL_FRAME_SLOT` | 5 | `zend_compile.h:698` |
| `ZEND_CALL_ARG(ex, n)` | `ex + 80 + 16*(n-1)` | `zend_compile.h:704, 707` |
| `sizeof(zend_function_entry)` | **48** | `Zend/zend_API.h:35` |
| `fname`/`handler`/`arg_info`/`num_args`/`flags` | 0/8/16/24/28 | same |
| `sizeof(zend_module_entry)` | 168 | `Zend/zend_modules.h:71` |
| `name`/`functions`/`module_startup_func`/`version` | 32/40/48/88 | same |

Two that are easy to get wrong and are worth naming: `zend_string.val` is at **24**, not 20, and
`zend_function_entry` is **48** bytes, not 40 -- PHP 8.4 added `frameless_function_infos` and
`doc_comment` after `flags`. Both would have walked the function table off into nothing.

The zval this probe hands the extension carries `IS_STRING` with **no** `IS_TYPE_REFCOUNTED`, and
the `zend_string` behind it is marked interned (`GC_STRING | IS_STR_INTERNED`, refcount 1). Nothing
in the call path takes or drops a reference, so refcounting did not have to exist for T3 to pass.

## The gap this probe found

The run above is the `[linker]` road. The **`mc --exe` road fails**, and not for the reason
`docs/plan.md` § 5 predicted:

```
dlopen failed: ... symbol not found in flat namespace '_php_error_docref'
```

T2 showed `mc --exe` exports fine. What breaks it here is `zend.mc`'s `u8 zheap[65536]`: once
`__bss` makes `__DATA`'s vmsize exceed its filesize by a whole 16 KiB page, `__LINKEDIT`'s offset
from the mach header in memory stops matching its offset in the file, and every exported symbol
becomes invisible to `dlopen` while the binary still runs. Minimal reproducer and the exact
threshold: `probes/gap-bss-exports/`. Reported in `docs/plan.md` § 5; the `[linker]` road is
immune, because `ld` writes a real `LC_DYLD_EXPORTS_TRIE` and the symbol table is never consulted.

## What this does not measure

One function, one argument, no refcount, no hash table, no object, no exception, no allocator. What
it settles is the thing that had to be settled first: **the layout is reproducible in mc and a real
extension binary is happy with it**. `pdo_sqlite` -- 73 imports including `_pdo_dbh_ce`,
`_std_object_handlers` and the allocator -- is the next order of magnitude and is not attempted
here.

# T1 -- the size of the Zend shim

Question (`docs/plan.md` § 4): how many symbols would a mc-php host binary have to export for a
real php-src extension `.so` to load into it?

Run: `sh probes/t1/run.sh` (needs `php-src` cloned at the repository root, `php-config` on PATH and
`re2c`). It prints the table below and writes the lists to `probes/t1/out/`.

## Measured

Host: macOS 26 / arm64, PHP 8.5.10 (cli, NTS, Homebrew), php-src at `php-8.5.10` (`34308a66`).

```
ext               total  zend-fn zend-data   system
ctype                20        7        0       13
pdo_sqlite          137       65        8       64
mbstring            208      119        8       81
UNION                        157       12
T1: shim = 169 symbols over ctype pdo_sqlite mbstring
```

**The answer is 169**: 157 functions + 12 data globals, the union over three extensions. `ctype`
alone needs **7 functions and no data at all**.

`json` cannot be built shared in PHP 8 (`phpize` + `make` succeed and produce no `.so`); it is
compiled into the binary and belongs to D2(a) -- written in mc -- not to the shim.

## How the split is made

Not by a name heuristic. A `.so` is a `MH_BUNDLE` that links only `libSystem`:

```
$ otool -L ext/ctype/modules/ctype.so
	/usr/lib/libSystem.B.dylib
$ otool -hv ext/ctype/modules/ctype.so | tail -1
MH_MAGIC_64    ARM64        ALL  0x00      BUNDLE    14       1336 DYLDLINK
```

so every `_php_*`/`_zend_*` it names is resolved at `dlopen` time by flat lookup **against whatever
the host process exports**. The script therefore classifies each undefined symbol by asking the
`php` binary: `nm -gU php` (4816 exported symbols: 4315 `T`, 427 `S`, 74 `D`), joined against
`nm -u <so>`. A symbol the host exports is shim; anything else (`_isdigit`, `_memcpy`,
`___maskrune`, `_sqlite3_*`) is libc or another dylib and is not our problem. The `T` vs `D`/`S`
letter is what separates a function from a data global.

## The 12 data globals

```
_core_globals                 _sapi_globals                 _zend_empty_string
_executor_globals             _sapi_module                  _zend_known_strings
_pdo_dbh_ce                   _std_object_handlers          _zend_one_char_string
_php_internal_encoding_changed _zend_empty_array            _zend_string_init_interned
```

Three of these are per-extension rather than engine (`_pdo_dbh_ce` is `ext/pdo`'s class entry,
`_php_internal_encoding_changed` is mbstring's own, exported by the host because `ext/mbstring` is
compiled in). `_zend_string_init_interned` is a **function pointer** the engine swaps at startup,
which is why it lands in the data column. The rest -- `executor_globals`, `core_globals`,
`sapi_globals`, `sapi_module`, `std_object_handlers`, `zend_empty_array`, `zend_empty_string`,
`zend_known_strings`, `zend_one_char_string` -- are the engine state an extension reads directly,
and every one of them is a struct whose layout mc-php would have to reproduce byte for byte.

## What `ctype` needs, in full

```
_php_error_docref              _zend_wrong_parameter_error
_php_info_print_table_end      _zend_wrong_parameters_count_error
_php_info_print_table_row      _zend_zval_type_name
_php_info_print_table_start
```

Four of the seven are `phpinfo()` output and are never reached by a call to `ctype_digit`; the other
three are error paths. **`zend_parse_parameters` is not in the list**: since PHP 7 the fast ZPP
macros (`ZEND_PARSE_PARAMETERS_START`) are expanded in the header into inline code that reads
`execute_data` directly and only calls out on the error path. That is the fact T3 rests on.

## The shape of the 157 functions

| prefix | count | what |
|---|---|---|
| `zend_*` | 64 | engine: strings, hashes, objects, exceptions, ZPP slow paths |
| `php_*` | 31 | `main/`: errors, info, ini, streams, output |
| `add_*` | 12 | array helpers (`add_assoc_*`, `add_next_index_*`) |
| `_e*` | 12 | the allocator (`_emalloc`, `_efree`, `_erealloc`, `_safe_emalloc`, `_estrdup`, ...) |
| `sapi_*` | 6 | the SAPI hooks |
| `zval_*` | 5 | zval lifetime |
| `pdo_*` | 4 | `ext/pdo` talking to `ext/pdo_sqlite` |
| other | 23 | `smart_str_*`, `spprintf`, `convert_*`, `gc_*`, ... |

Full lists: `out/union.zend.functions.txt`, `out/union.zend.data.txt`, and `out/<ext>.{undef,zend,system}.txt`.

## What this does not measure

The union grows with each extension added. 169 is the cost of these three, not of "all of pecl":
`intl`, `gd` and `curl` will each pull more of `main/` in. What the number does bound is the
**shape** of the shim -- an extension talks to the engine through a few hundred entry points, not a
few thousand, and a quarter of what these three import is allocator plus array helpers.

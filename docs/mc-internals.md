# The mc names mc-php depends on and mc does not freeze

mc freezes a public surface: every name in its `tests/golden/surface.txt` keeps its meaning and its parameter count until a major version ([mc's stability policy](https://github.com/minicompiler/mc/blob/main/docs/reference/hooks.md), § 8). mc-php is a compiler built out of mc's parts, not a program that only calls mc's hooks, and it uses more than that surface. This page lists every name it uses beyond it, grouped, each group with the reason.

The same list is [`tests/mcnames.mc`](../tests/mcnames.mc), a probe that names each one the way mc-php uses it -- a function called with the parameter count mc-php relies on, a global's address, a `#define`'s value. [`tests/mcnames.sh`](../tests/mcnames.sh) compiles it against the installed mc: a name that mc lacks, or a function whose parameter count changed, is refused on its own line, and the script prints the name, what it is and the mc version. It runs in CI with `--strict`, which also fails when the installed mc is not the version the probe pins.

**Pinned: mc 1.3.0.** The probe's `// mc-version:` line and `MC_VERSION` in `.github/workflows/ci.yml` are the same value; `--strict` is what keeps them so.

`[package].mc` in `mc.toml` is a different thing: the MINIMUM mc that can build mc-php. The pin is the exact version mc-php was verified against.

## The driver and mc's own main

src/build.mc is mc-php's main: mc's `<mc/core>` is the seven parts plus a main, and mc-php's main calls the parts' inits and mc_main after registering its own `build`, which for thread_safety = "both" runs mc's build (drv_build) in this process and itself again (drv_spawn) for the ZTS half. lex_readable is how that `build` decides whether the project file is one it can read before handing it to mc.

Functions (10): `drv_build`/2, `drv_spawn`/3, `lex_readable`/1, `mc_build_init`/0, `mc_bundle_init`/0, `mc_machines_init`/0, `mc_main`/3, `mc_pkg_init`/0, `mc_sandbox_init`/0, `mc_writers_init`/0.

## C functions mc declares

Three C functions mc-php calls and does not declare, because mc already does and a second extern of a name is `function declared twice`: write (mc's src/arena.mc; src/decls.mc's compile-time fatal error), unlink (every mc host layer; src/build.mc removes the ZTS copy of the project file) and realpath (mc's MACOS host layer only; src/stmt.mc resolves a script's path -- the Linux and Windows entries include `src/host_extra_*.mc` for it, which is why this probe is the macOS one).

Functions (3): `realpath`/2, `unlink`/1, `write`/3.

## mc's buffers, files, memory and output helpers

src/build.mc writes the ZTS copy of the project file with a buffer (buf_init, buf_put, BUF_SIZE, write_file); src/build.mc and src/program.mc compare and copy bytes (mem_eq, mem_copy); src/mach.mc encodes the words its derived machines add (buf_u32) and prints them in --dump-asm (out_str, out_num).

Functions (8): `buf_init`/1, `buf_put`/3, `buf_u32`/2, `mem_copy`/3, `mem_eq`/3, `out_num`/2, `out_str`/2, `write_file`/2.

`#define`s (1): `BUF_SIZE`.

## mc's TOML reader

src/ext.mc and src/program.mc read [php] out of the project file mc already parsed, and report a wrong value at its own file:line:col (toml_err_key); src/build.mc parses it again for "both". mc 1.3.0 does not freeze the `toml_*` family (a later mc does).

Functions (6): `toml_entries`/0, `toml_err_key`/2, `toml_get`/1, `toml_int`/2, `toml_parse`/1, `toml_path_at`/1.

## mc's AST and token vocabulary

mc-php builds its program as mc AST nodes: the node kinds (`N_*`), the core type ids (`TY_*`), the type kinds (`TK_*`), the lexer's token kinds (`T_*`) its own lexer compares against, and node_assign, which src/tls.mc uses to rewrite a node in place.

Functions (1): `node_assign`/2.

`#define`s (36): `N_ADDR`, `N_ASSIGN`, `N_BINARY`, `N_BLOB`, `N_BLOCK`, `N_BREAK`, `N_CALL`, `N_CAST`, `N_CONTINUE`, `N_EXPRSTMT`, `N_EXTERN`, `N_FUNC`, `N_GLOBAL`, `N_HOLE`, `N_IDENT`, `N_IF`, `N_INDEX`, `N_INT`, `N_LOOP`, `N_PARAM`, `N_RETURN`, `N_STR`, `N_UNARY`, `N_VAR`, `TK_INT`, `TK_SINT`, `TY_I64`, `TY_U8`, `TY_UPTR`, `TY_VOID`, `T_CHAR`, `T_EOF`, `T_HOLE`, `T_IDENT`, `T_INT`, `T_STR`.

## `<float>`

php's float is `<float>`'s f64: src/program.mc registers the library and its two machines from user_init (float_init, `machine_*_float_init`) and every file that types a float names ty_f64.

Functions (3): `float_init`/0, `machine_arm64_float_init`/0, `machine_x86_64_float_init`/0.

Globals (1): `ty_f64`.

## mc's machine internals

src/mach.mc derives the arm64 and x86-64 machines to add the instructions mc-php's peephole emits (docs/plan.md § 5): it reads and writes the walker's Ins record (`ins_*`, `set_ins_*`, `INS_*`, nins, ins_base, nlabels, nprel, prel_base), emits through the walker's helpers (e2, e3, ei, em), dispatches on the task slots (`MTASK_*`, `MOP_*`, `MUN_*`, MAXDEPTH), and names each machine's opcodes, registers and helpers (`I_*`, `REG_*`, `X_*`, `XREG_*`, `XR_*`, cond_arm_at, dalias_at, d_head, d_reg, in_reg, `mem_*`, a64_alias_reset, `x86_*`, xalias_at, R_PAGEOFF12). It enables that only on the mc lines it was validated on (pm_validated, which reads mc_version).

Functions (36): `a64_alias_reset`/0, `cond_arm_at`/1, `d_head`/1, `d_reg`/1, `dalias_at`/1, `e2`/3, `e3`/4, `ei`/4, `em`/4, `in_reg`/1, `ins_add`/7, `ins_at`/1, `ins_imm`/1, `ins_label`/1, `ins_op`/1, `ins_rd`/1, `ins_rm`/1, `ins_rn`/1, `ins_sym`/1, `mc_version`/0, `mem_base_at`/1, `mem_name_at`/1, `mem_op`/2, `mem_slot`/1, `mem_wreg`/1, `prel_base`/0, `set_ins_imm`/2, `set_ins_label`/2, `set_ins_op`/2, `set_ins_rd`/2, `x86_dst_done`/2, `x86_dst_reg`/1, `x86_in_reg`/1, `x86_mem_op`/2, `x86_val_reg`/2, `xalias_at`/1.

Globals (4): `ins_base`, `nins`, `nlabels`, `nprel`.

`#define`s (108): `INS_IMM`, `INS_RD`, `INS_RM`, `INS_RN`, `INS_SIZE`, `I_ADD`, `I_ADDI`, `I_ADDLO`, `I_ADRP`, `I_AND`, `I_ANDI`, `I_ASRV`, `I_B`, `I_BCOND`, `I_BL`, `I_BLR`, `I_CBNZ`, `I_CBZ`, `I_CMP`, `I_CMPI`, `I_COUNT`, `I_CSET`, `I_EMIT`, `I_EOR`, `I_LABEL`, `I_LDP_POST`, `I_LDR`, `I_LSLV`, `I_LSRV`, `I_MOV`, `I_MOVK`, `I_MOVW`, `I_MOVZ`, `I_MSUB`, `I_MUL`, `I_MVN`, `I_NEG`, `I_NOP`, `I_ORR`, `I_RET`, `I_SDIV`, `I_STP_PRE`, `I_STR`, `I_SUB`, `I_SUBI`, `I_SXTB`, `I_SXTH`, `I_SXTW`, `I_UDIV`, `MAXDEPTH`, `MOP_ADD`, `MOP_AND`, `MOP_SAR`, `MOP_SDIV`, `MOP_SHL`, `MOP_SHR`, `MOP_SMOD`, `MOP_SUB`, `MTASK_BIN`, `MTASK_BOOL`, `MTASK_CAST`, `MTASK_CMP`, `MTASK_COUNT`, `MTASK_DUMP`, `MTASK_ENCODE`, `MTASK_FRAME_FIX`, `MTASK_GLOBAL_LOAD`, `MTASK_GLOBAL_STORE`, `MTASK_INS_SIZE`, `MTASK_JNZ`, `MTASK_JZ`, `MTASK_LABEL`, `MTASK_LOAD`, `MTASK_PROLOGUE`, `MTASK_REG_STORE`, `MTASK_RELOC_KIND`, `MTASK_RELOC_OFF`, `MTASK_STORE`, `MTASK_UN`, `MUN_LNOT`, `REG_ALLOC`, `REG_BASE`, `REG_FRAME`, `REG_S1`, `REG_S2`, `REG_SP`, `REG_TMP`, `R_PAGEOFF12`, `XREG_BASE`, `XREG_S1`, `XREG_S2`, `XR_RAX`, `XR_RBP`, `XR_RCX`, `XR_RDX`, `XR_RSP`, `X_ADD`, `X_CALL`, `X_CALLR`, `X_COUNT`, `X_EMIT`, `X_JCC`, `X_JMP`, `X_LEA`, `X_MOVI`, `X_MOVZXB`, `X_NOP`, `X_SETCC`.

`name/N` is a function and the number of parameters mc-php calls it with.

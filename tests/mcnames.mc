// mcnames.mc -- every name mc-php uses from mc that mc does not freeze.
//
// mc freezes a public surface (its tests/golden/surface.txt): a name there
// keeps its meaning and its parameter count until a major version. mc-php
// uses more than that -- it is a compiler built out of mc's parts, not a
// program that only calls mc's hooks -- and every such name is here, in
// groups, each group with the reason mc-php needs it. docs/mc-internals.md is
// the same list for a reader.
//
// mc-php is verified against exactly this mc, and the CI installs exactly it:
//
// mc-version: 1.3.1
//
// tests/mcnames.sh compiles this file against the installed mc. It is never
// run: each line names one of the names -- a call with the parameter count
// mc-php relies on, the address of a global, or the value of a #define -- so
// an mc that lacks a name, or changed a function's parameter count, refuses
// that line (`call to unknown function`, `wrong number of arguments`,
// `unknown name`), and the script reports the name, what it is, and the mc
// version that refused it.
//
// Regenerate it when mc-php starts using another unfrozen name: the
// `// mcname NAME WHAT` comment on each line is what the script reads.
#include <mc/host>
#include <mc/core_min>
#include <mc/core_machines>
#include <mc/core_writers>
#include <mc/core_build>
#include <mc/core_bundle>
#include <mc/core_pkg>
#include <mc/core_sandbox>
#include <float>
#include <machine_arm64_float>
#include <machine_x86_64_float>

// what a compiler built from mc's parts defines itself (src/program.mc's is
// mc-php's); the probe's does nothing
void user_init() { }

// ---- the driver and mc's own main ----
// src/build.mc is mc-php's main: mc's <mc/core> is the seven parts plus a
// main, and mc-php's main calls the parts' inits and mc_main after registering
// its own `build`, which for thread_safety = "both" runs mc's build
// (drv_build) in this process and itself again (drv_spawn) for the ZTS half.
// lex_readable is how that `build` decides whether the project file is one it
// can read before handing it to mc.
void mcnames_main() {
    i64 v = 0;
    uptr p = 0;
    drv_build(0, 0);                         // mcname drv_build 2
    drv_spawn(0, 0, 0);                      // mcname drv_spawn 3
    lex_readable(0);                         // mcname lex_readable 1
    mc_build_init();                         // mcname mc_build_init 0
    mc_bundle_init();                        // mcname mc_bundle_init 0
    mc_machines_init();                      // mcname mc_machines_init 0
    mc_main(0, 0, 0);                        // mcname mc_main 3
    mc_pkg_init();                           // mcname mc_pkg_init 0
    mc_sandbox_init();                       // mcname mc_sandbox_init 0
    mc_writers_init();                       // mcname mc_writers_init 0
}

// ---- C functions mc declares ----
// Three C functions mc-php calls and does not declare, because mc already does
// and a second extern of a name is `function declared twice`: write (mc's
// src/arena.mc; src/decls.mc's compile-time fatal error), unlink (every mc
// host layer; src/build.mc removes the ZTS copy of the project file) and
// realpath (mc's MACOS host layer only; src/stmt.mc resolves a script's path
// -- the Linux and Windows entries include src/host_extra_*.mc for it, which
// is why this probe is the macOS one).
void mcnames_host() {
    i64 v = 0;
    uptr p = 0;
    realpath(0, 0);                          // mcname realpath 2
    unlink(0);                               // mcname unlink 1
    write(0, 0, 0);                          // mcname write 3
}

// ---- mc's buffers, files, memory and output helpers ----
// src/build.mc writes the ZTS copy of the project file with a buffer
// (buf_init, buf_put, BUF_SIZE, write_file); src/build.mc and src/program.mc
// compare and copy bytes (mem_eq, mem_copy); src/mach.mc encodes the words its
// derived machines add (buf_u32) and prints them in --dump-asm (out_str,
// out_num).
void mcnames_arena() {
    i64 v = 0;
    uptr p = 0;
    v = BUF_SIZE;                            // mcname BUF_SIZE define
    buf_init(0);                             // mcname buf_init 1
    buf_put(0, 0, 0);                        // mcname buf_put 3
    buf_u32(0, 0);                           // mcname buf_u32 2
    mem_copy(0, 0, 0);                       // mcname mem_copy 3
    mem_eq(0, 0, 0);                         // mcname mem_eq 3
    out_num(0, 0);                           // mcname out_num 2
    out_str(0, 0);                           // mcname out_str 2
    write_file(0, 0);                        // mcname write_file 2
}

// ---- mc's TOML reader ----
// src/ext.mc and src/program.mc read [php] out of the project file mc already
// parsed, and report a wrong value at its own file:line:col (toml_err_key);
// src/build.mc parses it again for "both". mc 1.3.0 does not freeze the toml_*
// family (a later mc does).
void mcnames_toml() {
    i64 v = 0;
    uptr p = 0;
    toml_entries();                          // mcname toml_entries 0
    toml_err_key(0, 0);                      // mcname toml_err_key 2
    toml_get(0);                             // mcname toml_get 1
    toml_int(0, 0);                          // mcname toml_int 2
    toml_parse(0);                           // mcname toml_parse 1
    toml_path_at(0);                         // mcname toml_path_at 1
}

// ---- mc's AST and token vocabulary ----
// mc-php builds its program as mc AST nodes: the node kinds (N_*), the core
// type ids (TY_*), the type kinds (TK_*), the lexer's token kinds (T_*) its
// own lexer compares against, and node_assign, which src/tls.mc uses to
// rewrite a node in place.
void mcnames_ast() {
    i64 v = 0;
    uptr p = 0;
    v = N_ADDR;                              // mcname N_ADDR define
    v = N_ASSIGN;                            // mcname N_ASSIGN define
    v = N_BINARY;                            // mcname N_BINARY define
    v = N_BLOB;                              // mcname N_BLOB define
    v = N_BLOCK;                             // mcname N_BLOCK define
    v = N_BREAK;                             // mcname N_BREAK define
    v = N_CALL;                              // mcname N_CALL define
    v = N_CAST;                              // mcname N_CAST define
    v = N_CONTINUE;                          // mcname N_CONTINUE define
    v = N_EXPRSTMT;                          // mcname N_EXPRSTMT define
    v = N_EXTERN;                            // mcname N_EXTERN define
    v = N_FUNC;                              // mcname N_FUNC define
    v = N_GLOBAL;                            // mcname N_GLOBAL define
    v = N_HOLE;                              // mcname N_HOLE define
    v = N_IDENT;                             // mcname N_IDENT define
    v = N_IF;                                // mcname N_IF define
    v = N_INDEX;                             // mcname N_INDEX define
    v = N_INT;                               // mcname N_INT define
    v = N_LOOP;                              // mcname N_LOOP define
    v = N_PARAM;                             // mcname N_PARAM define
    v = N_RETURN;                            // mcname N_RETURN define
    v = N_STR;                               // mcname N_STR define
    v = N_UNARY;                             // mcname N_UNARY define
    v = N_VAR;                               // mcname N_VAR define
    v = TK_INT;                              // mcname TK_INT define
    v = TK_SINT;                             // mcname TK_SINT define
    v = TY_I64;                              // mcname TY_I64 define
    v = TY_U8;                               // mcname TY_U8 define
    v = TY_UPTR;                             // mcname TY_UPTR define
    v = TY_VOID;                             // mcname TY_VOID define
    v = T_CHAR;                              // mcname T_CHAR define
    v = T_EOF;                               // mcname T_EOF define
    v = T_HOLE;                              // mcname T_HOLE define
    v = T_IDENT;                             // mcname T_IDENT define
    v = T_INT;                               // mcname T_INT define
    v = T_STR;                               // mcname T_STR define
    node_assign(0, 0);                       // mcname node_assign 2
}

// ---- <float> ----
// php's float is <float>'s f64: src/program.mc registers the library and its
// two machines from user_init (float_init, machine_*_float_init) and every
// file that types a float names ty_f64.
void mcnames_float() {
    i64 v = 0;
    uptr p = 0;
    float_init();                            // mcname float_init 0
    machine_arm64_float_init();              // mcname machine_arm64_float_init 0
    machine_x86_64_float_init();             // mcname machine_x86_64_float_init 0
    p = (uptr) &ty_f64;                      // mcname ty_f64 global
}

// ---- mc's machine internals ----
// src/mach.mc derives the arm64 and x86-64 machines to add the instructions
// mc-php's peephole emits (docs/plan.md § 5): it reads and writes the walker's
// Ins record (ins_*, set_ins_*, INS_*, nins, ins_base, nlabels, nprel,
// prel_base), emits through the walker's helpers (e2, e3, ei, em), dispatches
// on the task slots (MTASK_*, MOP_*, MUN_*, MAXDEPTH), and names each
// machine's opcodes, registers and helpers (I_*, REG_*, X_*, XREG_*, XR_*,
// cond_arm_at, dalias_at, d_head, d_reg, in_reg, mem_*, a64_alias_reset,
// x86_*, xalias_at, R_PAGEOFF12). It enables that only on the mc lines it was
// validated on (pm_validated, which reads mc_version).
void mcnames_machine() {
    i64 v = 0;
    uptr p = 0;
    v = INS_IMM;                             // mcname INS_IMM define
    v = INS_RD;                              // mcname INS_RD define
    v = INS_RM;                              // mcname INS_RM define
    v = INS_RN;                              // mcname INS_RN define
    v = INS_SIZE;                            // mcname INS_SIZE define
    v = I_ADD;                               // mcname I_ADD define
    v = I_ADDI;                              // mcname I_ADDI define
    v = I_ADDLO;                             // mcname I_ADDLO define
    v = I_ADRP;                              // mcname I_ADRP define
    v = I_AND;                               // mcname I_AND define
    v = I_ANDI;                              // mcname I_ANDI define
    v = I_ASRV;                              // mcname I_ASRV define
    v = I_B;                                 // mcname I_B define
    v = I_BCOND;                             // mcname I_BCOND define
    v = I_BL;                                // mcname I_BL define
    v = I_BLR;                               // mcname I_BLR define
    v = I_CBNZ;                              // mcname I_CBNZ define
    v = I_CBZ;                               // mcname I_CBZ define
    v = I_CMP;                               // mcname I_CMP define
    v = I_CMPI;                              // mcname I_CMPI define
    v = I_COUNT;                             // mcname I_COUNT define
    v = I_CSET;                              // mcname I_CSET define
    v = I_EMIT;                              // mcname I_EMIT define
    v = I_EOR;                               // mcname I_EOR define
    v = I_LABEL;                             // mcname I_LABEL define
    v = I_LDP_POST;                          // mcname I_LDP_POST define
    v = I_LDR;                               // mcname I_LDR define
    v = I_LSLV;                              // mcname I_LSLV define
    v = I_LSRV;                              // mcname I_LSRV define
    v = I_MOV;                               // mcname I_MOV define
    v = I_MOVK;                              // mcname I_MOVK define
    v = I_MOVW;                              // mcname I_MOVW define
    v = I_MOVZ;                              // mcname I_MOVZ define
    v = I_MSUB;                              // mcname I_MSUB define
    v = I_MUL;                               // mcname I_MUL define
    v = I_MVN;                               // mcname I_MVN define
    v = I_NEG;                               // mcname I_NEG define
    v = I_NOP;                               // mcname I_NOP define
    v = I_ORR;                               // mcname I_ORR define
    v = I_RET;                               // mcname I_RET define
    v = I_SDIV;                              // mcname I_SDIV define
    v = I_STP_PRE;                           // mcname I_STP_PRE define
    v = I_STR;                               // mcname I_STR define
    v = I_SUB;                               // mcname I_SUB define
    v = I_SUBI;                              // mcname I_SUBI define
    v = I_SXTB;                              // mcname I_SXTB define
    v = I_SXTH;                              // mcname I_SXTH define
    v = I_SXTW;                              // mcname I_SXTW define
    v = I_UDIV;                              // mcname I_UDIV define
    v = MAXDEPTH;                            // mcname MAXDEPTH define
    v = MOP_ADD;                             // mcname MOP_ADD define
    v = MOP_AND;                             // mcname MOP_AND define
    v = MOP_SAR;                             // mcname MOP_SAR define
    v = MOP_SDIV;                            // mcname MOP_SDIV define
    v = MOP_SHL;                             // mcname MOP_SHL define
    v = MOP_SHR;                             // mcname MOP_SHR define
    v = MOP_SMOD;                            // mcname MOP_SMOD define
    v = MOP_SUB;                             // mcname MOP_SUB define
    v = MTASK_BIN;                           // mcname MTASK_BIN define
    v = MTASK_BOOL;                          // mcname MTASK_BOOL define
    v = MTASK_CAST;                          // mcname MTASK_CAST define
    v = MTASK_CMP;                           // mcname MTASK_CMP define
    v = MTASK_COUNT;                         // mcname MTASK_COUNT define
    v = MTASK_DUMP;                          // mcname MTASK_DUMP define
    v = MTASK_ENCODE;                        // mcname MTASK_ENCODE define
    v = MTASK_FRAME_FIX;                     // mcname MTASK_FRAME_FIX define
    v = MTASK_GLOBAL_LOAD;                   // mcname MTASK_GLOBAL_LOAD define
    v = MTASK_GLOBAL_STORE;                  // mcname MTASK_GLOBAL_STORE define
    v = MTASK_INS_SIZE;                      // mcname MTASK_INS_SIZE define
    v = MTASK_JNZ;                           // mcname MTASK_JNZ define
    v = MTASK_JZ;                            // mcname MTASK_JZ define
    v = MTASK_LABEL;                         // mcname MTASK_LABEL define
    v = MTASK_LOAD;                          // mcname MTASK_LOAD define
    v = MTASK_PROLOGUE;                      // mcname MTASK_PROLOGUE define
    v = MTASK_REG_STORE;                     // mcname MTASK_REG_STORE define
    v = MTASK_RELOC_KIND;                    // mcname MTASK_RELOC_KIND define
    v = MTASK_RELOC_OFF;                     // mcname MTASK_RELOC_OFF define
    v = MTASK_STORE;                         // mcname MTASK_STORE define
    v = MTASK_UN;                            // mcname MTASK_UN define
    v = MUN_LNOT;                            // mcname MUN_LNOT define
    v = REG_ALLOC;                           // mcname REG_ALLOC define
    v = REG_BASE;                            // mcname REG_BASE define
    v = REG_FRAME;                           // mcname REG_FRAME define
    v = REG_S1;                              // mcname REG_S1 define
    v = REG_S2;                              // mcname REG_S2 define
    v = REG_SP;                              // mcname REG_SP define
    v = REG_TMP;                             // mcname REG_TMP define
    v = R_PAGEOFF12;                         // mcname R_PAGEOFF12 define
    v = XREG_BASE;                           // mcname XREG_BASE define
    v = XREG_S1;                             // mcname XREG_S1 define
    v = XREG_S2;                             // mcname XREG_S2 define
    v = XR_RAX;                              // mcname XR_RAX define
    v = XR_RBP;                              // mcname XR_RBP define
    v = XR_RCX;                              // mcname XR_RCX define
    v = XR_RDX;                              // mcname XR_RDX define
    v = XR_RSP;                              // mcname XR_RSP define
    v = X_ADD;                               // mcname X_ADD define
    v = X_CALL;                              // mcname X_CALL define
    v = X_CALLR;                             // mcname X_CALLR define
    v = X_COUNT;                             // mcname X_COUNT define
    v = X_EMIT;                              // mcname X_EMIT define
    v = X_JCC;                               // mcname X_JCC define
    v = X_JMP;                               // mcname X_JMP define
    v = X_LEA;                               // mcname X_LEA define
    v = X_MOVI;                              // mcname X_MOVI define
    v = X_MOVZXB;                            // mcname X_MOVZXB define
    v = X_NOP;                               // mcname X_NOP define
    v = X_SETCC;                             // mcname X_SETCC define
    a64_alias_reset();                       // mcname a64_alias_reset 0
    cond_arm_at(0);                          // mcname cond_arm_at 1
    d_head(0);                               // mcname d_head 1
    d_reg(0);                                // mcname d_reg 1
    dalias_at(0);                            // mcname dalias_at 1
    e2(0, 0, 0);                             // mcname e2 3
    e3(0, 0, 0, 0);                          // mcname e3 4
    ei(0, 0, 0, 0);                          // mcname ei 4
    em(0, 0, 0, 0);                          // mcname em 4
    in_reg(0);                               // mcname in_reg 1
    ins_add(0, 0, 0, 0, 0, 0, 0);            // mcname ins_add 7
    ins_at(0);                               // mcname ins_at 1
    p = (uptr) &ins_base;                    // mcname ins_base global
    ins_imm(0);                              // mcname ins_imm 1
    ins_label(0);                            // mcname ins_label 1
    ins_op(0);                               // mcname ins_op 1
    ins_rd(0);                               // mcname ins_rd 1
    ins_rm(0);                               // mcname ins_rm 1
    ins_rn(0);                               // mcname ins_rn 1
    ins_sym(0);                              // mcname ins_sym 1
    mc_version();                            // mcname mc_version 0
    mem_base_at(0);                          // mcname mem_base_at 1
    mem_name_at(0);                          // mcname mem_name_at 1
    mem_op(0, 0);                            // mcname mem_op 2
    mem_slot(0);                             // mcname mem_slot 1
    mem_wreg(0);                             // mcname mem_wreg 1
    p = (uptr) &nins;                        // mcname nins global
    p = (uptr) &nlabels;                     // mcname nlabels global
    p = (uptr) &nprel;                       // mcname nprel global
    prel_base();                             // mcname prel_base 0
    set_ins_imm(0, 0);                       // mcname set_ins_imm 2
    set_ins_label(0, 0);                     // mcname set_ins_label 2
    set_ins_op(0, 0);                        // mcname set_ins_op 2
    set_ins_rd(0, 0);                        // mcname set_ins_rd 2
    x86_dst_done(0, 0);                      // mcname x86_dst_done 2
    x86_dst_reg(0);                          // mcname x86_dst_reg 1
    x86_in_reg(0);                           // mcname x86_in_reg 1
    x86_mem_op(0, 0);                        // mcname x86_mem_op 2
    x86_val_reg(0, 0);                       // mcname x86_val_reg 2
    xalias_at(0);                            // mcname xalias_at 1
}

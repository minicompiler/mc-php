// mach.mc -- a peephole machine derived from the one mc drives on arm64.
//
// mc's arm64 machine (and <float>'s over it) lowers every operand through a
// register: `$i + 1` is `mov x10, #1; add x9, x9, x10`, `ld64(s + 16)` is
// `mov x10, #16; add x9, x21, x10; ldr x9, [x9]`, `$i < 9` is `mov x10, #9;
// cmp x9, x10`, and `if (c) break;` is `b.cond L1; b L2; L1:` -- two taken
// branches where one is enough. examples/decimal's profile is mostly the
// runtime's byte loops and the compiled php around them, which is all of that.
// This machine is the documented recipe (mc's docs/reference/machine.md §
// Deriving a machine): a copy of the table in effect, a few slots replaced,
// every other task delegated through a PRISTINE copy. It adds no instruction
// form: the immediate add/sub/cmp/and, the load and store with an offset and
// the inverted branch are forms the bundled machine already encodes, so its
// encoder, dump and sweep are untouched. Each rewrite looks at instructions
// already in the buffer and only ever turns one into I_NOP (which emits no
// word) and emits the shorter form.
//
//   P1  a constant that fits the immediate field, just materialised into the
//       right operand's register by a lone movz, is the operand of add, sub,
//       and (a 2^k-1 mask) or cmp;
//   P2  `add x, base, #k` just emitted for an address is the offset of the
//       load that reads it, and of the store that writes it when nothing
//       between the two touched either register;
//   P3  a lone movz (or P6's global load) stored into an allocated local is
//       written there directly;
//   P4  at a label: `b.cond L; b M; L:` is `b.!cond M; L:`, and a branch to
//       the label itself (nothing but labels between) is dropped;
//   P5  `cmp x, #0; cset x, ne` right after a cset into x is dropped: the
//       value is already 0 or 1, and so is an integer cast of it (P7);
//   P8  `!b` right after the cset that made b flips its condition instead;
//   P9  a branch on that boolean is a branch on the flags (P8 and P9 are mc's
//       own P2 and P1, which it applies with -O only; here they apply always);
//   P6  a global's load or store is `adrp x, sym; ldr y, [x, :lo12:sym]`, not
//       `adrp; add; ldr [x]`: the page offset goes into the access itself.
//       This one IS a new form, the access with a PAGEOFF12 relocation on it,
//       so it has a band of its own (500..501, the free one in mc's registry,
//       docs/reference/machine.md § The opcode bands) with its encoder, size,
//       dump and relocation kind; the words are the bundled ldr/str encodings
//       with a zero offset, which is what every linker and mc's own --exe
//       writer already patch a page offset into (they classify the access by
//       its size bits).
//
// The x86-64 half (both ABIs, over <float>'s) is the same idea in that
// machine's forms: `lea rd, [rl + k]` is the add or sub of a constant, and a
// load or a store takes the lea's offset; P4 with jcc/jmp; P7, P8 and P9
// after the setcc/movzx pair. x86 has no compare
// with an immediate in mc's table and its mov of a constant into a local is
// already retargeted, so P1's cmp half, P3 and P5 have no x86 twin.

uptr pm_tab;                          // this machine
uptr pm_orig;                         // what it was derived from, pristine
i64  pm_ad[MAXDEPTH];                 // P2: where the last address add for a depth is
i64  pm_ad_at(i64 d) { return ld64(pm_ad + d * 8); }
void pm_ad_set(i64 d, i64 v) { st64(pm_ad + d * 8, v); }
i64  pm_off;                          // MCPHP_PEEP=0 in the compiler's environment

uptr pm_of(i64 task) { return ld64(pm_orig + task * 8); }

// P6's band: ins_rm holds the bundled I_LDR*/I_STR* it stands for
#define PM_LDG   500
#define PM_STG   501
#define PM_MAXOP 502
i64 pm_mine(i64 op) { return op >= PM_LDG && op < PM_MAXOP; }

i64 pm_int(i64 d) {
    i64 k = type_kind(walk_depth_type(d));
    return k == TK_INT || k == TK_SINT;
}

// the index of the latest instruction that emits a word, skipping the ones a
// rewrite turned into I_NOP; -1 at the start of the function
i64 pm_last() {
    i64 i = nins - 1;
    loop {
        if (i < ins_base) return 0 - 1;
        if (ins_op(ins_at(i)) != I_NOP) return i;
        i = i - 1;
    }
    return 0 - 1;
}

// P1: the value a lone `movz` put into depth d's own register, or -1
i64 pm_konst(i64 d) {
    if (!in_reg(d) || dalias_at(d) >= 0) return 0 - 1;
    i64 j = pm_last();
    if (j < 0) return 0 - 1;
    uptr e = ins_at(j);
    if (ins_op(e) != I_MOVZ || ins_rd(e) != REG_BASE + d || ins_rn(e) != 0) return 0 - 1;
    return j;
}

// a 2^k-1 mask, the one AND immediate the bundled encoder writes
i64 pm_mask(i64 m) {
    if (m <= 0) return 0;
    return (m & (m + 1)) == 0;
}

void pm_bin(i64 op, i64 d, i64 d2) {
    if (pm_off || !pm_int(d)) { callp(pm_of(MTASK_BIN), op, d, d2); return; }
    i64 j = pm_konst(d2);
    if (j >= 0) {
        i64 k = ins_imm(ins_at(j));
        i64 iop = 0;
        if (op == MOP_ADD && k <= 4095) iop = I_ADDI;
        if (op == MOP_SUB && k <= 4095) iop = I_SUBI;
        if (op == MOP_AND && pm_mask(k)) iop = I_ANDI;
        if (iop) {
            set_ins_op(ins_at(j), I_NOP);
            i64 rl = val_reg(d, REG_S1);
            i64 rd = dst_reg(d);
            ei(iop, rd, rl, k);
            if (iop == I_ADDI && in_reg(d)) pm_ad_set(d, nins - 1);
            dst_done(d, rd);
            return;
        }
    }
    callp(pm_of(MTASK_BIN), op, d, d2);
}

void pm_cmp(i64 cond, i64 d, i64 d2) {
    if (pm_off || !pm_int(d) || cond < 0 || cond >= 10) { callp(pm_of(MTASK_CMP), cond, d, d2); return; }
    i64 j = pm_konst(d2);
    if (j >= 0 && ins_imm(ins_at(j)) <= 4095) {
        i64 k = ins_imm(ins_at(j));
        set_ins_op(ins_at(j), I_NOP);
        i64 rl = val_reg(d, REG_S1);
        i64 rd = dst_reg(d);
        ei(I_CMPI, 0, rl, k);
        ins_add(I_CSET, rd, 0, 0, cond_arm_at(cond), 0, 0);
        dst_done(d, rd);
        return;
    }
    callp(pm_of(MTASK_CMP), cond, d, d2);
}

// P2: `add rd, base, #k` at index j, still what depth d's register holds, and
// an offset the access of this width can carry
i64 pm_addr_ok(i64 j, i64 d, i64 ty) {
    if (j < ins_base || j >= nins) return 0;
    uptr e = ins_at(j);
    if (ins_op(e) != I_ADDI || ins_rd(e) != REG_BASE + d) return 0;
    i64 rn = ins_rn(e);
    if (rn == REG_FRAME || rn == REG_SP || rn == REG_S1 || rn == REG_S2 || rn == REG_TMP) return 0;
    i64 w = type_width(ty);
    if (w != 1 && w != 2 && w != 4 && w != 8) return 0;
    i64 k = ins_imm(e);
    if (k % w != 0 || k / w > 4095) return 0;
    return 1;
}

void pm_load(i64 ty, i64 d) {
    if (!pm_off && in_reg(d) && dalias_at(d) < 0) {
        i64 j = pm_last();
        if (j >= 0 && pm_addr_ok(j, d, ty)) {
            uptr e = ins_at(j);
            set_ins_op(e, I_NOP);
            i64 rd = dst_reg(d);
            em(mem_op(ty, 0), rd, ins_rn(e), ins_imm(e));
            dst_done(d, rd);
            return;
        }
    }
    callp(pm_of(MTASK_LOAD), ty, d);
}

// between the address and the store, nothing may name the address's register
// or its base, and nothing may be a label or a call (a path that skipped the
// add, or a callee that clobbers the base)
i64 pm_clean(i64 j, i64 r1, i64 r2) {
    i64 i = j + 1;
    loop {
        if (i >= nins) break;
        uptr e = ins_at(i);
        i64 op = ins_op(e);
        if (op != I_NOP) {
            if (op == I_LABEL || op == I_BL || op == I_BLR || op == I_B || op == I_BCOND
                || op == I_CBZ || op == I_CBNZ || op == I_EMIT || op >= I_COUNT) return 0;
            if (ins_rd(e) == r1 || ins_rn(e) == r1 || ins_rm(e) == r1) return 0;
            if (ins_rd(e) == r2 || ins_rn(e) == r2 || ins_rm(e) == r2) return 0;
        }
        i = i + 1;
    }
    return 1;
}

void pm_store(i64 ty, i64 d) {
    if (!pm_off && in_reg(d) && dalias_at(d) < 0) {
        i64 j = pm_ad_at(d);
        if (pm_addr_ok(j, d, ty)) {
            uptr e = ins_at(j);
            if (pm_clean(j, REG_BASE + d, ins_rn(e))) {
                set_ins_op(e, I_NOP);
                i64 rv = val_reg(d + 1, REG_S2);
                em(mem_op(ty, 1), rv, ins_rn(e), ins_imm(e));
                pm_ad_set(d, 0 - 1);
                return;
            }
        }
    }
    callp(pm_of(MTASK_STORE), ty, d);
}

// P3: a local's register gets a small constant directly
void pm_reg_store(i64 ty, i64 d, i64 r) {
    i64 j = 0 - 1;
    if (!pm_off && pm_int(d)) j = pm_konst(d);
    // and P6's load of a global, which only writes its rd
    if (j < 0 && !pm_off && pm_int(d) && in_reg(d) && dalias_at(d) < 0) {
        i64 g = pm_last();
        if (g >= 0 && ins_op(ins_at(g)) == PM_LDG && ins_rd(ins_at(g)) == REG_BASE + d) j = g;
    }
    if (j >= 0) {
        set_ins_rd(ins_at(j), REG_ALLOC + r);
        gen_cast(REG_ALLOC + r, ty);
        a64_alias_reset();
        return;
    }
    callp(pm_of(MTASK_REG_STORE), ty, d, r);
}

// P5: `d = (d != 0)` right after a cset into d's own register is already so
void pm_bool(i64 d) {
    if (!pm_off && pm_int(d) && in_reg(d) && dalias_at(d) < 0) {
        i64 j = pm_last();
        if (j >= 0) {
            uptr e = ins_at(j);
            if (ins_op(e) == I_CSET && ins_rd(e) == REG_BASE + d) return;
        }
    }
    callp(pm_of(MTASK_BOOL), d);
}

// P7: an integer cast of a value a cset just made (0 or 1 fits every width)
void pm_cast(i64 ty, i64 d) {
    i64 k = type_kind(ty);
    if (!pm_off && pm_int(d) && (k == TK_INT || k == TK_SINT) && in_reg(d) && dalias_at(d) < 0) {
        i64 j = pm_last();
        if (j >= 0) {
            uptr e = ins_at(j);
            if (ins_op(e) == I_CSET && ins_rd(e) == REG_BASE + d) return;
        }
    }
    callp(pm_of(MTASK_CAST), ty, d);
}

// P8: `!b` right after the cset that made b is the cset of the other
// condition -- mc does it on the optimised road only (its own P2)
void pm_un(i64 op, i64 d) {
    if (!pm_off && op == MUN_LNOT && pm_int(d) && in_reg(d) && dalias_at(d) < 0) {
        i64 j = pm_last();
        if (j >= 0) {
            uptr e = ins_at(j);
            if (ins_op(e) == I_CSET && ins_rd(e) == REG_BASE + d) { set_ins_imm(e, ins_imm(e) ^ 1); return; }
        }
    }
    callp(pm_of(MTASK_UN), op, d);
}

// P9: a branch on the boolean a cset just made is a branch on the flags --
// mc's own P1, which it applies on the optimised road only
i64 pm_fuse(i64 d, i64 l, i64 take) {
    if (pm_off || !pm_int(d) || !in_reg(d) || dalias_at(d) >= 0) return 0;
    i64 j = pm_last();
    if (j < 0) return 0;
    uptr e = ins_at(j);
    if (ins_op(e) != I_CSET || ins_rd(e) != REG_BASE + d) return 0;
    i64 cc = ins_imm(e);
    if (!take) cc = cc ^ 1;
    set_ins_op(e, I_NOP);
    ins_add(I_BCOND, 0, 0, 0, cc, l, 0);
    return 1;
}
void pm_jz(i64 d, i64 l)  { if (!pm_fuse(d, l, 0)) callp(pm_of(MTASK_JZ), d, l); }
void pm_jnz(i64 d, i64 l) { if (!pm_fuse(d, l, 1)) callp(pm_of(MTASK_JNZ), d, l); }

i64 pm_is_branch(i64 op) { return op == I_BCOND || op == I_CBZ || op == I_CBNZ; }

// P4
void pm_label(i64 l) {
    if (!pm_off) {
        // a branch to this very label, with only labels between, goes nowhere
        i64 i = nins - 1;
        loop {
            if (i < ins_base) break;
            uptr e = ins_at(i);
            i64 op = ins_op(e);
            if (op == I_NOP || op == I_LABEL) { i = i - 1; continue; }
            if ((op == I_B || pm_is_branch(op)) && ins_label(e) == l) set_ins_op(e, I_NOP);
            break;
        }
        // `b.cond L; b M; L:` -- the conditional branch jumps over the other
        i64 b = pm_last();
        if (b >= 0 && ins_op(ins_at(b)) == I_B) {
            i64 c = b - 1;
            loop { if (c < ins_base) break; if (ins_op(ins_at(c)) != I_NOP) break; c = c - 1; }
            if (c >= ins_base) {
                uptr ce = ins_at(c);
                i64 cop = ins_op(ce);
                if (pm_is_branch(cop) && ins_label(ce) == l) {
                    if (cop == I_BCOND) set_ins_imm(ce, ins_imm(ce) ^ 1);
                    if (cop == I_CBZ) set_ins_op(ce, I_CBNZ);
                    if (cop == I_CBNZ) set_ins_op(ce, I_CBZ);
                    set_ins_label(ce, ins_label(ins_at(b)));
                    set_ins_op(ins_at(b), I_NOP);
                }
            }
        }
    }
    callp(pm_of(MTASK_LABEL), l);
}

// P6
void pm_global_load(i64 ty, i64 d, i64 sym) {
    i64 k = type_kind(ty);
    if (pm_off || (k != TK_INT && k != TK_SINT)) { callp(pm_of(MTASK_GLOBAL_LOAD), ty, d, sym); return; }
    i64 rd = dst_reg(d);
    ins_add(I_ADRP, rd, 0, 0, 0, 0, sym);
    ins_add(PM_LDG, rd, rd, mem_op(ty, 0), 0, 0, sym);
    dst_done(d, rd);
}

void pm_global_store(i64 ty, i64 d, i64 sym) {
    i64 k = type_kind(ty);
    if (pm_off || (k != TK_INT && k != TK_SINT)) { callp(pm_of(MTASK_GLOBAL_STORE), ty, d, sym); return; }
    ins_add(I_ADRP, REG_S1, 0, 0, 0, 0, sym);
    ins_add(PM_STG, val_reg(d, REG_S2), REG_S1, mem_op(ty, 1), 0, 0, sym);
}

i64 pm_ins_size(uptr e) {
    if (pm_mine(ins_op(e))) return 4;
    return callp(pm_of(MTASK_INS_SIZE), e);
}

void pm_encode(uptr e, i64 pc, uptr lab, uptr b) {
    if (!pm_mine(ins_op(e))) { callp(pm_of(MTASK_ENCODE), e, pc, lab, b); return; }
    i64 mi = mem_slot(ins_rm(e));
    buf_u32(b, mem_base_at(mi) | (ins_rn(e) << 5) | ins_rd(e));
}

i64 pm_reloc_kind(uptr e) {
    if (pm_mine(ins_op(e))) return R_PAGEOFF12;
    return callp(pm_of(MTASK_RELOC_KIND), e);
}

i64 pm_reloc_off(uptr e) {
    if (pm_mine(ins_op(e))) return 0;
    return callp(pm_of(MTASK_RELOC_OFF), e);
}

void pm_dump(uptr e) {
    if (!pm_mine(ins_op(e))) { callp(pm_of(MTASK_DUMP), e); return; }
    i64 mi = mem_slot(ins_rm(e));
    d_head(mem_name_at(mi));
    if (mem_wreg(mi)) { out_str(1, "w"); out_num(1, ins_rd(e)); } else d_reg(ins_rd(e));
    out_str(1, ", [");
    d_reg(ins_rn(e));
    out_str(1, ", ");
    out_str(1, sym_name(sym_at(ins_sym(e))));
    out_str(1, "@PAGEOFF]\n");
}

void pm_prologue() {
    i64 d = 0;
    loop { if (d >= MAXDEPTH) break; pm_ad_set(d, 0 - 1); d = d + 1; }
    callp(pm_of(MTASK_PROLOGUE));
}

void pm_env() {
    uptr e = host_environ();
    if (!e) return;
    i64 i = 0;
    loop {
        uptr s = ld64(e + i * 8);
        if (!s) return;
        if (str_eq(s, "MCPHP_PEEP=0")) { pm_off = 1; return; }
        i = i + 1;
    }
}

// ---- x86-64 ------------------------------------------------------------------
uptr px_tab;
uptr px_tab_win;
uptr px_orig;
uptr px_orig_win;
uptr px_cur;                          // the pristine table of the ABI in effect
i64  px_ad[MAXDEPTH];
i64  px_ad_at(i64 d) { return ld64(px_ad + d * 8); }
void px_ad_set(i64 d, i64 v) { st64(px_ad + d * 8, v); }

uptr px_of(i64 task) { return ld64(px_cur + task * 8); }

i64 px_last() {
    i64 i = nins - 1;
    loop {
        if (i < ins_base) return 0 - 1;
        if (ins_op(ins_at(i)) != X_NOP) return i;
        i = i - 1;
    }
    return 0 - 1;
}

i64 px_konst(i64 d) {
    if (!x86_in_reg(d) || xalias_at(d) >= 0) return 0 - 1;
    i64 j = px_last();
    if (j < 0) return 0 - 1;
    uptr e = ins_at(j);
    if (ins_op(e) != X_MOVI || ins_rd(e) != XREG_BASE + d) return 0 - 1;
    return j;
}

void px_bin(i64 op, i64 d, i64 d2) {
    if (!pm_off && pm_int(d) && (op == MOP_ADD || op == MOP_SUB)) {
        i64 j = px_konst(d2);
        if (j >= 0) {
            i64 k = ins_imm(ins_at(j));
            if (op == MOP_SUB) k = 0 - k;
            if (k >= 0 - 2147483647 && k <= 2147483647) {
                set_ins_op(ins_at(j), X_NOP);
                i64 rl = x86_val_reg(d, XREG_S1);
                i64 rd = x86_dst_reg(d);
                em(X_LEA, rd, rl, k);
                if (x86_in_reg(d)) px_ad_set(d, nins - 1);
                x86_dst_done(d, rd);
                return;
            }
        }
    }
    callp(px_of(MTASK_BIN), op, d, d2);
}

i64 px_addr_ok(i64 j, i64 d) {
    if (j < ins_base || j >= nins) return 0;
    uptr e = ins_at(j);
    if (ins_op(e) != X_LEA || ins_rd(e) != XREG_BASE + d) return 0;
    i64 rn = ins_rn(e);
    return rn != XR_RBP && rn != XR_RSP && rn != XR_RAX && rn != XR_RCX && rn != XR_RDX;
}

void px_load(i64 ty, i64 d) {
    if (!pm_off && x86_in_reg(d) && xalias_at(d) < 0) {
        i64 j = px_last();
        if (j >= 0 && px_addr_ok(j, d)) {
            uptr e = ins_at(j);
            set_ins_op(e, X_NOP);
            i64 rd = x86_dst_reg(d);
            em(x86_mem_op(ty, 0), rd, ins_rn(e), ins_imm(e));
            x86_dst_done(d, rd);
            return;
        }
    }
    callp(px_of(MTASK_LOAD), ty, d);
}

i64 px_clean(i64 j, i64 r1, i64 r2) {
    i64 i = j + 1;
    loop {
        if (i >= nins) break;
        uptr e = ins_at(i);
        i64 op = ins_op(e);
        if (op != X_NOP) {
            if (op == I_LABEL || op == X_CALL || op == X_CALLR || op == X_JMP || op == X_JCC
                || op == X_EMIT || op >= X_COUNT) return 0;
            if (ins_rd(e) == r1 || ins_rn(e) == r1 || ins_rm(e) == r1) return 0;
            if (ins_rd(e) == r2 || ins_rn(e) == r2 || ins_rm(e) == r2) return 0;
        }
        i = i + 1;
    }
    return 1;
}

void px_store(i64 ty, i64 d) {
    if (!pm_off && x86_in_reg(d) && xalias_at(d) < 0) {
        i64 j = px_ad_at(d);
        if (px_addr_ok(j, d)) {
            uptr e = ins_at(j);
            if (px_clean(j, XREG_BASE + d, ins_rn(e))) {
                set_ins_op(e, X_NOP);
                i64 rv = x86_val_reg(d + 1, XREG_S2);
                em(x86_mem_op(ty, 1), rv, ins_rn(e), ins_imm(e));
                px_ad_set(d, 0 - 1);
                return;
            }
        }
    }
    callp(px_of(MTASK_STORE), ty, d);
}

void px_label(i64 l) {
    if (!pm_off) {
        i64 i = nins - 1;
        loop {
            if (i < ins_base) break;
            uptr e = ins_at(i);
            i64 op = ins_op(e);
            if (op == X_NOP || op == I_LABEL) { i = i - 1; continue; }
            if ((op == X_JMP || op == X_JCC) && ins_label(e) == l) set_ins_op(e, X_NOP);
            break;
        }
        i64 b = px_last();
        if (b >= 0 && ins_op(ins_at(b)) == X_JMP) {
            i64 c = b - 1;
            loop { if (c < ins_base) break; if (ins_op(ins_at(c)) != X_NOP) break; c = c - 1; }
            if (c >= ins_base) {
                uptr ce = ins_at(c);
                if (ins_op(ce) == X_JCC && ins_label(ce) == l) {
                    set_ins_imm(ce, ins_imm(ce) ^ 1);
                    set_ins_label(ce, ins_label(ins_at(b)));
                    set_ins_op(ins_at(b), X_NOP);
                }
            }
        }
    }
    callp(px_of(MTASK_LABEL), l);
}

// P7 on x86-64: the setcc/movzx pair already made a 0 or a 1
void px_cast(i64 ty, i64 d) {
    i64 k = type_kind(ty);
    if (!pm_off && pm_int(d) && (k == TK_INT || k == TK_SINT) && x86_in_reg(d) && xalias_at(d) < 0) {
        i64 j = px_last();
        if (j > ins_base) {
            uptr z = ins_at(j);
            uptr c = ins_at(j - 1);
            if (ins_op(z) == X_MOVZXB && ins_rd(z) == XREG_BASE + d && ins_rn(z) == XREG_BASE + d
                && ins_op(c) == X_SETCC && ins_rd(c) == XREG_BASE + d) return;
        }
    }
    callp(px_of(MTASK_CAST), ty, d);
}

void px_un(i64 op, i64 d) {
    if (!pm_off && op == MUN_LNOT && pm_int(d) && x86_in_reg(d) && xalias_at(d) < 0) {
        i64 j = px_last();
        if (j > ins_base) {
            uptr z = ins_at(j);
            uptr c = ins_at(j - 1);
            if (ins_op(z) == X_MOVZXB && ins_rd(z) == XREG_BASE + d && ins_rn(z) == XREG_BASE + d
                && ins_op(c) == X_SETCC && ins_rd(c) == XREG_BASE + d) { set_ins_imm(c, ins_imm(c) ^ 1); return; }
        }
    }
    callp(px_of(MTASK_UN), op, d);
}

i64 px_fuse(i64 d, i64 l, i64 take) {
    if (pm_off || !pm_int(d) || !x86_in_reg(d) || xalias_at(d) >= 0) return 0;
    i64 j = px_last();
    if (j <= ins_base) return 0;
    uptr z = ins_at(j);
    uptr c = ins_at(j - 1);
    if (ins_op(z) != X_MOVZXB || ins_rd(z) != XREG_BASE + d || ins_rn(z) != XREG_BASE + d) return 0;
    if (ins_op(c) != X_SETCC || ins_rd(c) != XREG_BASE + d) return 0;
    i64 cc = ins_imm(c);
    if (!take) cc = cc ^ 1;
    set_ins_op(z, X_NOP);
    set_ins_op(c, X_NOP);
    ins_add(X_JCC, 0, 0, 0, cc, l, 0);
    return 1;
}
void px_jz(i64 d, i64 l)  { if (!px_fuse(d, l, 0)) callp(px_of(MTASK_JZ), d, l); }
void px_jnz(i64 d, i64 l) { if (!px_fuse(d, l, 1)) callp(px_of(MTASK_JNZ), d, l); }

void px_prologue_at(uptr orig) {
    px_cur = orig;
    i64 d = 0;
    loop { if (d >= MAXDEPTH) break; px_ad_set(d, 0 - 1); d = d + 1; }
    callp(px_of(MTASK_PROLOGUE));
}
void px_prologue_sysv() { px_prologue_at(px_orig); }
void px_prologue_win()  { px_prologue_at(px_orig_win); }

void px_fill(uptr tab, uptr orig, uptr src, uptr pro) {
    i64 t = 0;
    loop {
        if (t >= MTASK_COUNT) break;
        st64(tab  + t * 8, ld64(src + t * 8));
        st64(orig + t * 8, ld64(src + t * 8));
        t = t + 1;
    }
    machine_slot(tab, MTASK_PROLOGUE, pro);
    machine_slot(tab, MTASK_BIN,      &px_bin);
    machine_slot(tab, MTASK_LOAD,     &px_load);
    machine_slot(tab, MTASK_STORE,    &px_store);
    machine_slot(tab, MTASK_LABEL,    &px_label);
    machine_slot(tab, MTASK_CAST,     &px_cast);
    machine_slot(tab, MTASK_UN,       &px_un);
    machine_slot(tab, MTASK_JZ,       &px_jz);
    machine_slot(tab, MTASK_JNZ,      &px_jnz);
}

// The derivation reads the Ins record, opcode numbers and machine helpers
// that mc's tests/golden/surface.txt does not freeze, so it is enabled only on
// the mc lines it was validated on (tests/fixtures.sh's peephole read-back,
// run on all five CI legs). On any other mc the bundled machines stay and the
// compiled code is what the core writes; that read-back then fails, which is
// the signal to validate the new line and add it here.
i64 pm_validated() {
    uptr v = xstrdup(mc_version(), 4);
    return str_eq(v, "1.1.") || str_eq(v, "1.2.") || str_eq(v, "1.3.");
}

// derived from whatever "arm64" is now (<float>'s machine, over mc's)
void ph_mach_init() {
    if (!pm_validated()) return;
    pm_env();
    pm_tab  = xalloc(MTASK_COUNT * 8);
    pm_orig = xalloc(MTASK_COUNT * 8);
    uptr src = machine_tab("arm64");
    i64 t = 0;
    loop {
        if (t >= MTASK_COUNT) break;
        st64(pm_tab  + t * 8, ld64(src + t * 8));
        st64(pm_orig + t * 8, ld64(src + t * 8));
        t = t + 1;
    }
    machine_slot(pm_tab, MTASK_PROLOGUE,  &pm_prologue);
    machine_slot(pm_tab, MTASK_BIN,       &pm_bin);
    machine_slot(pm_tab, MTASK_CMP,       &pm_cmp);
    machine_slot(pm_tab, MTASK_LOAD,      &pm_load);
    machine_slot(pm_tab, MTASK_STORE,     &pm_store);
    machine_slot(pm_tab, MTASK_REG_STORE, &pm_reg_store);
    machine_slot(pm_tab, MTASK_LABEL,     &pm_label);
    machine_slot(pm_tab, MTASK_BOOL,      &pm_bool);
    machine_slot(pm_tab, MTASK_CAST,      &pm_cast);
    machine_slot(pm_tab, MTASK_UN,        &pm_un);
    machine_slot(pm_tab, MTASK_JZ,        &pm_jz);
    machine_slot(pm_tab, MTASK_JNZ,       &pm_jnz);
    machine_slot(pm_tab, MTASK_GLOBAL_LOAD,  &pm_global_load);
    machine_slot(pm_tab, MTASK_GLOBAL_STORE, &pm_global_store);
    machine_slot(pm_tab, MTASK_INS_SIZE,     &pm_ins_size);
    machine_slot(pm_tab, MTASK_ENCODE,       &pm_encode);
    machine_slot(pm_tab, MTASK_RELOC_KIND,   &pm_reloc_kind);
    machine_slot(pm_tab, MTASK_RELOC_OFF,    &pm_reloc_off);
    machine_slot(pm_tab, MTASK_DUMP,         &pm_dump);
    machine("arm64", pm_tab);
    px_tab      = xalloc(MTASK_COUNT * 8);
    px_orig     = xalloc(MTASK_COUNT * 8);
    px_tab_win  = xalloc(MTASK_COUNT * 8);
    px_orig_win = xalloc(MTASK_COUNT * 8);
    px_fill(px_tab, px_orig, machine_tab("x86_64"), &px_prologue_sysv);
    px_fill(px_tab_win, px_orig_win, machine_tab("x86_64-win"), &px_prologue_win);
    px_cur = px_orig;
    machine("x86_64", px_tab);
    machine("x86_64-win", px_tab_win);
}

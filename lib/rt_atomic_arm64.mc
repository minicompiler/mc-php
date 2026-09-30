// rt_atomic_arm64.mc -- the runtime's atomic words on AArch64 (macOS, Linux
// and Windows alike: AAPCS64 is the same on all three). lib/rt_atomic_x86_64.mc
// and lib/rt_atomic_win64.mc are the x86-64 halves; src/program.mc pushes the
// one the TARGET's architecture needs (docs/threads.md § Step 4).
//
// Every atomic is ONE function whose body is raw words: `#opcode` folds a
// constant, so an atomic cannot take an expression, and its operands are the
// parameters, which arrive in x0..x2 and which mc's prologue only stores to
// the frame. A function with no `return` ends in an epilogue that leaves x0
// alone, so x0 is the answer. Scratch is x2..x4, caller-saved, which mc never
// keeps a value in across a call.
//
// The read-modify-writes are load-exclusive/store-exclusive loops (ARMv8.0),
// not the ARMv8.1 LSE words, so nothing here needs FEAT_LSE. A loop split
// across two functions is not an option -- the frame stores and the `ret`
// between the halves may clear the exclusive monitor -- which is why each loop
// lives entirely inside one function, with its branch offsets in the word.
//
// Ordering: ldar/stlr and ldaxr/stlxr are release-consistent (RCsc), so these
// five are sequentially consistent, the order php code sees (docs/threads.md
// § the memory model).
//
// Every word was assembled by
//   llvm-mc -triple=aarch64-linux-gnu -filetype=obj  |  llvm-objdump -d
// and tests/sweep_sync.py re-assembles them and checks mc emits them.
#opcode ph_w(v) v

// the value at p
i64 ph_at_load(uptr p) {
    ph_w(0xC8DFFC00);       // ldar  x0, [x0]
}

// *p = v
void ph_at_store(uptr p, i64 v) {
    ph_w(0xC89FFC01);       // stlr  x1, [x0]
}

// *p += d, answering the value before
i64 ph_at_add(uptr p, i64 d) {
    ph_w(0xC85FFC02);       // 1: ldaxr x2, [x0]
    ph_w(0x8B010043);       //    add   x3, x2, x1
    ph_w(0xC804FC03);       //    stlxr w4, x3, [x0]
    ph_w(0x35FFFFA4);       //    cbnz  w4, 1b
    ph_w(0xAA0203E0);       //    mov   x0, x2
}

// if *p == e then *p = n: 1 when it was, 0 when it was not
i64 ph_at_cas(uptr p, i64 e, i64 n) {
    ph_w(0xC85FFC03);       // 1: ldaxr x3, [x0]
    ph_w(0xEB01007F);       //    cmp   x3, x1
    ph_w(0x540000A1);       //    b.ne  2f
    ph_w(0xC804FC02);       //    stlxr w4, x2, [x0]
    ph_w(0x35FFFF84);       //    cbnz  w4, 1b
    ph_w(0xD2800020);       //    mov   x0, #1
    ph_w(0x14000003);       //    b     3f
    ph_w(0xD5033F5F);       // 2: clrex
    ph_w(0xD2800000);       //    mov   x0, #0
}                           // 3:

// *p = v, answering the value before
i64 ph_at_xchg(uptr p, i64 v) {
    ph_w(0xC85FFC02);       // 1: ldaxr x2, [x0]
    ph_w(0xC803FC01);       //    stlxr w3, x1, [x0]
    ph_w(0x35FFFFC3);       //    cbnz  w3, 1b
    ph_w(0xAA0203E0);       //    mov   x0, x2
}

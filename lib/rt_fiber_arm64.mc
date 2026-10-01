// rt_fiber_arm64.mc -- the runtime's stackful-fiber context switch on AArch64
// (macOS, Linux and Windows-on-ARM alike: AAPCS64 is the same on all three).
// lib/rt_fiber_x86_64.mc and lib/rt_fiber_win64.mc are the x86-64 halves;
// src/program.mc pushes the one the TARGET's architecture needs
// (docs/threads.md § Step 5). This is the house mechanism the atomics use
// (lib/rt_atomic_arm64.mc): a primitive mc cannot express, written as a raw
// `#opcode` word function and gated by tests/sweep_sync.py.
//
// ph_ctx_swap(from, to) parks the current fiber into `from` and resumes `to`.
// It saves only the callee-saved registers and SP; x29/x30 are NOT saved here
// -- mc's own prologue pushed them onto this fiber's stack and its epilogue
// pops them, so the swap just restores the TARGET's SP and lets mc's epilogue
// (`add sp, sp, #0x10; ldp x29, x30, [sp], #0x10; ret`) pop the target's
// frame pointer and return address off the target's stack and jump there. So
// the body ends by loading the target's SP and falls through to mc's epilogue
// -- there is no `ret` of its own. The whole model rests on a fiber never
// migrating threads (docs/threads.md § 5 risk 5): the self-test asserts it.
//
// The saved context is 152 bytes inside a PH_CTX (256) buffer: x19..x28 at
// 0..79, SP at 80, d8..d15 at 88..151. x0 = from, x1 = to; x2 is scratch,
// caller-saved. mc's prologue stored x0/x1 to the frame and left them in the
// registers, so the body reads them directly.
//
// Every word was assembled by
//   llvm-mc -triple=aarch64-linux-gnu -filetype=obj  |  llvm-objcopy -O binary
// and tests/sweep_sync.py re-assembles them and checks mc emits them.
#opcode ph_fw(v) v

void ph_ctx_swap(uptr from, uptr to) {
    ph_fw(0xA9005013);       // stp x19, x20, [x0, #0]
    ph_fw(0xA9015815);       // stp x21, x22, [x0, #16]
    ph_fw(0xA9026017);       // stp x23, x24, [x0, #32]
    ph_fw(0xA9036819);       // stp x25, x26, [x0, #48]
    ph_fw(0xA904701B);       // stp x27, x28, [x0, #64]
    ph_fw(0x910003E2);       // mov x2, sp
    ph_fw(0xF9002802);       // str x2, [x0, #80]
    ph_fw(0x6D05A408);       // stp d8, d9, [x0, #88]
    ph_fw(0x6D06AC0A);       // stp d10, d11, [x0, #104]
    ph_fw(0x6D07B40C);       // stp d12, d13, [x0, #120]
    ph_fw(0x6D08BC0E);       // stp d14, d15, [x0, #136]
    ph_fw(0xA9405033);       // ldp x19, x20, [x1, #0]
    ph_fw(0xA9415835);       // ldp x21, x22, [x1, #16]
    ph_fw(0xA9426037);       // ldp x23, x24, [x1, #32]
    ph_fw(0xA9436839);       // ldp x25, x26, [x1, #48]
    ph_fw(0xA944703B);       // ldp x27, x28, [x1, #64]
    ph_fw(0xF9402822);       // ldr x2, [x1, #80]
    ph_fw(0x9100005F);       // mov sp, x2
    ph_fw(0x6D45A428);       // ldp d8, d9, [x1, #88]
    ph_fw(0x6D46AC2A);       // ldp d10, d11, [x1, #104]
    ph_fw(0x6D47B42C);       // ldp d12, d13, [x1, #120]
    ph_fw(0x6D48BC2E);       // ldp d14, d15, [x1, #136]
}

// Prepare a fresh fiber's context so the first ph_ctx_swap into it returns,
// through mc's epilogue, at `tramp` with a clean 16-byte-aligned stack.
// `top` is the high end of the fiber's stack (16-aligned). mc's epilogue does
// `add sp, #0x10; ldp x29, x30, [sp], #0x10; ret`, so it reads the frame pair
// at (saved SP + 16). We put (fp=0, lr=tramp) at top-16 and save SP = top-32;
// the epilogue then lands at `tramp` with sp = top. Not a raw function: it
// only writes memory a normal store can reach.
void ph_ctx_bootstrap(uptr ctx, uptr top, uptr tramp) {
    uptr pair = top - 16;
    st64(pair, 0);               // x29 the trampoline will see (no caller frame)
    st64(pair + 8, tramp);       // x30: ret target
    st64(ctx + 80, top - 32);    // saved SP; epilogue's add #0x10 reaches `pair`
}

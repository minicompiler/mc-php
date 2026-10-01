// rt_fiber_x86_64.mc -- the runtime's stackful-fiber context switch on x86-64
// under the System V convention (Linux): the parameters arrive in rdi and rsi.
// lib/rt_fiber_win64.mc is the same under the Windows x64 convention (rcx,
// rdx), and lib/rt_fiber_arm64.mc says what a context switch is and why the
// body falls through to mc's own epilogue instead of returning itself.
//
// ph_ctx_swap(from, to) saves the callee-saved registers -- rbx, rbp, r12..r15
// -- into `from` and loads them from `to`. rbp is included: mc's epilogue is
// `leave; ret` (mov rsp, rbp; pop rbp; ret), so restoring the target's rbp is
// what makes `leave` land on the target's stack and `ret` return into it. rsp
// is reconstructed by `leave` from rbp, so it is not saved separately. No XMM
// is callee-saved on System V. The saved context is 48 bytes inside a PH_CTX
// (256) buffer: rbx 0, rbp 8, r12 16, r13 24, r14 32, r15 40.
//
// x86 instructions are one to fifteen bytes and `#opcode` folds one 32-bit
// word, so the body is a BYTE STREAM cut into four-byte words, little-endian,
// an instruction free to straddle a word boundary, the tail padded with `nop`
// (0x90). Beside each word: its four bytes, then the instructions that START
// in it. mc's prologue stored rdi/rsi to the frame and left them in the
// registers, so the body reads them directly.
//
// Every byte was assembled by
//   llvm-mc -triple=x86_64-linux-gnu -x86-asm-syntax=intel --show-encoding
// and tests/sweep_sync.py re-assembles them and checks mc emits them.
#opcode ph_fw(v) v

void ph_ctx_swap(uptr from, uptr to) {
    ph_fw(0x481F8948);       // 48 89 1f 48    mov [rdi+0], rbx ; mov [rdi+8], rbp
    ph_fw(0x4C086F89);       // 89 6f 08 4c    mov [rdi+16], r12
    ph_fw(0x4C106789);       // 89 67 10 4c    mov [rdi+24], r13
    ph_fw(0x4C186F89);       // 89 6f 18 4c    mov [rdi+32], r14
    ph_fw(0x4C207789);       // 89 77 20 4c    mov [rdi+40], r15
    ph_fw(0x48287F89);       // 89 7f 28 48    mov rbx, [rsi+0]
    ph_fw(0x8B481E8B);       // 8b 1e 48 8b    mov rbp, [rsi+8]
    ph_fw(0x8B4C086E);       // 6e 08 4c 8b    mov r12, [rsi+16]
    ph_fw(0x8B4C1066);       // 66 10 4c 8b    mov r13, [rsi+24]
    ph_fw(0x8B4C186E);       // 6e 18 4c 8b    mov r14, [rsi+32]
    ph_fw(0x8B4C2076);       // 76 20 4c 8b    mov r15, [rsi+40]
    ph_fw(0x9090287E);       // 7e 28 90 90    nop ; nop
}

// Prepare a fresh fiber's context so the first ph_ctx_swap into it returns,
// through mc's `leave; ret`, at `tramp` with a System-V-aligned stack (rsp
// congruent to 8 mod 16 at entry, as after a `call`). `top` is 16-aligned.
// `leave` sets rsp = rbp, pops rbp, `ret` pops the return address; so with
// rbp = top-24 and (0, tramp) at top-24/top-16, entry lands at `tramp` with
// rsp = top-8. See lib/rt_fiber_arm64.mc for the same idea on that arch.
void ph_ctx_bootstrap(uptr ctx, uptr top, uptr tramp) {
    st64(top - 24, 0);          // the rbp `leave` pops (no caller frame)
    st64(top - 16, tramp);      // the return address `ret` jumps to
    st64(ctx + 8, top - 24);    // saved rbp
}

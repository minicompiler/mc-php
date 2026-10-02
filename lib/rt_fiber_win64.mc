// rt_fiber_win64.mc -- the runtime's stackful-fiber context switch on x86-64
// under the Windows x64 convention: the parameters arrive in rcx and rdx. The
// same mechanism as lib/rt_fiber_x86_64.mc, which says how the words are cut
// and why the body falls through to mc's `leave; ret`. Windows x64 saves far
// more across a call: rbx, rbp, rdi, rsi, r12..r15 AND xmm6..xmm15, all of
// which a fiber running arbitrary compiled code may hold, so all are saved.
// The saved context is 224 bytes inside a PH_CTX (256) buffer: rbx 0, rbp 8,
// rdi 16, rsi 24, r12 32, r13 40, r14 48, r15 56, xmm6..xmm15 at 64..223
// (movups, so the buffer needs no 16-byte alignment). mc's prologue stored
// rcx/rdx to the frame and left them in the registers.
//
// Every byte was assembled by
//   llvm-mc -triple=x86_64-linux-gnu -x86-asm-syntax=intel --show-encoding
// and tests/sweep_sync.py re-assembles them and checks mc emits them.
#opcode ph_fw(v) v

void ph_ctx_swap(uptr from, uptr to) {
    ph_fw(0x48198948);       // 48 89 19 48    mov [rcx+0], rbx ; mov [rcx+8], rbp
    ph_fw(0x48086989);       // 89 69 08 48    mov [rcx+16], rdi
    ph_fw(0x48107989);       // 89 79 10 48    mov [rcx+24], rsi
    ph_fw(0x4C187189);       // 89 71 18 4c    mov [rcx+32], r12
    ph_fw(0x4C206189);       // 89 61 20 4c    mov [rcx+40], r13
    ph_fw(0x4C286989);       // 89 69 28 4c    mov [rcx+48], r14
    ph_fw(0x4C307189);       // 89 71 30 4c    mov [rcx+56], r15
    ph_fw(0x0F387989);       // 89 79 38 0f    movups [rcx+64], xmm6
    ph_fw(0x0F407111);       // 11 71 40 0f    movups [rcx+80], xmm7
    ph_fw(0x44507911);       // 11 79 50 44    movups [rcx+96], xmm8
    ph_fw(0x6041110F);       // 0f 11 41 60
    ph_fw(0x49110F44);       // 44 0f 11 49    movups [rcx+112], xmm9
    ph_fw(0x110F4470);       // 70 44 0f 11    movups [rcx+128], xmm10
    ph_fw(0x00008091);       // 91 80 00 00
    ph_fw(0x110F4400);       // 00 44 0f 11    movups [rcx+144], xmm11
    ph_fw(0x00009099);       // 99 90 00 00
    ph_fw(0x110F4400);       // 00 44 0f 11    movups [rcx+160], xmm12
    ph_fw(0x0000A0A1);       // a1 a0 00 00
    ph_fw(0x110F4400);       // 00 44 0f 11    movups [rcx+176], xmm13
    ph_fw(0x0000B0A9);       // a9 b0 00 00
    ph_fw(0x110F4400);       // 00 44 0f 11    movups [rcx+192], xmm14
    ph_fw(0x0000C0B1);       // b1 c0 00 00
    ph_fw(0x110F4400);       // 00 44 0f 11    movups [rcx+208], xmm15
    ph_fw(0x0000D0B9);       // b9 d0 00 00
    ph_fw(0x1A8B4800);       // 00 48 8b 1a    mov rbx, [rdx+0]
    ph_fw(0x086A8B48);       // 48 8b 6a 08    mov rbp, [rdx+8]
    ph_fw(0x107A8B48);       // 48 8b 7a 10    mov rdi, [rdx+16]
    ph_fw(0x18728B48);       // 48 8b 72 18    mov rsi, [rdx+24]
    ph_fw(0x20628B4C);       // 4c 8b 62 20    mov r12, [rdx+32]
    ph_fw(0x286A8B4C);       // 4c 8b 6a 28    mov r13, [rdx+40]
    ph_fw(0x30728B4C);       // 4c 8b 72 30    mov r14, [rdx+48]
    ph_fw(0x387A8B4C);       // 4c 8b 7a 38    mov r15, [rdx+56]
    ph_fw(0x4072100F);       // 0f 10 72 40    movups xmm6, [rdx+64]
    ph_fw(0x507A100F);       // 0f 10 7a 50    movups xmm7, [rdx+80]
    ph_fw(0x42100F44);       // 44 0f 10 42    movups xmm8, [rdx+96]
    ph_fw(0x100F4460);       // 60 44 0f 10    movups xmm9, [rdx+112]
    ph_fw(0x0F44704A);       // 4a 70 44 0f    movups xmm10, [rdx+128]
    ph_fw(0x00809210);       // 10 92 80 00
    ph_fw(0x0F440000);       // 00 00 44 0f    movups xmm11, [rdx+144]
    ph_fw(0x00909A10);       // 10 9a 90 00
    ph_fw(0x0F440000);       // 00 00 44 0f    movups xmm12, [rdx+160]
    ph_fw(0x00A0A210);       // 10 a2 a0 00
    ph_fw(0x0F440000);       // 00 00 44 0f    movups xmm13, [rdx+176]
    ph_fw(0x00B0AA10);       // 10 aa b0 00
    ph_fw(0x0F440000);       // 00 00 44 0f    movups xmm14, [rdx+192]
    ph_fw(0x00C0B210);       // 10 b2 c0 00
    ph_fw(0x0F440000);       // 00 00 44 0f    movups xmm15, [rdx+208]
    ph_fw(0x00D0BA10);       // 10 ba d0 00
    ph_fw(0x90900000);       // 00 00 90 90    nop ; nop
}

// Prepare a fresh fiber's context: identical to the System V half (rbp at
// offset 8, mc's epilogue is `leave; ret` here too), so the first swap lands
// at `tramp` with rsp = top-8 (congruent to 8 mod 16, as Win64 wants at a
// call boundary; the callee reserves its own 32-byte shadow space).
void ph_ctx_bootstrap(uptr ctx, uptr top, uptr tramp) {
    st64(top - 24, 0);
    st64(top - 16, tramp);
    st64(ctx + 8, top - 24);
}

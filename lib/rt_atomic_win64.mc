// rt_atomic_win64.mc -- the runtime's atomic words on x86-64 under the Windows
// x64 convention: the parameters arrive in rcx, rdx and r8, the answer leaves
// in rax. The same five instructions as lib/rt_atomic_x86_64.mc, which says
// how the words are cut, with the registers of this convention; mc's Win64
// prologue stores rcx, rdx and r8 to the frame and moves none of them.
//
// Every byte was assembled by
//   llvm-mc -triple=x86_64-linux-gnu -x86-asm-syntax=intel --show-encoding
// and tests/sweep_sync.py re-assembles them and checks mc emits them.
#opcode ph_w(v) v

// the value at p
i64 ph_at_load(uptr p) {
    ph_w(0x90018B48);       // 48 8b 01 90    mov rax, qword ptr [rcx] ; nop
}

// *p = v
void ph_at_store(uptr p, i64 v) {
    ph_w(0x90118748);       // 48 87 11 90    xchg qword ptr [rcx], rdx ; nop
}

// *p += d, answering the value before
i64 ph_at_add(uptr p, i64 d) {
    ph_w(0xF0D08948);       // 48 89 d0 f0    mov rax, rdx ; lock xadd qword ptr [rcx], rax
    ph_w(0x01C10F48);       // 48 0f c1 01
}

// if *p == e then *p = n: 1 when it was, 0 when it was not
i64 ph_at_cas(uptr p, i64 e, i64 n) {
    ph_w(0xF0D08948);       // 48 89 d0 f0    mov rax, rdx ; lock cmpxchg qword ptr [rcx], r8
    ph_w(0x01B10F4C);       // 4c 0f b1 01
    ph_w(0x0FC0940F);       // 0f 94 c0 0f    sete al ; movzx eax, al
    ph_w(0x9090C0B6);       // b6 c0 90 90    nop ; nop
}

// *p = v, answering the value before
i64 ph_at_xchg(uptr p, i64 v) {
    ph_w(0x48D08948);       // 48 89 d0 48    mov rax, rdx ; xchg qword ptr [rcx], rax
    ph_w(0x90900187);       // 87 01 90 90    nop ; nop
}

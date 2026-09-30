// rt_atomic_x86_64.mc -- the runtime's atomic words on x86-64 under the System V
// convention (Linux): the parameters arrive in rdi, rsi and rdx, the answer
// leaves in rax. lib/rt_atomic_win64.mc is the same five under the Windows x64
// convention (rcx, rdx, r8), and lib/rt_atomic_arm64.mc says what an atomic
// function is and why it is one.
//
// x86 instructions are one to fifteen bytes and `#opcode` folds one 32-bit
// word, so each body is a BYTE STREAM cut into four-byte words, little-endian
// (the first byte is the word's low byte), an instruction free to straddle a
// word boundary, the tail padded with `nop` (0x90). mc's prologue only stores
// the parameters to the frame and its epilogue (`leave; ret`) leaves rax alone.
// Beside each word: its four bytes, then the instructions that START in it.
//
// Ordering: x86-64 is TSO, so a plain load is an acquire and every `lock`ed
// read-modify-write (and `xchg` with memory, locked implicitly) is a full
// barrier: the store is an `xchg` so that it is sequentially consistent too.
//
// Every byte was assembled by
//   llvm-mc -triple=x86_64-linux-gnu -x86-asm-syntax=intel --show-encoding
// and tests/sweep_sync.py re-assembles them and checks mc emits them.
#opcode ph_w(v) v

// the value at p
i64 ph_at_load(uptr p) {
    ph_w(0x90078B48);       // 48 8b 07 90    mov rax, qword ptr [rdi] ; nop
}

// *p = v
void ph_at_store(uptr p, i64 v) {
    ph_w(0x90378748);       // 48 87 37 90    xchg qword ptr [rdi], rsi ; nop
}

// *p += d, answering the value before
i64 ph_at_add(uptr p, i64 d) {
    ph_w(0xF0F08948);       // 48 89 f0 f0    mov rax, rsi ; lock xadd qword ptr [rdi], rax
    ph_w(0x07C10F48);       // 48 0f c1 07
}

// if *p == e then *p = n: 1 when it was, 0 when it was not
i64 ph_at_cas(uptr p, i64 e, i64 n) {
    ph_w(0xF0F08948);       // 48 89 f0 f0    mov rax, rsi ; lock cmpxchg qword ptr [rdi], rdx
    ph_w(0x17B10F48);       // 48 0f b1 17
    ph_w(0x0FC0940F);       // 0f 94 c0 0f    sete al ; movzx eax, al
    ph_w(0x9090C0B6);       // b6 c0 90 90    nop ; nop
}

// *p = v, answering the value before
i64 ph_at_xchg(uptr p, i64 v) {
    ph_w(0x48F08948);       // 48 89 f0 48    mov rax, rsi ; xchg qword ptr [rdi], rax
    ph_w(0x90900787);       // 87 07 90 90    nop ; nop
}

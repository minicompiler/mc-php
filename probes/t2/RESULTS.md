# T2 -- exporting a symbol to a `.so`, and receiving a variadic call

Question (`docs/plan.md` § 4): can a binary written in mc be the host a php extension `.so` is
`dlopen`ed into -- can the `.so` resolve the Zend API against it, and can a function written in mc
be the callee of a variadic C call such as `zend_parse_parameters("ll", &a, &b)`?

Run: `sh probes/t2/run.sh`. Host: macOS 26 / arm64, mc 1.0.0 (`mc --host` = macos/aarch64),
Apple clang.

## Answers

| question | answer |
|---|---|
| a `.so` resolves an mc-defined symbol at `dlopen` | **yes**, on all three link roads, `mc --exe` included |
| `-export_dynamic` needed | **no** on macOS |
| an mc function can be a variadic C callee | **yes**, with no mc change |
| how many variadic arguments reach it | **4** (parameters 9..12), a hard ceiling |

```
$ sh probes/t2/run.sh
ext.so: 3 undefined mcphp_* symbols, filetype BUNDLE
(a) mc --exe
  mc --exe: OK
(b) mc build + ld -export_dynamic
  ld -export_dynamic: OK
(c) mc build + ld, no -export_dynamic
  ld (no flag): OK
(d) control: (a) with LC_DYSYMTAB.nextdefsym = 0
  nextdefsym=0: dlopen fails as expected (the classic symbol table is what dyld reads)
export tables:
  host-exe           trie=0 symtab-exports=3
  build/host-ld      trie=1 symtab-exports=3
T2: export yes (all three roads), variadic callee yes (4 arguments max)
```

## (a) The export -- and a correction to `docs/plan.md` § 5

`probes/t2/ext.c` is built the way a php extension is (`clang -bundle -undefined dynamic_lookup`),
so `_mcphp_cb` and `_mcphp_va` are undefined in it and dyld resolves them by flat lookup at
`dlopen`. All three hosts resolve them and the calls return the right numbers.

`docs/plan.md` § 5 said `mc --exe` "writes imports only (... Mach-O has no export trie)" and that
the `[linker]` road with `-export_dynamic` is what makes the host usable. **Both halves are wrong
on macOS.** The first:

```
$ otool -l host-exe | grep -E 'export_off|export_size|LC_DYLD_EXPORTS_TRIE'
     export_off 0
    export_size 0
```

There is indeed no export trie -- and it does not matter, because **dyld falls back to the classic
symbol table** (`LC_SYMTAB`, delimited by `LC_DYSYMTAB.iextdefsym` / `nextdefsym`) for a main
executable that has none. The control proves it is that table and not something else: patching
`nextdefsym` from 8 to 0 on a copy of the same binary, and re-signing it, turns the run into

```
dlopen failed: dlopen(./ext.so, 0x0002): symbol not found in flat namespace '_mcphp_cb'
```

while `nm -g` still lists the symbols (nm reads the type letter, not the dysymtab range). mc's exe
writer fills `iextdefsym`/`nextdefsym` correctly, so its output is a usable `dlopen` host as it
stands. **No mc change is needed for D2(b) on macOS, and no `[linker]` road either.**

The second half: `-export_dynamic` changes nothing here (road (c) is the same link without it and
behaves identically). On macOS an executable exports its global symbols by default; the flag is an
ELF habit. What the ELF side does is **not measured** -- this host is macos/aarch64 -- and the
`.dynsym`/JUMP_SLOT claim in § 5 stands untested until someone runs this probe on Linux.

## (b) The variadic callee

On Apple arm64 a caller of a variadic function passes **every** variadic argument on the stack, 8
bytes each, starting at `[sp]` at the call. That is not an assumption; it is what clang emitted for
`mcphp_va("ll", 7, 35)`:

```
_ext_call_va:
    sub  sp, sp, #0x20
    stp  x29, x30, [sp, #0x10]
    add  x29, sp, #0x10
    mov  x9, sp
    mov  x8, #0x7
    str  x8, [x9]          ; 7  at [sp + 0]
    mov  x8, #0x23
    str  x8, [x9, #0x8]    ; 35 at [sp + 8]
    adrp x0, ...           ; "ll" -- the only register argument
    bl   _mcphp_va
```

And an mc callee reads parameter 9 at `[x29 + 16]` and parameter 10 at `[x29 + 24]` (mc
`docs/reference/objects.md` § 4), where `[x29 + 16]` **is** the caller's `sp`, because
`stp x29, x30, [sp, #-16]!` is what moved it. So **variadic argument N is mc parameter 8 + N**, with
no mc change at all. `mc --dump-asm` of the callee declared with ten parameters:

```
_mcphp_va:
  stp x29, x30, [sp, #-16]!
  mov x29, sp
  sub sp, sp, #80
  str x0, [sp, #72]        ; fmt -- the real one
  str x1, [sp, #64]        ; x1..x7: junk, a variadic caller never sets them
  ...
  ldr x16, [x29, #16]      ; parameter 9  = variadic argument 1 = 7
  str x16, [sp, #8]
  ldr x16, [x29, #24]      ; parameter 10 = variadic argument 2 = 35
  str x16, [sp]
```

`ext_call_va` returns 735 from the mc callee and `ext_call_c_va` returns 735 from a C callee written
with `va_arg` in the same file: the two agree, so the mc callee is reading the same bytes the C ABI
puts there.

### The ceiling is four

mc's `MAXPARAMS` is 12 and a variadic callee spends one parameter on the format, leaving **9..12**:
four variadic arguments. `ext_call_va4("llll", 1, 2, 3, 4)` returns 1234 from both the mc and the C
callee. A thirteenth is refused at compile time, which is the ceiling stated by the compiler itself:

```
$ mc --exe p13.mc -o p13
p13.mc:2: at most 12 parameters
```

`zend_parse_parameters(execute_data, "ll", &a, &b)` is two named arguments plus one pointer per
format character, so **the reachable shape is `execute_data` + a format + 3 pointers** -- enough for
the great majority of internal functions, not for all of them. Three ways out, in the order they
cost: read the format and dispatch to arity-specific mc callees (still capped at 4); write the
`va_list` walk in mc by hand (`x29 + 16 + 8*n` is a plain address once more than 12 slots are
needed -- the register-save area does not exist on Apple arm64, every variadic argument is already
on the stack, so the walk is `ld64(base + 8*n)` and needs no mc feature); or a C trampoline. The
second is the one to take: it needs nothing from mc and has no ceiling.

## What is not measured here

- Linux/ELF: whether `mc --exe`'s ELF writer exports anything, and whether the SysV variadic ABI
  (which passes the first 8 integer variadic arguments in **registers**, not on the stack) lines up
  with mc's parameters at all. It will not line up the same way; on SysV variadic argument N is
  simply register argument N, so `mcphp_va(fmt, v1, v2, ...)` with the arguments in their natural
  positions is the shape there. Both hosts need their own probe.
- Windows: not applicable to this question yet.
- A variadic callee that receives **floats** or a struct by value: not measured. Zend's
  `zend_parse_parameters` takes only pointers after the format, so this may never matter.

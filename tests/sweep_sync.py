#!/usr/bin/env python3
"""The llvm-mc sweep over the runtime's atomic words (docs/threads.md § Step 4).

    python3 tests/sweep_sync.py        # LLVM=/path/to/llvm/bin, MC=mc

Each lib/rt_atomic_*.mc body is raw `ph_w(0x........)` words with the
instructions written beside them. Three things are checked per function:
  1. the instructions in the comments, assembled by llvm-mc, are byte for byte
     the words (AArch64: the whole body at once, so a branch's offset is
     checked too; x86-64: the comment's own hex bytes are the word's, and the
     instructions assemble to them);
  2. mc, compiling the file, emits exactly those words in that order;
  3. nothing else is in the body.
Exit 1 on any mismatch; exit 0 with a note when llvm-mc is not there.
"""
import os, re, shutil, subprocess, sys, tempfile

here = os.path.dirname(os.path.abspath(__file__))
root = os.path.dirname(here)
llvm = os.environ.get("LLVM", "")
def tool(n):
    p = os.path.join(llvm, n) if llvm else shutil.which(n)
    if not p:
        for d in ("/opt/homebrew/opt/llvm/bin", "/usr/local/opt/llvm/bin", "/usr/lib/llvm-18/bin"):
            if os.path.exists(os.path.join(d, n)): return os.path.join(d, n)
    return p
MC = os.environ.get("MC", "mc")
llvm_mc, objcopy = tool("llvm-mc"), tool("llvm-objcopy")
if not llvm_mc or not objcopy or not os.path.exists(llvm_mc):
    print("sweep: SKIPPED (no llvm-mc / llvm-objcopy)"); sys.exit(0)

FILES = (("lib/rt_atomic_arm64.mc", "aarch64-linux-gnu", "elf-obj"),
         ("lib/rt_atomic_x86_64.mc", "x86_64-linux-gnu", "elf-obj-x86_64"),
         ("lib/rt_atomic_win64.mc", "x86_64-linux-gnu", "coff-obj-x86_64"),
         # the stackful-fiber context switch (docs/threads.md § Step 5): the
         # same raw-word mechanism, one file per convention. ph_ctx_bootstrap
         # is ordinary mc code in the same file, not a word function, so the
         # name regex above skips it.
         ("lib/rt_fiber_arm64.mc", "aarch64-linux-gnu", "elf-obj"),
         ("lib/rt_fiber_x86_64.mc", "x86_64-linux-gnu", "elf-obj-x86_64"),
         ("lib/rt_fiber_win64.mc", "x86_64-linux-gnu", "coff-obj-x86_64"))
tmp = tempfile.mkdtemp()
fail = 0

def asm(triple, text, intel):
    s = os.path.join(tmp, "a.s"); o = os.path.join(tmp, "a.o"); b = os.path.join(tmp, "a.bin")
    open(s, "w").write((".intel_syntax noprefix\n" if intel else "") + text + "\n")
    subprocess.run([llvm_mc, "-triple=" + triple, "-filetype=obj", s, "-o", o], check=True)
    subprocess.run([objcopy, "-O", "binary", "--only-section=.text", o, b], check=True)
    return open(b, "rb").read()

def le(words):
    return b"".join(w.to_bytes(4, "little") for w in words)

for path, triple, backend in FILES:
    src = open(os.path.join(root, path)).read().split("\n")
    funcs = []; cur = None
    for line in src:
        m = re.match(r"^(?:i64|void) (ph_at_\w+|ph_ctx_swap)\(", line)
        if m: cur = [m.group(1), [], []]; funcs.append(cur); continue
        if cur is None: continue
        m = re.match(r"^    ph_f?w\((0x[0-9A-Fa-f]{8})\);\s*//(.*)$", line)
        if m: cur[1].append(int(m.group(1), 16)); cur[2].append(m.group(2)); continue
        if line.startswith("}"):
            m = re.match(r"^}\s*//\s*(\d+:)\s*$", line)
            if m: cur[2].append(" " + m.group(1))
            cur = None; continue
        if line.strip(): print("  FAIL %s %s: a line that is not a word: %s" % (path, cur[0], line.strip())); fail = 1
    # mc's own emission: the object's text holds every body, in order
    obj = os.path.join(tmp, "m.o"); objbin = os.path.join(tmp, "m.bin")
    r = subprocess.run([MC, "--backend=" + backend, os.path.join(root, path), "-o", obj], capture_output=True, text=True)
    text = b""
    if r.returncode == 0:
        sect = ".text"
        subprocess.run([objcopy, "-O", "binary", "--only-section=" + sect, obj, objbin], check=True)
        text = open(objbin, "rb").read()
    else:
        print("  FAIL %s: mc refused it: %s" % (path, r.stderr.strip())); fail = 1
    nins = 0
    for name, words, comments in funcs:
        want = le(words)
        if text and want not in text:
            print("  FAIL %s %s: mc does not emit the words" % (path, name)); fail = 1
        if "x86" in triple:
            hexb = bytes(int(x, 16) for c in comments for x in re.match(r"\s*((?:[0-9a-f]{2} ?){4})", c).group(1).split())
            ins = [i.strip() for c in comments for i in re.sub(r"^\s*(?:[0-9a-f]{2} ?){4}", "", c).split(";") if i.strip()]
            got = asm(triple, "\n".join(ins), True)
            ok = hexb == want and got == want
        else:
            ins = [c.strip() for c in comments if c.strip()]
            got = asm(triple, "\n".join(ins), False)
            ok = got == want
        nins += len([i for i in ins if not re.fullmatch(r"\d+:", i)])
        if not ok:
            print("  FAIL %s %s: the words are %s, the instructions assemble to %s" % (path, name, want.hex(), got.hex())); fail = 1
    print("  %s: %d functions, %d instructions, %d words" % (path, len(funcs), nins, sum(len(f[1]) for f in funcs)))
shutil.rmtree(tmp)
print("sweep: %s" % ("FAIL" if fail else "ok"))
sys.exit(fail)

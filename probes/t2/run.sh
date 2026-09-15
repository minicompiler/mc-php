#!/bin/sh
# T2 -- can an mc binary export a symbol to a .so, and receive a variadic call?
#
# Builds ext.so exactly as a php extension is built (-bundle -undefined
# dynamic_lookup: the host's symbols are UNDEFINED and resolved at dlopen time
# by flat lookup), then builds the mc host three ways and runs each:
#
#   (a) mc --exe                       -- the built-in Mach-O exe writer
#   (b) mc build, ld -export_dynamic   -- the [linker] road
#   (c) mc build, ld with no such flag -- the control
#
# and a fourth binary, (a) with LC_DYSYMTAB.nextdefsym patched to 0, as the
# control that says WHICH table dyld reads.
#
# Exits 0 only when every road was built and produced the expected numbers.
set -eu
LC_ALL=C
export LC_ALL

cd "$(dirname "$0")"
MC=${MC:-mc}
CC=${CC:-clang}

want='dlopen OK
  ext_call_cb = 42 (want 42) OK
  ext_call_va = 735 (want 735) OK
  ext_call_c_va = 735 (want 735) OK
  ext_call_va4 = 1234 (want 1234) OK
  ext_call_c_va4 = 1234 (want 1234) OK
T2 OK'

"$CC" -bundle -undefined dynamic_lookup -o ext.so ext.c
echo "ext.so: $(nm -u ext.so | grep -c mcphp) undefined mcphp_* symbols, filetype $(otool -hv ext.so | tail -1 | awk '{print $5}')"

fail=0
check() { # name binary
    if [ ! -x "$2" ]; then echo "  $1: NOT BUILT"; fail=1; return; fi
    got=$("$2" ./ext.so 2>&1) || true
    if [ "$got" = "$want" ]; then echo "  $1: OK"; else echo "  $1: MISMATCH"; echo "$got" | sed 's/^/    /'; fail=1; fi
}

echo "(a) mc --exe"
"$MC" --exe host.mc -o host-exe
check "mc --exe" ./host-exe

echo "(b) mc build + ld -export_dynamic"
"$MC" build . >/dev/null
check "ld -export_dynamic" ./build/host-ld

echo "(c) mc build + ld, no -export_dynamic"
"$MC" build . --config noexport.toml >/dev/null
check "ld (no flag)" ./build/host-ld-noexport

echo "(d) control: (a) with LC_DYSYMTAB.nextdefsym = 0"
python3 - <<'PY'
import struct, shutil
shutil.copy('host-exe', 'host-exe-nodysym')
b = bytearray(open('host-exe-nodysym', 'rb').read())
ncmds = struct.unpack_from('<I', b, 16)[0]
off = 32
for _ in range(ncmds):
    cmd, size = struct.unpack_from('<II', b, off)
    if cmd == 0xb:                      # LC_DYSYMTAB
        struct.pack_into('<I', b, off + 20, 0)   # nextdefsym
        break
    off += size
open('host-exe-nodysym', 'wb').write(bytes(b))
PY
codesign -f -s - host-exe-nodysym >/dev/null 2>&1
if ./host-exe-nodysym ./ext.so 2>&1 | grep -q 'symbol not found in flat namespace'; then
    echo "  nextdefsym=0: dlopen fails as expected (the classic symbol table is what dyld reads)"
else
    echo "  nextdefsym=0: UNEXPECTED -- it still resolved"; fail=1
fi

echo "export tables:"
for b in host-exe build/host-ld; do
    printf '  %-18s trie=%s symtab-exports=%s\n' "$b" \
        "$(otool -l $b | grep -c LC_DYLD_EXPORTS_TRIE)" \
        "$(dyld_info -exports $b 2>/dev/null | grep -c mcphp)"
done

[ "$fail" = 0 ] || { echo "T2: FAILED"; exit 1; }
echo "T2: export yes (all three roads), variadic callee yes (4 arguments max)"

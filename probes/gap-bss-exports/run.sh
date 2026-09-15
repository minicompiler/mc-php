#!/bin/sh
# An mc gap, reported to mc and not worked around here (docs/plan.md section 5).
#
# An `mc --exe` Mach-O executable has no LC_DYLD_EXPORTS_TRIE, so dyld resolves
# a dlopen'd bundle's flat-namespace imports against the classic symbol table.
# That works -- until __bss makes __DATA's vmsize exceed its filesize by a whole
# 16 KiB page. From then on __LINKEDIT's offset from the mach header in MEMORY
# (vmaddr - textVmaddr) no longer equals its offset in the FILE (fileoff), the
# symbol table is read out of __DATA's zerofill instead, and EVERY symbol the
# binary exports becomes invisible to dlopen. The binary itself still runs.
#
# Prints one line per __bss size and exits 0 only when it reproduced the break.
set -eu
cd "$(dirname "$0")"
MC=${MC:-mc}
CC=${CC:-clang}

"$CC" -bundle -flat_namespace -undefined suppress -o caller.so caller.c 2>/dev/null

seen_ok=0
seen_fail=0
for n in 8192 16000 16384 65536; do
    sed "s/BSS_BYTES/$n/" host.mc > host-$n.mc
    "$MC" --exe host-$n.mc -o host-$n >/dev/null
    got=$(./host-$n ./caller.so 2>&1 | head -1)
    facts=$(python3 - "host-$n" <<'PY'
import re, subprocess, sys
o = subprocess.run(['otool', '-l', sys.argv[1]], capture_output=True, text=True).stdout
segs = {m.group(1): (int(m.group(2), 16), int(m.group(3), 16), int(m.group(4)), int(m.group(5)))
        for m in re.finditer(r'segname (\S+)\n\s+vmaddr (0x[0-9a-f]+)\n\s+vmsize (0x[0-9a-f]+)\n\s+fileoff (\d+)\n\s+filesize (\d+)', o)}
text, data, le = segs['__TEXT'], segs['__DATA'], segs['__LINKEDIT']
print("__DATA vmsize=%d filesize=%d | __LINKEDIT vmoff=%d fileoff=%d"
      % (data[1], data[3], le[0] - text[0], le[2]))
PY
)
    printf '%-7s %s -> %s\n' "bss=$n" "$facts" "$got"
    case "$got" in
        42) seen_ok=1 ;;
        FAIL*) seen_fail=1 ;;
    esac
done

[ "$seen_ok" = 1 ]   || { echo "gap: the small-bss build did not work -- something else is wrong"; exit 1; }
[ "$seen_fail" = 1 ] || { echo "gap: NOT REPRODUCED -- mc may have fixed it"; exit 1; }
echo "gap reproduced: exports vanish once __DATA's zerofill reaches one page"

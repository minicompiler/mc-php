#!/bin/sh
# Every name mc-php uses from mc that mc does not freeze, checked against the
# installed mc (tests/mcnames.mc lists them, docs/mc-internals.md says why).
#
#     sh tests/mcnames.sh            # MC=/path/to/mc to use another mc
#     sh tests/mcnames.sh --strict   # also fail when the installed mc is not
#                                    # the version tests/mcnames.mc pins (CI)
#
# The probe is compiled, never run. A name the installed mc lacks, or a
# function whose parameter count changed, makes mc refuse that line; the
# script names it, blanks the line, and compiles again, so one run reports
# every such name.
set -u
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/.." && pwd)
cd "$root"
MC=${MC:-mc}
strict=0
[ "${1:-}" = --strict ] && strict=1
probe=tests/mcnames.mc
pin=$(sed -n 's|^// mc-version: *||p' "$probe")
have=$("$MC" --version 2>/dev/null | head -1 | sed 's/^mc //' | tr -d '\r')
tmp=$(mktemp -d "${TMPDIR:-/tmp}/mcnames.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fail=0
n=$(grep -c '^    .*// mcname ' "$probe")
echo "== mc names mc-php uses and mc does not freeze: $n, against mc $have (pinned: $pin) =="
if [ "$have" != "$pin" ]; then
    if [ "$strict" = 1 ]; then echo "  FAIL the installed mc is $have; mc-php is verified against mc $pin"; fail=1
    else echo "  note: the installed mc is $have; mc-php is verified against mc $pin"; fi
fi
cp "$probe" "$tmp/p.mc"
missing=0
while :; do
    if "$MC" "$tmp/p.mc" -o "$tmp/p.o" > "$tmp/err" 2>&1; then break; fi
    line=$(sed -n 's|^.*/p\.mc:\([0-9][0-9]*\):.*$|\1|p' "$tmp/err" | head -1)
    if [ -z "$line" ]; then
        echo "  FAIL mc $have refuses the probe outside its list of names:"; sed 's/^/      /' "$tmp/err"; fail=1; break
    fi
    name=$(sed -n "${line}p" "$tmp/p.mc" | sed -n 's|^.*// mcname \([^ ]*\) \([^ ]*\).*$|\1 \2|p')
    [ -n "$name" ] || { echo "  FAIL mc $have refuses probe line $line:"; sed 's/^/      /' "$tmp/err"; fail=1; break; }
    set -- $name
    what="a function of $2 parameters"
    case "$2" in define) what="a #define" ;; global) what="a global" ;; esac
    echo "  FAIL mc $have: $1, $what, which mc-php uses -- $(sed 's|^.*/p\.mc:[0-9]*: *||' "$tmp/err" | head -1)"
    missing=$((missing + 1)); fail=1
    sed -i.bak "${line}s|.*||" "$tmp/p.mc"
done
[ "$fail" = 0 ] || { [ "$missing" -gt 0 ] && echo "  mcnames: $missing name(s) mc $have does not have as mc-php uses them; see docs/mc-internals.md"; exit 1; }
echo "  mcnames: all $n, each with the parameter count mc-php relies on"

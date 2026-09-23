#!/bin/sh
# The carve's own proof, and it has a short life BY DESIGN.
#
#     sh tests/carve.sh
#
# src/*.mc was cut out of probes/t10/php.mc and lib/php_rt.mc out of
# probes/t10/php_rt.txt. This asserts that the cut moved nothing a compiled
# program can observe, by the only test that settles it: build the frozen
# probe's compiler and this project's compiler from the SAME runtime bytes,
# and compare the two binaries byte for byte.
#
# The basename matters. An mc --exe binary's ad-hoc signature carries the
# OUTPUT FILE's basename as its identifier (mc's M11), so two builds must be
# written to the same name in different directories or they differ by exactly
# the length of the name.
#
# It also reports what DOES differ in the real tree: lib/php_rt.mc's first
# lines, which name the file and where it came from. They are a comment, so
# no program sees them; they are inside a #embed, so the compiler binary does.
#
# DELETE THIS SCRIPT with the first commit that changes what the compiler
# does. It asserts the carve and nothing else, and once src/ has moved on it
# is asserting that the project has not.
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/.." && pwd)
cd "$root"
MC=${MC:-mc}
[ -f probes/t10/php.mc ] || { echo "carve: the probe is gone -- delete this script"; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/a" "$tmp/b"

# (a) the frozen probe, built as the probe builds it
"$MC" --exe probes/t10/mc-php.mc -o "$tmp/a/mc-php"

# (b) this project's sources, with the probe's runtime bytes in place of
#     ours -- so the only thing under test is the 15-way split of php.mc
cp -R src "$tmp/src"
cp probes/t10/php_rt.txt "$tmp/php_rt.mc"
mkdir -p "$tmp/lib" && mv "$tmp/php_rt.mc" "$tmp/lib/php_rt.mc"
( cd "$tmp" && "$MC" --exe src/mc-php.mc -o b/mc-php )

if cmp -s "$tmp/a/mc-php" "$tmp/b/mc-php"; then
    echo "  carve: src/*.mc rebuilds probes/t10/php.mc byte for byte"
else
    echo "  carve: THE SPLIT MOVED SOMETHING -- the two binaries differ"
    exit 1
fi

# and the one real difference, named with its size
a=$(wc -c < probes/t10/php_rt.txt)
b=$(wc -c < lib/php_rt.mc)
sed -n '7,$p' lib/php_rt.mc > "$tmp/ours"
sed -n '3,$p' probes/t10/php_rt.txt > "$tmp/theirs"
if cmp -s "$tmp/ours" "$tmp/theirs"; then
    echo "  carve: lib/php_rt.mc differs from the probe's only in its header" \
         "($a -> $b bytes, all of it comment)"
else
    echo "  carve: lib/php_rt.mc differs from probes/t10/php_rt.txt BELOW the header"
    exit 1
fi

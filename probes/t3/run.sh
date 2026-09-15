#!/bin/sh
# T3 -- does a real php extension run on a zval built in mc?
#
# Three steps:
#   1. the layout gate: layout.c prints every offset with offsetof/sizeof from
#      the installed php headers; every #define in zend.mc that names one must
#      match it. A layout fact in mc is measured, never assumed.
#   2. the run: load php-src's own ctype.so, find ctype_digit through its
#      zend_module_entry, and call its handler on zvals mc built.
#   3. the oracle: the same five inputs under `php`, compared.
#
# Exits 0 only when the layout matched, the extension ran and php agreed.
set -eu
LC_ALL=C
export LC_ALL

cd "$(dirname "$0")"
MC=${MC:-mc}
CC=${CC:-clang}
PHP=${PHP:-php}
PHP_CONFIG=${PHP_CONFIG:-php-config}

so=../../php-src/ext/ctype/modules/ctype.so
[ -f "$so" ] || { echo "T3: no ctype.so -- run probes/t1/run.sh first"; exit 1; }

# --- 1. the layout gate ---------------------------------------------------
"$CC" -o layout layout.c $("$PHP_CONFIG" --includes)
./layout > layout.txt

n=0
bad=0
while read -r name val; do
    mine=$(sed -n "s/^#define  *$name  *\([0-9][0-9]*\).*/\1/p" zend.mc | head -1)
    [ -n "$mine" ] || continue
    n=$((n + 1))
    if [ "$mine" != "$val" ]; then
        echo "  LAYOUT MISMATCH $name: zend.mc says $mine, the header says $val"
        bad=1
    fi
done < layout.txt
[ "$bad" = 0 ] || { echo "T3: layout does not match the headers"; exit 1; }
[ "$n" -ge 25 ] || { echo "T3: only $n layout facts checked, expected at least 25"; exit 1; }
echo "layout: $n facts match the php headers"

# --- 2. the run -----------------------------------------------------------
# The [linker] road. `mc --exe` is measured separately below: it produces a
# binary whose exported symbols dyld cannot see, which is the gap this probe
# found (see RESULTS.md and docs/plan.md section 5).
"$MC" build . > /dev/null
./build/host-ld "$so" > got.txt 2>&1 || { echo "T3: the run failed"; cat got.txt; exit 1; }
cat got.txt

# --- 3. the oracle --------------------------------------------------------
"$PHP" -d display_errors=0 -d error_reporting=0 \
    -r 'foreach (["123","12a","",53,97] as $v) { echo ctype_digit($v) ? "true" : "false", "\n"; }' \
    2>/dev/null > oracle.txt
awk '/ctype_digit\(.*\) -> /{print $3}' got.txt > mine.txt
if ! cmp -s mine.txt oracle.txt; then
    echo "T3: php disagrees"
    diff oracle.txt mine.txt || true
    exit 1
fi
echo "oracle: php agrees on all $(wc -l < oracle.txt | tr -d ' ') inputs"

# --- 4. the mc --exe road, recorded ---------------------------------------
"$MC" --exe host.mc -o host-exe
if ./host-exe "$so" > exe.txt 2>&1; then
    echo "mc --exe: WORKS (the gap in docs/plan.md section 5 is gone)"
else
    echo "mc --exe: $(head -1 exe.txt)"
fi

echo "T3: yes -- a real ctype.so ran ctype_digit on a zval built in mc"

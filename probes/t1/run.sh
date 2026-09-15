#!/bin/sh
# T1 -- the size of the Zend shim.
#
# Builds real php-src extensions as shared objects and measures, per .so, which
# symbols it imports from the php binary (the Zend/PHP API a mc-php host would
# have to provide) and which come from libc/the system.
#
# The split is not a name heuristic: a symbol is "Zend/PHP API" iff the `php`
# binary itself exports it, which is exactly what dyld resolves it against. The
# function/data column comes from nm's type letter on the php binary (T = text,
# D/S = data), so a global like _executor_globals is counted as data.
#
# Writes probes/t1/out/ (per-.so lists + the union) and prints the counts.
# Exits 0 only when at least one .so was measured.
set -eu
LC_ALL=C
export LC_ALL

root=$(cd "$(dirname "$0")/../.." && pwd)
src=$root/php-src
out=$(dirname "$0")/out
out=$(cd "$(dirname "$out")" && pwd)/out

PHP_CONFIG=${PHP_CONFIG:-php-config}
EXTS=${EXTS:-"ctype pdo_sqlite mbstring"}

command -v "$PHP_CONFIG" >/dev/null || { echo "T1: no php-config"; exit 1; }
[ -d "$src" ] || { echo "T1: no php-src -- git clone --depth 1 --branch php-8.5.10 https://github.com/php/php-src $src"; exit 1; }

phpbin=$("$PHP_CONFIG" --prefix)/bin/php
[ -x "$phpbin" ] || { echo "T1: no php binary at $phpbin"; exit 1; }

# re2c is a php-src build dependency (pdo_sqlite's SQL parser is generated).
RE2C=${RE2C:-re2c}

mkdir -p "$out"

# The php binary's exports, with the type letter: "<symbol> <T|D|S>".
nm -gU "$phpbin" | awk '$2 ~ /^[TDSB]$/ {print $3, $2}' | sort > "$out/php-exports.txt"

built=""
for ext in $EXTS; do
    d=$src/ext/$ext
    [ -d "$d" ] || { echo "T1: skip $ext (no such ext)"; continue; }
    so=$d/modules/$ext.so
    if [ ! -f "$so" ]; then
        ( cd "$d" \
          && phpize >/dev/null 2>&1 \
          && ./configure --with-php-config="$PHP_CONFIG" >/dev/null 2>&1 \
          && make -j4 RE2C="$RE2C" CPPFLAGS="${T1_CPPFLAGS:--I/opt/homebrew/opt/pcre2/include}" >/dev/null 2>&1 ) \
          || { echo "T1: skip $ext (build failed; see $d)"; continue; }
    fi
    [ -f "$so" ] || { echo "T1: skip $ext (no $so)"; continue; }

    nm -u "$so" | grep -v '^dyld_stub_binder$' | sort > "$out/$ext.undef.txt"
    join "$out/$ext.undef.txt" "$out/php-exports.txt" > "$out/$ext.zend.txt"
    cut -d' ' -f1 "$out/php-exports.txt" > "$out/.names"
    comm -23 "$out/$ext.undef.txt" "$out/.names" > "$out/$ext.system.txt"
    built="$built $ext"
done

[ -n "$built" ] || { echo "T1: nothing built"; exit 1; }

cat $(for e in $built; do echo "$out/$e.zend.txt"; done) | sort -u > "$out/union.zend.txt"
awk '$2 == "T" {print $1}' "$out/union.zend.txt" > "$out/union.zend.functions.txt"
awk '$2 != "T" {print $1}' "$out/union.zend.txt" > "$out/union.zend.data.txt"

printf '%-14s %8s %8s %8s %8s\n' ext total zend-fn zend-data system
for e in $built; do
    printf '%-14s %8d %8d %8d %8d\n' "$e" \
        "$(wc -l < "$out/$e.undef.txt")" \
        "$(awk '$2 == "T"' "$out/$e.zend.txt" | wc -l)" \
        "$(awk '$2 != "T"' "$out/$e.zend.txt" | wc -l)" \
        "$(wc -l < "$out/$e.system.txt")"
done
printf '%-14s %8s %8d %8d %8s\n' UNION "" \
    "$(wc -l < "$out/union.zend.functions.txt")" \
    "$(wc -l < "$out/union.zend.data.txt")" ""
echo "T1: shim = $(wc -l < "$out/union.zend.txt" | tr -d ' ') symbols over$built"

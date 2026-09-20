#!/bin/sh
# D8 (b): the T9 workload timed under `php` and as an mc-php binary.
#
# The programs are ordinary PHP and run under `php` unchanged:
#   main.php   a JSON round trip (ext/json, written in mc by T9), a template
#              renderer (strpos/substr/string building) and a sort-heavy pass
#   heavy.php  the same without the JSON phase and with more work, because
#              the 48 MiB arena (D7, no free) is what caps the JSON phase
#
# Interleaved repetitions, the median of each, and the ratio php / mc-php --
# with php's own start-up timed beside them, so the second ratio says what
# the WORK costs. It prints the numbers and exits 0 only when it measured.
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../../.." && pwd)
cd "$root"
MC=${MC:-mc}
PHP=${PHP:-php}
REPS=${REPS:-7}

[ -x probes/t9/mc-php ] || { echo "bench: no probes/t9/mc-php -- run probes/t9/run.sh"; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

for prog in main.php heavy.php; do
    rm -f "$tmp/bench"
    probes/t9/mc-php --exe "probes/t9/bench/$prog" -o "$tmp/bench"
    a=$("$PHP" "probes/t9/bench/$prog")
    b=$("$tmp/bench")
    if [ "$a" != "$b" ]; then
        echo "bench: php says '$a', mc-php says '$b' -- not comparable"
        exit 1
    fi
    printf '\n== %s ==\n  both answer %s\n' "$prog" "$a"
    ls -l "$tmp/bench" | awk '{ printf "  the binary is %s bytes\n", $5 }'
    python3 probes/t9/bench/time2.py "$PHP" "$tmp/bench" "$REPS" "probes/t9/bench/$prog"
done

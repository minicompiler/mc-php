#!/bin/sh
# D8 (b): the T10 workload timed under `php` and as an mc-php binary.
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

[ -x probes/t10/mc-php ] || { echo "bench: no probes/t10/mc-php -- run probes/t10/run.sh"; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# D8 (b) wants a COMMITTED, DATED record and not a line that scrolls past,
# so the run writes one; `--no-record` is for a scratch run.
stamp=$(date -u +%Y-%m-%d)
rec=probes/t10/bench/results/$stamp.json
[ "${1:-}" = "--no-record" ] && rec=$tmp/scratch.json
mkdir -p "$(dirname "$rec")"
{
    printf '{\n  "date": "%s",\n' "$stamp"
    printf '  "host": "%s",\n' "$(uname -srm)"
    printf '  "php": "%s",\n' "$("$PHP" -r 'echo PHP_VERSION;')"
    printf '  "mc": "%s",\n' "$($MC --version)"
    printf '  "reps": %s,\n  "programs": [\n' "$REPS"
} > "$rec"
first=1

for prog in main.php heavy.php; do
    rm -f "$tmp/bench"
    if ! probes/t10/mc-php --exe "probes/t10/bench/$prog" -o "$tmp/bench"; then
        echo "bench: $prog does not compile"
        exit 1
    fi
    # BYTE for byte and the exit status, both: `$(...)` strips every trailing
    # newline, which is the very defect this probe fixed in the fixture gate
    # (docs/review-backlog.md section 1) and which was still here. A binary
    # with a missing or extra final newline was timed as comparable.
    #
    # And the STATUS is taken inside an `if`, because `set -e` is on: a bare
    # `cmd > out 2> err; ae=$?` never reaches the assignment when cmd fails,
    # it ends the script -- so the exit-code half of this gate was
    # unreachable for any workload that exits non-zero. run.sh's D8 gate was
    # fixed for this in round seven and THIS was reported as fixed with it
    # and was not; the reviewer of #9 was right and the claim was wrong.
    ae=0
    if "$PHP" "probes/t10/bench/$prog" > "$tmp/a.out" 2> "$tmp/a.err"
    then :; else ae=$?; fi
    be=0
    if "$tmp/bench" > "$tmp/b.out" 2> "$tmp/b.err"
    then :; else be=$?; fi
    if ! cmp -s "$tmp/a.out" "$tmp/b.out" || ! cmp -s "$tmp/a.err" "$tmp/b.err" \
       || [ "$ae" != "$be" ]; then
        printf 'bench: %s -- php exit %s, mc-php exit %s, and the streams differ:\n' \
            "$prog" "$ae" "$be"
        diff -u "$tmp/a.out" "$tmp/b.out" | head -10
        diff -u "$tmp/a.err" "$tmp/b.err" | head -10
        echo "bench: not comparable"
        exit 1
    fi
    a=$(cat "$tmp/a.out")
    printf '\n== %s ==\n  both answer %s (exit %s, both streams byte for byte)\n' \
        "$prog" "$a" "$ae"
    size=$(ls -l "$tmp/bench" | awk '{ print $5 }')
    printf '  the binary is %s bytes\n' "$size"
    python3 probes/t10/bench/time2.py "$PHP" "$tmp/bench" "$REPS" \
        "probes/t10/bench/$prog" --json "$tmp/t.json"
    [ "$first" = 1 ] || printf ',\n' >> "$rec"
    first=0
    # the row is what time2.py MEASURED, not a re-parse of what it printed
    python3 -c 'import json,sys; o=json.load(open(sys.argv[1]));
o["answer"]=sys.argv[2]; o["bytes"]=int(sys.argv[3]);
sys.stdout.write("    " + json.dumps(o))' "$tmp/t.json" "$a" "$size" >> "$rec"
done
printf '\n  ]\n}\n' >> "$rec"
printf '\n  recorded: %s\n' "$rec"

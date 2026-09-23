#!/bin/sh
# The fast gates -- everything but the 21k .phpt grid.
#
#     sh tests/run.sh            # builds build/mc-php if it is not there
#     BIN=/path/to/mc-php sh tests/run.sh
#
# The grid is tests/grid.sh and takes about half an hour; it is the number
# this project answers with and it is not a per-commit gate. These five are:
#
#   d8check      every .php in the project is in a regime with an obligation
#   lencheck     every hand-counted string length in src/ and lib/ is right
#   aritycheck   every library row's callee exists with that many parameters
#   fixtures     tests/g/*.php byte for byte php's, on BOTH streams and the
#                exit code
#   refusals     tests/r/*.php parse under php and are refused BY NAME by
#                mc-php, exit 3
#   D8 (a)       the workload's TestCase RUN in both worlds, every declared
#                test* executed in each, and the two outputs identical
#   D8 (b)       tests/bench/bench10.sh, which refuses to time main.php and
#                heavy.php unless the two worlds answer the same
#
# The last two are why d8check.py alone is not enough: it is a STATIC
# classifier and proves reachability, not execution. A broken workload test
# would pass it. (Found by the reviewer of #10.)
#
# Exits 0 only when every one of them passed.
set -u
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/.." && pwd)
cd "$root"
MC=${MC:-mc}
BIN=${BIN:-build/mc-php}
export BIN
fail=0

"$MC" --version
${PHP:-php} --version | head -1

echo ""
echo "== the sources =="
python3 tests/d8check.py    || fail=1
python3 tests/lencheck.py   || fail=1
python3 tests/aritycheck.py || fail=1

echo ""
echo "== the compiler =="
# ALWAYS, unless the caller named a binary of its own. Building only when the
# file is missing tests a stale compiler after every edit to src/, which is
# the one failure a gate must not have. It costs about two seconds.
#
# `mc build` unlinks the output first, which it has to: mc --exe over a signed
# executable at the same inode makes the kernel SIGKILL its next run (mc's M12
# note). One more reason the build belongs to mc.toml and not to a shell line.
if [ "$BIN" = "build/mc-php" ]; then
    "$MC" build || fail=1
else
    echo "  BIN was given: $BIN (not rebuilding)"
fi
[ -x "$BIN" ] || { echo "  no $BIN"; exit 1; }
ls -l "$BIN" | awk '{ printf "  %s  %s bytes\n", "'"$BIN"'", $5 }'

echo ""
echo "== the fixtures and the refusals =="
sh tests/fixtures.sh || fail=1

echo ""
echo "== D8 (a): the workload's tests, RUN in both worlds =="
# d8check.py above is static: it proves every .php is in a regime and that the
# runner NAMES every test* the class declares. It cannot prove one was
# invoked. This does, and it is the probe's own step 10 carved across.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# The SAME bounded runner the fixture gate and the bench use. Without it this
# was the only unbounded gate in the repository: a compiler regression that
# emits a non-terminating binary, or a run.php that hangs, would wait for ever
# and never reach the cleanup. `lim` kills the process GROUP -- tests/mcphp.sh
# starts the compiler as a child -- and says out of band whether the alarm
# fired, because a program may legitimately exit(124). (Found by the reviewer
# of #10, second round.)
. tests/lim.sh
LIM_SECS=${LIM_SECS:-120}
want=$(grep -c 'function[[:space:]][[:space:]]*test' tests/bench/WorkloadTest.php)
# The SAME sanitized environment on both sides: tests/mcphp.sh removes the
# harness's own three variables before it execs the program, so php must not
# keep them either or the two halves run under different inputs.
pe=0
if lim env -u MCPHP_OUT -u MCPHP_BIN -u MCPHP_TMP \
    ${PHP:-php} tests/bench/run.php > "$tmp/p.out" 2> "$tmp/p.err"
then :; else pe=$?; fi
pto=$timedout
me=0
if MCPHP_OUT=$tmp/d8.bin MCPHP_BIN=$(cd "$(dirname "$BIN")" && pwd)/$(basename "$BIN") \
    lim sh tests/mcphp.sh tests/bench/run.php > "$tmp/m.out" 2> "$tmp/m.err"
then :; else me=$?; fi
rm -f "$tmp/d8.bin" "$tmp/d8.bin.out" "$tmp/d8.bin.err"
# The ALARM says so, not the exit code: a program may legitimately exit(124),
# and reading the code as the alarm would call a real 124 a hang and a hang in
# both worlds an agreement.
[ "$pto" != yes ]      || { echo "  php timed out"; fail=1; }
[ "$timedout" != yes ] || { echo "  mc-php timed out"; fail=1; }
pok=$(grep -c '^ok ' "$tmp/p.out" || true)
mok=$(grep -c '^ok ' "$tmp/m.out" || true)
printf '  php     %s\n  mc-php  %s\n' "$(tail -1 "$tmp/p.out")" "$(tail -1 "$tmp/m.out")"
printf '  %s test* declared; php ran %s, mc-php ran %s\n' "$want" "$pok" "$mok"
[ "$pe" = 0 ]      || { printf '  php exited %s\n' "$pe"; fail=1; }
[ "$me" = 0 ]      || { printf '  mc-php exited %s\n' "$me"; fail=1; }
[ "$pok" = "$want" ] || { echo "  php did not run every declared test"; fail=1; }
[ "$mok" = "$want" ] || { echo "  mc-php did not run every declared test"; fail=1; }
# A last line ending in "0 failed" is satisfied by a runner that executed
# nothing, which is why the count above is checked too -- and since #10 the
# runner also EXITS non-zero, which is what $pe and $me read.
if [ -s "$tmp/p.err" ] || [ -s "$tmp/m.err" ]; then
    echo "  a world wrote to stderr:"; sed 's/^/    /' "$tmp/p.err" "$tmp/m.err"; fail=1
fi
if ! cmp -s "$tmp/p.out" "$tmp/m.out"; then
    echo "  the two worlds printed different things:"
    diff -u "$tmp/p.out" "$tmp/m.out" | sed -n '3,14p' | sed 's/^/    /'
    fail=1
fi
# NOT phpunit and NOT `mc-php test`, and the reason is on record rather than
# implied: phpunit is not installed (tests/bench/shim.php's note) and
# `mc-php test` does not exist -- docs/plan.md D8 (a) names it as the
# mechanism the COMPILER will provide. Until it does, the method list is
# written by hand in run.php and d8check.py is what keeps it honest.
echo "  NOT phpunit and NOT \`mc-php test\`: docs/plan.md D8 (e) is the exemption."

echo ""
echo "== D8 (b): the bench, php against the mc-php binary =="
# It is a TIMING run, but what it GATES is correctness: it refuses to time
# main.php and heavy.php unless the two worlds agree on both streams and the
# exit code, which is two more whole programs the fixtures do not cover. The
# ratios it prints are informational here; --no-record keeps a CI run from
# writing a dated row.
sh tests/bench/bench10.sh --no-record || fail=1

echo ""
[ "$fail" = 0 ] || { echo "tests: something failed"; exit 1; }
echo "tests: the fast gates passed (the grid is tests/grid.sh)"

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
if [ ! -x "$BIN" ]; then
    # mc --exe must not overwrite a signed executable at the same inode: the
    # kernel kills the next run with SIGKILL (mc's M12 note). `mc build`
    # unlinks it first, which is one more reason the build is mc.toml's.
    "$MC" build || fail=1
fi
[ -x "$BIN" ] || { echo "  no $BIN"; exit 1; }
ls -l "$BIN" | awk '{ printf "  %s  %s bytes\n", "'"$BIN"'", $5 }'

echo ""
echo "== the fixtures and the refusals =="
sh tests/fixtures.sh || fail=1

echo ""
[ "$fail" = 0 ] || { echo "tests: something failed"; exit 1; }
echo "tests: the fast gates passed (the grid is tests/grid.sh)"

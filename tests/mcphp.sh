#!/bin/sh
# Executor B for the phpt grid (probes/t0/phpt-run.py's protocol):
#
#     tests/mcphp.sh FILE.php [ARGS...]
#
# stdin is the test's --STDIN-- section, the environment carries --ENV--.
# Compile the file with the taught compiler and run the binary; the process
# exits with the PROGRAM's status, except:
#
#   3   a named refusal -- `mc-php: <what> is refused by design (docs/plan.md
#       D<n>)`. That is the grid's third column and it is a DESIGN answer, not
#       a failure: docs/plan.md D1/D4/D5/D6 and T5's own named limits.
#   2   an ordinary compile error (a construct the compiler does not parse, an
#       mc diagnostic): not a refusal, not a run.
#
# The refusal is recognised by the message and not by a compiler exit code,
# because mc's err_at always exits 1: the compiler is mc's, the taxonomy is
# this repository's.
set -u
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# the PRIVATE name first: probes/t0/phpt-run.py talks to this wrapper on
# MCPHP__* so that a .phpt's own --ENV-- may use the public names, and a
# standalone caller (fixtures.sh, run.sh, bench10.sh) still sets those.
root=$(CDPATH= cd -- "$here/.." && pwd)
MCPHP=${MCPHP__BIN:-${MCPHP_BIN:-$root/build/mc-php}}
[ -x "$MCPHP" ] || { echo "mcphp.sh: no $MCPHP -- run \`mc build\`" >&2; exit 2; }

src=$1
shift

# Where the binary goes. The CALLER names it through MCPHP_OUT when it can,
# because the caller is the process that WAITS for this one and so is the only
# one that knows when the file is dead: the `exec` at the bottom means this
# shell cannot delete it itself. Without MCPHP_OUT they pile up in MCPHP_TMP
# until its sweeper collects them, which at 37 tests/s is about 3000 binaries
# (6 GB) live at once -- that is what filled the boot volume at 20000 of
# 21395 tests. The fallback is kept so a direct call still works.
_out=${MCPHP__OUT:-${MCPHP_OUT:-}}
if [ -n "$_out" ]; then
    tmp=$_out
else
    dir=${MCPHP__TMP:-${MCPHP_TMP:-${TMPDIR:-/tmp}}}
    tmp=$dir/mcphp.$$.$(basename "$src" .php)
fi
err=$tmp.err

# Both of the compiler's streams are captured, because a php COMPILE-TIME
# `Fatal error:` is written to BOTH in php's own order -- the stderr form
# first -- and a shell that let stdout through live could not reproduce it.
out=$tmp.out
# The compiler runs in the BACKGROUND and is waited for, so a signal can
# reach it. The caller's timeout kills this wrapper; without this the
# compiler kept going, kept writing the binary, and left exactly the orphan
# the temporary-directory bound exists to prevent.
# Windows: an executable is a `.exe` or the loader will not start it, and on
# windows/aarch64 mc has no one-step PE writer (its exe slot is 0), so there
# the compiler writes an OBJECT and lld-link makes the program -- the road
# tests/windows.sh asks for by setting MCPHP_WINLINK to the directory
# tests/winsys.sh filled. windows/x86_64 keeps the one-step --exe.
exe=$tmp
case $(uname -s) in MINGW*|MSYS*|CYGWIN*) exe=$tmp.exe ;; esac
# MCPHP__RC=check (tests/grid.sh's and tests/fixtures.sh's private name for
# it) compiles the program the way src/rc.mc's check mode does: every string
# counted and poisoned at zero. It reaches the COMPILER as MCPHP_RC through
# `env` and is gone before the program runs; a public MCPHP_RC the caller or
# the test itself set is left alone, since php's run of the test saw it too,
# so a test that reads its own environment sees what php's run of it saw.
rc_env=
[ -n "${MCPHP__RC:-}" ] && rc_env="MCPHP_RC=$MCPHP__RC"
# MCPHP_OPT=N compiles at mc's optimisation level N (default 0). The gate runs
# the whole corpus once at each level: the two must agree, which is the
# opt0 == opt1 check. The build road takes it as [project].opt (mc reads it
# there); the single-file roads take it as the --opt= flag.
opt_flag=
opt_proj=
[ -n "${MCPHP_OPT:-}" ] && { opt_flag="--opt=$MCPHP_OPT"; opt_proj="opt = $MCPHP_OPT"; }
# A source with a project file beside it (tests/c: NAME.toml, e.g.
# `[php] checked_reads = true`) is built the project road, `mc-php build`:
# the file's own tables plus a [project] this wrapper writes. The generated
# file sits BESIDE the source and names the entry and the output by their
# bare names, because mc resolves a relative path against the config's
# directory and does not read a Windows drive path (D:/...) as absolute; the
# output is moved to where the caller wants it once the build is done.
cfg=${src%.php}.toml
pdir=$(dirname "$src")
pnm=.mcphp.$$.$(basename "$src" .php)
if [ -f "$cfg" ]; then
    kind=exe; po=$pnm; pdest=$exe
    [ "$exe" != "$tmp" ] && po=$pnm.exe
    [ -n "${MCPHP_WINLINK:-}" ] && { kind=obj; po=$pnm.obj; pdest=$tmp.obj; }
    { printf '[project]\nentry = "%s"\nout = "%s"\nkind = "%s"\n' "$(basename "$src")" "$po" "$kind"; [ -n "$opt_proj" ] && echo "$opt_proj"; printf '\n'; cat "$cfg"; } > "$pdir/$pnm.toml"
    env $rc_env "$MCPHP" build "$pdir" --config "$pdir/$pnm.toml" > "$out" 2> "$err" &
elif [ -n "${MCPHP_WINLINK:-}" ]; then
    env $rc_env "$MCPHP" $opt_flag "$src" -o "$tmp.obj" > "$out" 2> "$err" &
else
    env $rc_env "$MCPHP" $opt_flag --exe "$src" -o "$exe" > "$out" 2> "$err" &
fi
mcpid=$!
trap 'kill -9 $mcpid 2>/dev/null; rm -f "$err" "$out" "$tmp" "$exe" "$tmp.obj" "$pdir/$pnm" "$pdir/$pnm".*; exit 143' TERM
trap 'kill -9 $mcpid 2>/dev/null; rm -f "$err" "$out" "$tmp" "$exe" "$tmp.obj" "$pdir/$pnm" "$pdir/$pnm".*; exit 130' INT
wait $mcpid
rc=$?
# the project road prints its own step line on stdout; it is the build's, not the program's
if [ -f "$cfg" ]; then
    rm -f "$pdir/$pnm.toml"
    [ "$rc" = 0 ] && { : > "$out"; mv -f "$pdir/$po" "$pdest"; }
    rm -f "$pdir/$po"
fi
trap - TERM INT
if [ "$rc" != 0 ]; then
    cat "$err" >&2
    cat "$out"
    # 255 is a php compile-time fatal: php reports those while parsing too,
    # and exits 255. The text is already written; passing the code through is
    # what makes the grid compare it.
    if [ "$rc" = 255 ]; then rm -f "$err" "$out" "$tmp" "$exe" "$tmp.obj"; exit 255; fi
    if grep -q 'is refused by design' "$err"; then rm -f "$err" "$out" "$tmp" "$exe" "$tmp.obj"; exit 3; fi
    rm -f "$err" "$out" "$tmp" "$exe" "$tmp.obj"
    exit 2
fi

if [ -n "${MCPHP_WINLINK:-}" ]; then
    lld-link -machine:arm64 -subsystem:console -entry:mc_start -nodefaultlib \
        -out:"$exe" "$tmp.obj" "$MCPHP_WINLINK/kernel32.lib" "$MCPHP_WINLINK/ucrtbase.lib" \
        > "$out" 2> "$err"
    lrc=$?
    rm -f "$tmp.obj"
    if [ "$lrc" != 0 ]; then cat "$err" >&2; cat "$out"; rm -f "$err" "$out" "$exe"; exit 2; fi
fi
rm -f "$err" "$out"
# The wrapper's own scratch name is not the PROGRAM's business: the oracle
# runs without it, so a .phpt that reads getenv('MCPHP_OUT') or enumerates
# its environment would see two different environments and be classified on
# the harness rather than on itself.
if [ -n "${MCPHP__OUT:-}${MCPHP__BIN:-}${MCPHP__TMP:-}" ]; then
    # The GRID drove this wrapper on the private names. It also sets the
    # PUBLIC ones, because probes/t5..t9's frozen wrappers read only those
    # -- so a public name whose value IS the private one is the grid's and
    # goes, and one that differs is the test's own --ENV-- value, which the
    # oracle kept and which removing would be the same asymmetry the other
    # way round.
    [ "${MCPHP_OUT:-}" = "${MCPHP__OUT:-}" ] && unset MCPHP_OUT
    [ "${MCPHP_BIN:-}" = "${MCPHP__BIN:-}" ] && unset MCPHP_BIN
    [ "${MCPHP_TMP:-}" = "${MCPHP__TMP:-}" ] && unset MCPHP_TMP
    unset MCPHP__OUT MCPHP__BIN MCPHP__TMP
else
    unset MCPHP_OUT MCPHP_BIN MCPHP_TMP
fi
unset MCPHP__RC
# EXEC, so this shell BECOMES the program: python's subprocess timeout kills
# the process it spawned, and a program that loops for ever must be that same
# process. Without the exec the timeout killed the shell and left the binary
# spinning -- eleven of them had accumulated across three grid runs before
# this was measured. The binary is left behind for the caller to sweep.
exec "$exe" "$@"

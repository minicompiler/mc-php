# Sourced by run.sh, grid.sh and fixtures.sh: one definition of where the
# compiled binaries go and how that directory is kept bounded.
#
# The leak this answers: a full-corpus grid filled a 460 GiB boot volume at
# about 20000 of 21395 tests. The sweeper and the trap that were already here
# answered NEITHER of its two mechanisms.
#
#   (a) the PEAK. mcphp.sh EXECs the binary it compiled -- it must, or
#       python's timeout kills the shell and leaves the program spinning --
#       so it cannot delete it. The sweeper only collected a file whose mtime
#       was a minute old and it woke every 20 s, so at the measured 37 tests/s
#       about 3000 binaries of ~2 MB were live at once. The fix is per test
#       and it belongs to the CALLER, which is the process that waits:
#       probes/t0/phpt-run.py names the binary with MCPHP_OUT and unlinks it
#       the moment the subprocess returns. The peak is then the job count
#       times ~2 MB, whatever the corpus size.
#
#   (b) the ORPHANS. The directory carries the pid, so a run killed with
#       SIGKILL left its whole directory behind and no later run ever
#       collected it. That is where the tens of gigabytes came from.
#       mcphp_tmp_init sweeps the siblings whose pid is gone, at startup.
#
# The background sweeper and the trap stay as belt and braces: they cover a
# caller that dies between the spawn and the unlink.

# mcphp_tmp_init PREFIX -- collect dead siblings, then make ours.
mcphp_tmp_init() {
    _pfx=$1
    _base=${TMPDIR:-/tmp}
    for _d in "$_base/$_pfx".*; do
        [ -d "$_d" ] || continue
        _pid=${_d##*.}
        case $_pid in ''|*[!0-9]*) continue ;; esac
        # A dead pid, or -- because a pid is RECYCLED and a live one may be
        # some other process entirely -- anything a day old. Without the
        # second test one unlucky collision keeps an orphan for ever, which
        # is the failure this whole function exists to stop.
        if kill -0 "$_pid" 2>/dev/null; then
            find "$_d" -maxdepth 0 -mtime +1 -exec rm -rf {} + 2>/dev/null
        else
            rm -rf "$_d"
        fi
    done
    MCPHP_TMP=$_base/$_pfx.$$
    export MCPHP_TMP
    mkdir -p "$MCPHP_TMP"
    : > "$MCPHP_TMP/peak"
}

# Sample the directory and keep the maximum, so "bounded by the job count" is
# a number and not a claim. `peak` is excluded from the age sweep below,
# because it is only written when the maximum moves and would otherwise be
# collected as stale.
mcphp_tmp_watch() {
    ( while [ -d "$MCPHP_TMP" ]; do
          k=$(du -sk "$MCPHP_TMP" 2>/dev/null | awk '{ print $1 }')
          o=$(cat "$MCPHP_TMP/peak" 2>/dev/null)
          [ -n "$k" ] && { [ -z "$o" ] || [ "$k" -gt "$o" ]; } && echo "$k" > "$MCPHP_TMP/peak"
          find "$MCPHP_TMP" -type f -mmin +1 ! -name peak -delete 2>/dev/null
          sleep 2
      done ) &
    MCPHP_SWEEP=$!
}

mcphp_tmp_done() {
    kill "$MCPHP_SWEEP" 2>/dev/null
    printf '  tmp peak: %s KiB (%s)\n' "$(cat "$MCPHP_TMP/peak" 2>/dev/null || echo '?')" "$MCPHP_TMP"
    rm -rf "$MCPHP_TMP"
}

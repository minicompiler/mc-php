# ONE bounded runner for every gate in this probe -- the fixture gate, the
# D8 test runner and the bench. `run.sh` is a 90-minute probe and a
# compiler regression that emits a non-terminating binary would otherwise
# hang it with no output and never reach its cleanup trap, while the grid
# beside it is bounded by phpt-run.py's own timeout. Source it after `tmp`
# is set (it writes `$tmp/alarm`) and set LIM_SECS to change the budget.
#
# A fixture that loops for ever must not hang the gate with no output. perl is
# on every host that has php; `timeout` is not on macOS.
# perl forks rather than execs, so the alarm kills the CHILD and this shell
# never prints "Alarm clock" into the stderr being compared.
# `timedout` is set by the wrapper itself and not read off the child's exit
# status: a fixture may legitimately `exit(124)`, and treating that code as
# the alarm failed a pair whose streams and statuses agreed. The marker file
# is the alarm's own signal, written before the wrapper exits.
timedout=""
lim() {
    rm -f "$tmp/alarm"
    perl -e 'my $t = shift; my $mark = shift;
             # the child leads its OWN process group, and the alarm kills
             # the group: mcphp.sh starts the compiler as a child, so
             # `kill 9, $p` left it running and writing its binary after
             # the wrapper was gone -- measured, one surviving compiler
             # per timeout.
             my $p = fork;
             if (!$p) { setpgrp(0, 0); exec(@ARGV) or exit 127 }
             # `kill -9, $p` is how perl spells the process GROUP: it is
             # the SIGNAL that is negative, not the pid (perldoc -f kill,
             # "If SIGNAL is negative, it kills process groups instead of
             # processes"), and the child made itself the leader above.
             # Measured WITH A CONTROL, because the reading is easy to get
             # backwards: a child that leaves a `sleep 40` behind loses it
             # to `kill -9, $p` and KEEPS it under `kill 9, $p`.
             $SIG{ALRM} = sub { kill -9, $p; waitpid $p, 0;
                                open my $fh, ">", $mark; close $fh; exit 124 };
             alarm $t; waitpid $p, 0;
             # A child killed by a SIGNAL has its number in the low seven
             # bits and nothing in the high byte, so `$? >> 8` reported 0:
             # a fixture that SEGFAULTED came out as a clean exit 0 and
             # could pass the comparison. 128 + n is the shell convention
             # and is a code php never answers.
             exit(($? & 127) ? 128 + ($? & 127) : $? >> 8)' "${LIM_SECS:-30}" "$tmp/alarm" "$@"
    _rc=$?
    timedout=no
    if [ -f "$tmp/alarm" ]; then timedout=yes; fi
    return $_rc
}

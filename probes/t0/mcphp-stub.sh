#!/bin/sh
# Placeholder executor B for T0. The compiler does not exist yet, so every
# .phpt is red on this side by construction -- this script refuses every
# input uniformly, with none of the refusal exit code phpt-run.py checks for
# (--refuse-code, default 3), so every outcome reports as "wrong" and not
# "refused": a refusal is a named compile error from a real compiler, not
# "not implemented yet".
#
# Protocol phpt-run.py drives an executor with (see phpt-run.py's docstring):
#   <executor> FILE.php [ARGS...]
# stdin is the test's --STDIN-- section (or empty), the environment carries
# --ENV--. This stub reads none of it.
echo "mcphp-stub: not implemented" >&2
exit 99

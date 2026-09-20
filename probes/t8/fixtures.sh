#!/bin/sh
# g/*.php byte for byte php's (both streams and the exit code), r/*.php refused
# by name with exit 3. Exits 0 only when every one agreed.
set -u
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../.." && pwd)
cd "$root"
PHP=${PHP:-php}
# A measurement takes a SNAPSHOT of the compiler (T7's note): an edit during
# the run cannot then corrupt it.
snap=${TMPDIR:-/tmp}/mcphp-fx.$$
cp probes/t8/mc-php "$snap"
MCPHP_BIN=$snap
export MCPHP_BIN
trap 'rm -f "$snap"' EXIT INT TERM
fail=0
ng=0; nok=0
for f in probes/t8/g/*.php; do
    ng=$((ng + 1))
    exp=$("$PHP" "$f" 2>&1) && pe=0 || pe=$?
    got=$(probes/t8/mcphp.sh "$f" 2>&1) && me=0 || me=$?
    if [ "$exp" = "$got" ] && [ "$pe" = "$me" ]; then
        nok=$((nok + 1))
    else
        printf '  FAIL  %s\n    php:    %s (exit %s)\n    mc-php: %s (exit %s)\n' \
            "$(basename "$f")" "$exp" "$pe" "$got" "$me"
        fail=1
    fi
done
echo "  fixtures: $nok / $ng agree with php"
nr=0; nrok=0
for f in probes/t8/r/*.php; do
    nr=$((nr + 1))
    msg=$(probes/t8/mcphp.sh "$f" 2>&1 >/dev/null | sed 's/^[^:]*:[0-9]*: //' | head -1)
    probes/t8/mcphp.sh "$f" >/dev/null 2>&1 && rc=0 || rc=$?
    case "$rc:$msg" in
        3:*"is refused by design"*) nrok=$((nrok + 1)) ;;
        *) printf '  FAIL  %-26s exit %s: %s\n' "$(basename "$f")" "$rc" "$msg"; fail=1 ;;
    esac
done
echo "  refusals: $nrok / $nr named, exit 3"
exit $fail

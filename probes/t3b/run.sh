#!/bin/sh
# probes/t3b/run.sh [image] [reps] -- build t3b.so against IMAGE's php and run
# the matrix: modes 0-3 x opcache off/on x the starting request idle/busy,
# 8 workers, REPS times each; prints one line per cell. Inside the Linux VM:
#     limactl shell mc-k7 -- sh "$PWD/probes/t3b/run.sh" php:8.5-zts-alpine 20
set -u
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
img=${1:-php:8.5-zts-alpine}; reps=${2:-10}
tag=$img
case "$img" in mc-php-*) ;; *)
    tag=mc-php-t3b-$(echo "$img" | tr ':/.' '---')
    docker image inspect "$tag" > /dev/null 2>&1 || printf '%s\n' "FROM $img" 'RUN apk add --no-cache $PHPIZE_DEPS > /dev/null' | docker build -q -t "$tag" - > /dev/null || exit 2 ;;
esac
docker run --rm -v "$here:/p" -w /p "$tag" sh -c '
    P=$(dirname $(command -v php)); [ -x /opt/phpdbg/bin/php ] && P=/opt/phpdbg/bin
    $P/php -v | head -1
    cc -O1 -g -shared -fPIC $($P/php-config --includes) -o /tmp/t3b.so t3b.c -lpthread || exit 3
    for oc in 0 1; do for m in 0 1 2 3; do for loops in 0 200; do
        ok=0; crash=0; other=""
        i=0; while [ $i -lt '"$reps"' ]; do i=$((i + 1))
            $P/php -n -d extension=/tmp/t3b.so -d opcache.enable_cli=$oc -d opcache.enable=$oc test.php $m 8 $loops > /tmp/o 2>&1; rc=$?
            if [ $rc = 0 ] && grep -q "self 8/8 named 8/8" /tmp/o; then ok=$((ok + 1))
            elif [ $rc -ge 128 ]; then crash=$((crash + 1))
            else other=$(grep -v "^ *$" /tmp/o | grep -o "self [0-9/]* named [0-9/]*\|named\[0\]: [^ ]* [^ ]* [^ ]* [^ ]*\|Assertion[^:]*: [^ ]*" | head -2 | tr "\n" " "); fi
        done
        echo "opcache $oc mode $m loops $loops: ok $ok crash $crash of '"$reps"' $other"
    done; done; done
'

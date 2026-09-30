#!/bin/sh
# probes/t3b/cost.sh [image]: microseconds per start (thread + ts_resource +
# request startup + the call + request shutdown + ts_free_thread), 300 starts
# one after another, per mode, opcache off and on; best of 3 runs
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
img=${1:-php:8.5-zts-alpine}
tag=mc-php-t3b-$(echo "$img" | tr ':/.' '---')
docker run --rm -v "$here:/p" -w /p "$tag" sh -c '
    cc -O2 -shared -fPIC $(php-config --includes) -o /tmp/t3b.so t3b.c -lpthread || exit 3
    for oc in 0 1; do for m in 1 2 3; do
        for r in 1 2 3; do php -n -d extension=/tmp/t3b.so -d opcache.enable_cli=$oc -d opcache.enable=$oc test.php $m 1 200 cost | grep "cost"; done | sort -t" " -k6 -n | head -1 | sed "s/^/opcache $oc /"
    done; done
'

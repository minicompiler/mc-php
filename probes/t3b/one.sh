#!/bin/sh
# probes/t3b/one.sh MODE N LOOPS OPCACHE [image] [T3B_TRACE]: one run
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
img=${5:-php:8.5-zts-alpine}
tag=mc-php-t3b-$(echo "$img" | tr ':/.' '---')
docker run --rm -e T3B_TRACE=${6:-} -v "$here:/p" -w /p "$tag" sh -c "
    cc -O0 -g -shared -fPIC \$(php-config --includes) -o /tmp/t3b.so t3b.c -lpthread || exit 3
    php -n -d extension=/tmp/t3b.so -d opcache.enable_cli=$4 -d opcache.enable=$4 test.php $1 $2 $3 $7 2>&1 | head -40; echo rc \$?
"

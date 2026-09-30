#!/bin/sh
# probes/t3b/dbg.sh MODE N LOOPS OPCACHE [image]: one run under gdb, the backtrace
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
img=${5:-php:8.5-zts-alpine}
tag=mc-php-t3b-$(echo "$img" | tr ':/.' '---')-gdb
if ! docker image inspect "$tag" > /dev/null 2>&1; then
    printf '%s\n' "FROM $img" 'RUN apk add --no-cache $PHPIZE_DEPS gdb > /dev/null' | docker build -q -t "$tag" - > /dev/null || exit 2
fi
docker run --rm --cap-add=SYS_PTRACE --security-opt seccomp=unconfined -v "$here:/p" -w /p "$tag" sh -c "
    cc -O0 -g -shared -fPIC \$(php-config --includes) -o /tmp/t3b.so t3b.c -lpthread || exit 3
    gdb -batch -ex run -ex 'thread apply all bt 12' --args php -n -d extension=/tmp/t3b.so -d opcache.enable_cli=$4 -d opcache.enable=$4 test.php $1 $2 $3 2>&1 | grep -v '^\[New\|^\[Thread\|Download\|^$' | head -70
"

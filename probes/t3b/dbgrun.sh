#!/bin/sh
# probes/t3b/dbgrun.sh MODE N LOOPS OPCACHE [extra]: one run on the DEBUG ZTS php (asserts on)
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
docker run --rm -e T3B_TRACE=${6:-} -v "$here:/p" -w /p mc-php-t3b-dbg sh -c "
    P=/opt/phpdbg/bin
    cc -O0 -g -shared -fPIC \$(\$P/php-config --includes) -o /tmp/t3b.so t3b.c -lpthread || exit 3
    \$P/php -n -d extension=/tmp/t3b.so -d zend_extension=opcache -d opcache.enable_cli=$4 -d opcache.enable=$4 test.php $1 $2 $3 $5 2>&1 | head -40; echo rc \$?
"

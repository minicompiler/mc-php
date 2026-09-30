#!/bin/sh
# probes/t3b/segv2.sh IMAGE OPCACHE SCRIPT ARGS...: a crash of any script, symbolised
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
tag=$1; oc=$2; shift 2
docker run --rm -e T3B_SEGV=1 -v "$here:/p" -w /p "$tag" sh -c "
    P=\$(dirname \$(command -v php)); [ -x /opt/phpdbg/bin/php ] && P=/opt/phpdbg/bin
    cc -O0 -g -fno-omit-frame-pointer -shared -fPIC \$(\$P/php-config --includes) -o /tmp/t3b.so t3b.c -lpthread || exit 3
    \$P/php -n -d extension=/tmp/t3b.so -d opcache.enable_cli=$oc -d opcache.enable=$oc $* > /tmp/o 2> /tmp/e; echo rc \$?
    grep -v '^\\[\\|Freeing\\|Total\\|^\$' /tmp/e | grep -v ' r..p \\| ---p ' | head -4
    apk add -q binutils > /dev/null 2>&1
    for a in \$(grep -o 'pc=[0-9a-f]*\\|lr=[0-9a-f]*\\|frame [0-9a-f]*' /tmp/e | sed 's/.*[= ]//' | head -14); do
        A=\$((0x\$a))
        grep ' r-xp ' /tmp/e | while read rng perm off dev ino f; do
            lo=\$((0x\${rng%-*})); hi=\$((0x\${rng#*-}))
            if [ \$A -ge \$lo ] && [ \$A -lt \$hi ]; then
                o=\$(printf '%x' \$((A - lo + 0x\$off)))
                echo \"\$a \$(basename \$f) \$(addr2line -f -e \$f 0x\$o | tr '\\n' ' ')\"
            fi
        done
    done
"

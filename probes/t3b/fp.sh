#!/bin/sh
# probes/t3b/fp.sh MODE OPCACHE [reqs] [par]: FrankenPHP, t3b.so loaded, REQS
# requests PAR at a time; counts ok/bad answers and whether FrankenPHP survived
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
m=$1; oc=$2; reqs=${3:-2000}; par=${4:-16}; lp=${5:-20}
name=t3b-fp-$$
docker run --rm -v "$here:/p" -w /p mc-php-t3b-php-8-5-zts-alpine sh -c 'cc -O1 -g -shared -fPIC $(php-config --includes) -o /p/fp/t3b.so t3b.c -lpthread' || exit 3
docker run -d --name $name -v "$here:/p" dunglas/frankenphp:php8.5-alpine sh -c "
    printf 'extension=/p/fp/t3b.so\nopcache.enable=$oc\n' > /usr/local/etc/php/conf.d/zz-t3b.ini
    exec frankenphp run --config /p/fp/Caddyfile" > /dev/null
i=0; while [ $i -lt 30 ]; do docker exec $name curl -fs --max-time 5 "http://127.0.0.1:8080/?m=2&n=1" > /dev/null 2>&1 && break; sleep 1; i=$((i+1)); done
docker exec $name sh -c "seq 1 $reqs | xargs -P $par -I{} curl -s --max-time 30 'http://127.0.0.1:8080/?m=$m&n=2&l=$lp'" > /tmp/fp.$$ 2>&1
alive=$(docker exec $name curl -fs --max-time 5 "http://127.0.0.1:8080/?m=3&n=1" 2>/dev/null || echo dead)
echo "mode $m opcache $oc loops $lp: $(grep -c '^ok' /tmp/fp.$$) ok, $(grep -c '^BAD' /tmp/fp.$$) bad, $(grep -vc '^ok\|^BAD' /tmp/fp.$$) other of $reqs; after: $alive"
grep -v '^ok' /tmp/fp.$$ | sort | uniq -c | sort -rn | head -3 | cut -c1-200
docker logs $name 2>&1 | grep -i "fatal\|segm\|signal\|panic\|assert" | head -3 | cut -c1-200
docker rm -f $name > /dev/null; rm -f /tmp/fp.$$

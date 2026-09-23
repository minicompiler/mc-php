#!/bin/sh
# Build the extension for one target php. $1 = `php -i` output file, $2 = out.so,
# $3 = backend (macho|elf-obj|elf-obj-x86_64), $4 = link mode (macos|linux).
set -e
inf=$1; out=$2; be=$3; mode=$4
api=$(sed -n 's/^PHP API => //p' "$inf" | tr -d ' \r')
bid=$(sed -n 's/^PHP Extension Build => //p' "$inf" | tr -d ' \r')
[ "$(sed -n 's/^Thread Safety => //p' "$inf" | tr -d ' \r')" = enabled ] && zts=1 || zts=0
[ "$(sed -n 's/^Debug Build => //p' "$inf" | tr -d ' \r')" = yes ] && dbg=1 || dbg=0
sed -e "s/@API@/$api/" -e "s/@ZTS@/$zts/" -e "s/@DEBUG@/$dbg/" -e "s/@BUILDID@/$bid/" tmpl.mc > gen.mc
mc --backend="$be" gen.mc -o gen.o
if [ "$mode" = macos ]; then
  ld -bundle -undefined dynamic_lookup -o "$out" gen.o -L"$(xcrun --show-sdk-path)/usr/lib" -lSystem
else
  ld.lld -shared -Bsymbolic -o "$out" gen.o
fi
echo "built $out  api=$api zts=$zts debug=$dbg build_id=$bid"

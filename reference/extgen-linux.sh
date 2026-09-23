#!/bin/sh
# Build the extension for one LINUX target php. $1 = `php -i` output, $2 = out.so,
# $3 = source template. Same header derivation as the macOS road; the only
# difference is the link: ld.lld -shared -Bsymbolic, because mc takes the
# address of its own functions with adrp/add and a shared object would
# otherwise demand a GOT for a preemptible symbol.
set -e
inf=$1; out=$2; tmpl=${3:-tmpl.mc}
api=$(sed -n 's/^PHP API => //p' "$inf" | tr -d ' \r')
bid=$(sed -n 's/^PHP Extension Build => //p' "$inf" | tr -d ' \r')
[ "$(sed -n 's/^Thread Safety => //p' "$inf" | tr -d ' \r')" = enabled ] && zts=1 || zts=0
[ "$(sed -n 's/^Debug Build => //p' "$inf" | tr -d ' \r')" = yes ] && dbg=1 || dbg=0
sed -e "s/@API@/$api/" -e "s/@ZTS@/$zts/" -e "s/@DEBUG@/$dbg/" -e "s/@BUILDID@/$bid/" "$tmpl" > genl.mc
mc --backend=elf-obj genl.mc -o genl.o
ld.lld -shared -Bsymbolic -o "$out" genl.o
echo "built $out  api=$api zts=$zts debug=$dbg build_id=$bid"

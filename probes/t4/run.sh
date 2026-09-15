#!/bin/sh
# T4 -- does mc's Tier 3 take PHP's grammar, and where exactly does it not?
#
# Three tables, in the order docs/plan.md section 4 row T4 asks for them:
#   1. the lexer   -- one PHP construct per fixture under lex/, each read by the
#                     stock mc AND by a compiler whose user_init does nothing
#                     but tok_add. What still dies is what the core lexer keeps.
#   2. the entry   -- the four shapes that can make a .php file the thing the
#                     user names, and whether source_claim fires for each.
#   3. the grammar -- probes/t4/php.mc, one syntax("<?php") registration owning
#                     the whole grammar, measured step by step against `php`.
#
# Exits 0 only when every measurement ran and every oracle agreed.
set -eu
LC_ALL=C
export LC_ALL

cd "$(dirname "$0")"
MC=${MC:-mc}
PHP=${PHP:-php}
fail=0

note() { printf '%s\n' "$*"; }
bad()  { printf 'T4: %s\n' "$*"; fail=1; }

# verdict of one compiler on one file: "ok" or the diagnostic it died with
verdict() {
    out=$("$1" --dump-tokens "$2" 2>&1) && { printf 'ok\n'; return 0; }
    printf '%s\n' "$out" | sed -n 's/.*: //p' | tail -1
}

"$MC" --version

# --- 0. the three compilers --------------------------------------------------
"$MC" --exe mc-lexprobe.mc   -o mc-lexprobe
"$MC" --exe mc-php.mc        -o mc-php
"$MC" --exe entry/mc-claim.mc   -o entry/mc-claim
"$MC" --exe entry/mc-push.mc    -o entry/mc-push
"$MC" --exe entry/mc-inplace.mc -o entry/mc-inplace
"$MC" --exe dollar/mc-d.mc      -o dollar/mc-d

# --- 1. the lexer ------------------------------------------------------------
note ""
note "== 1. the lexer: $(ls lex/*.php | wc -l | tr -d ' ') constructs =="
note "  fixture              stock mc                   +tok  the tokens it then makes"
ndie=0
nfix=0
nres=0
for f in lex/*.php; do
    a=$(verdict "$MC" "$f")
    b=$(verdict ./mc-lexprobe "$f")
    [ "$a" = ok ] || ndie=$((ndie + 1))
    if [ "$a" != ok ] && [ "$b" = ok ]; then nfix=$((nfix + 1)); fi
    if [ "$b" != ok ]; then nres=$((nres + 1)); fi
    t=$(./mc-lexprobe --dump-tokens "$f" 2>/dev/null | awk '{ $1=""; $2=""; printf "%s ", substr($0,3) }' | cut -c1-34)
    printf '  %-20s %-26s %-6s %s\n' "$(basename "$f" .php)" "$a" "$b" "$t"
done
note "  $ndie of $(ls lex/*.php | wc -l | tr -d ' ') die under the stock lexer; tok_add fixes $nfix; $nres are the lexer's own"

# the three the lexer keeps, named. If mc ever gains a way to own them this
# assertion is what says so.
for f in lex/04-hash-comment.php lex/21-attribute.php lex/07-single-quote.php; do
    [ "$(verdict ./mc-lexprobe "$f")" = ok ] && bad "$f now lexes -- the residual list in RESULTS.md is stale"
done
[ "$(verdict ./mc-lexprobe lex/30-single-char.php)" = ok ] || bad "30-single-char should lex (as a CHAR, which is the silent wrong answer)"

# --- 2. the entry ------------------------------------------------------------
mkdir -p out
note ""
note "== 2. the entry: where a .php file can be named =="
i=$(./entry/mc-claim --dump-tokens entry/plain.php 2>&1 | grep -c 'claim: entry/plain.php -> 1') || true
[ "$i" = 1 ] && note "  (i)   entry = main.php            source_claim fires before token 1   yes" \
             || bad "(i) source_claim did not fire for the entry"
i=$(./entry/mc-claim --dump-ast entry/stub.mc 2>&1 | grep -c 'claim: entry/plain.php -> 1') || true
[ "$i" = 1 ] && note "  (ii)  a .mc stub that #includes it  claimed when the core resolves it  yes" \
             || bad "(ii) source_claim did not fire for an #included .php"
i=$(./entry/mc-push --dump-ast entry/rw.php 2>&1 | grep -c 'name=main') || true
[ "$i" = 2 ] && note "  (iii) p_push_source from user_init  the ENTRY is parsed too: $i x main   no" \
             || bad "(iii) expected the entry to be parsed twice, saw $i"
i=$(./entry/mc-inplace --dump-ast entry/ip2.php 2>&1 | grep -c 'rewrote 2 bytes') || true
[ "$i" = 1 ] && note "  (iv)  rewrite in place in on_source  the lexer reads the new bytes     yes" \
             || bad "(iv) the in-place rewrite did not reach the lexer"
if ! "$MC" build . >out/build 2>&1; then bad "mc build with entry = main.php failed"; cat out/build; fi
./build/t4 > out/mine 2>&1 || true
"$PHP" main.php > out/oracle 2>/dev/null || true
if cmp -s out/mine out/oracle; then
    note "  (i')  mc build, [compiler] + entry   ran, php agrees: $(tr -d '\n' < out/mine)"
else
    bad "mc build: php disagrees"
fi
./dollar/mc-d --dump-ast dollar/a.php >/dev/null 2>&1 && bad '$name reached a syntax_expr("$") handler'
note "  and: \$name is a T_HOLE -- $(./dollar/mc-d --dump-ast dollar/a.php 2>&1 | sed -n 's/.*: //p')"

# --- 3. the grammar ----------------------------------------------------------
note ""
note "== 3. the grammar: probes/t4/php.mc, step by step =="
step() {                       # step <fixture> <oracle|refuse> [expected text]
    src=$1
    kind=$2
    b=out/$(basename "$src" .php)
    if [ "$kind" = refuse ]; then
        if ./mc-php --exe "$src" -o "$b" >out/err 2>&1; then
            bad "$src compiled, it must be refused"
            printf '  %-22s REFUSED?  no\n' "$(basename "$src" .php)"
            return
        fi
        printf '  %-22s refused: %s\n' "$(basename "$src" .php)" "$(sed -n 's/.*: //p' out/err | tail -1)"
        return
    fi
    if ! ./mc-php --exe "$src" -o "$b" >out/err 2>&1; then
        bad "$src did not compile: $(cat out/err)"
        return
    fi
    "$b" > out/mine 2>&1 || true
    if [ "$kind" = oracle ]; then
        "$PHP" -d error_reporting=0 "$src" > out/oracle 2>/dev/null || true
        if cmp -s out/mine out/oracle; then
            printf '  %-22s ran, php agrees: %s\n' "$(basename "$src" .php)" "$(tr '\n' ' ' < out/mine)"
        else
            bad "$src: php disagrees"
            diff out/oracle out/mine || true
        fi
        return
    fi
    printf '  %-22s ran (no php oracle): %s\n' "$(basename "$src" .php)" "$(tr '\n' ' ' < out/mine)"
}

step g/01-echo.php        oracle
step g/02-assign.php      oracle
step g/03-d4-retype.php   refuse
step g/04-function.php    oracle
step g/05-control.php     oracle
step g/06-interp.php      oracle
step g/07-class.php       own
step g/08-require.php     oracle
step g/09-eval.php        refuse
step g/10-float.php       refuse
step g/11-numbers.php     oracle
step g/12-singlequote.php oracle
step g/13-hash.php        oracle
step g/14-inline-html.php refuse

note ""
[ "$fail" = 0 ] || { note "T4: a measurement failed"; exit 1; }
note "T4: measured -- see probes/t4/RESULTS.md"

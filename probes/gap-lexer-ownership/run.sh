#!/bin/sh
# Exits 0 only while the gap still reproduces.
set -eu
LC_ALL=C
export LC_ALL
cd "$(dirname "$0")"
MC=${MC:-mc}

"$MC" --exe mc-claimall.mc -o mc-claimall

gone=0
probe() {                              # case <file> <what must still happen>
    out=$(./mc-claimall --dump-tokens "$1" 2>&1) || true
    printf '  %-20s %s\n' "$1" "$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-70)"
    printf '%s' "$out" | grep -q "$2" || { printf '    ^ FIXED: no longer matches "%s"\n' "$2"; gone=1; }
}

echo "mc $("$MC" --version | awk '{print $2}') -- every source claimed, every lexeme added:"
probe a-single-quote.php 'unterminated char literal'
probe b-single-char.php  '2 3 120'   # T_CHAR: 'x' is silently the integer 120
probe c-hash.php         'unknown directive'
probe d-attribute.php    'unknown directive'
probe f-rawtext.php      'unterminated char literal'  # the ' inside the raw text

# $name is a T_HOLE; a syntax_expr("$") handler does not see it
out=$(./mc-claimall --dump-ast e-dollar.php 2>&1) || true
printf '  %-20s %s\n' e-dollar.php "$out"
printf '%s' "$out" | grep -q 'hole \$name has no rule binding it' || { echo '    ^ FIXED'; gone=1; }

[ "$gone" = 0 ] || { echo "gap-lexer-ownership: no longer reproduces -- update docs/plan.md section 5"; exit 1; }
echo "gap-lexer-ownership: still reproduces"

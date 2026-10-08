#!/bin/sh
# The example gates: every directory under examples/ but hello (tests/ext.sh
# grades that one), each compiled and compared with something php produced.
#
#     sh tests/examples.sh               # on the host it is on
#     BIN=/path/to/mc-php MC=/path/to/mc sh tests/examples.sh
#     LINUX=1 sh tests/examples.sh       # the mcphp.linux.toml files
#     WINDOWS=1 sh tests/examples.sh     # the mcphp.windows.toml files
#
#   decimal          PHP compiled by mc-php. The DIFFERENTIAL (check.php with
#                    the module, then with decimal.php required, byte for byte
#                    on both streams and the exit), bcmath as a second oracle
#                    where the host php has it, and the bench row against the
#                    interpreted source -- whose ratio is printed, not gated.
#   db               PHP compiled by mc-php, calling libsqlite3 through #[Extern]
#                    (slice 1: scalars only). check.php against check.expect and
#                    against php's own SQLite3 class as the oracle; SKIPPED by
#                    name on Windows and on a php without sqlite3.
#   ctype            php-src's ext/ctype ported to PHP and compiled by mc-php.
#                    The eleven cty_* graded byte for byte against php's own
#                    (compiled-in) ctype_* over all 256 bytes, the int quirk and
#                    the non-string types; the bench is cty_*/ctype_*, printed.
#                    SKIPPED on Windows (#[Extern] is refused there by name).
#   two-extensions   PHP compiled by mc-php: extA and extB, where B calls A
#                    through php's function table. The differential in BOTH
#                    load orders and B alone, the C twins graded the same way,
#                    and the bench row against the interpreted source and the
#                    twins -- printed, not gated. Then hello and decimal, two
#                    mc-php extensions that do not call each other, together.
#   awaitable        the compiled awaitable.src.php, a ZTS extension on native
#                    OS threads and native sync: check.php against check.expect,
#                    the demo, and the C twin (c/awaitable.c + c/twin.php) graded
#                    the same way. It needs a thread-safe php and skips on an NTS
#                    one (docs/threads.md § 3b); CI's ZTS legs run it.
#
# Exits 0 only when every step that ran passed.
set -u
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/.." && pwd)
cd "$root"
PHP=${PHP:-php}
BIN=${BIN:-build/mc-php}
MC=${MC:-mc}
host=macos; sx=so; suf=
[ "${LINUX:-0}" = 1 ] && { host=linux; suf=.linux; }
[ "${WINDOWS:-0}" = 1 ] && { host=windows; suf=.windows; sx=dll; }
fail=0
# the form a NATIVE php.exe reads: MSYS's /d/a/... means nothing to it
rootn=$(cygpath -m "$root" 2>/dev/null || echo "$root")

[ -x "$BIN" ] || { echo "  no $BIN"; exit 1; }
. "$here/tmp.sh"
mcphp_tmp_init mcphp-examples
tmp=$MCPHP_TMP
. "$here/lim.sh"
. "$here/ts.sh"
mcphp_ts_init
trap 'rm -rf "$tmp"; mcphp_ts_clean' EXIT
trap 'exit 130' INT

say()  { printf '  %s\n' "$*"; }
bad()  { printf '  FAIL %s\n' "$*"; fail=1; }
skip() { printf '  SKIPPED %s\n' "$*"; }

# build EX CFG ART: mc-php build, the artefact removed first so a failed
# build is never graded on an old one (tests/ext.sh, the reviewer of #15).
# For a ZTS php the build is from a copy of CFG that says so (tests/ts.sh).
build() {
    rm -f "$1/build/$3"
    if "$BIN" build "$1" --config "$(mcphp_ts_cfg "$2")" > "$tmp/build.out" 2>&1 && [ -f "$1/build/$3" ]; then
        return 0
    fi
    bad "mc-php build $2:"; sed 's/^/      /' "$tmp/build.out"
    return 1
}

# differential NAME SCRIPT ARGS...: run php twice on the same script -- the first run with
# the extension arguments given, the second with none -- and require the same
# bytes on each stream and the same exit.
differential() {
    name=$1; script=$2; shift 2
    "$PHP" "$@" "$script" > "$tmp/n.out" 2> "$tmp/n.err"; nrc=$?
    "$PHP" "$script"      > "$tmp/i.out" 2> "$tmp/i.err"; irc=$?
    ok=1
    cmp -s "$tmp/n.out" "$tmp/i.out" || { ok=0; bad "$name: stdout differs"
        diff -u "$tmp/i.out" "$tmp/n.out" | sed -n '3,20p' | sed 's/^/      /'; }
    cmp -s "$tmp/n.err" "$tmp/i.err" || { ok=0; bad "$name: stderr differs"
        diff -u "$tmp/i.err" "$tmp/n.err" | sed -n '3,20p' | sed 's/^/      /'; }
    [ "$nrc" = "$irc" ] || { ok=0; bad "$name: exit $nrc native, $irc interpreted"; }
    [ "$ok" = 1 ] && say "$name: $(wc -l < "$tmp/n.out" | tr -d ' ') lines, byte for byte php's own, exit $nrc"
}

# --- decimal: PHP compiled by mc-php ------------------------------------------
echo "  -- decimal"
EX=examples/decimal
dso=$rootn/$EX/build/decimal.$sx
if build "$EX" "$EX/mcphp$suf.toml" "decimal.$sx"; then
    say "built: $(wc -c < "$dso" | tr -d ' ') bytes from $EX/decimal.php"
    differential check.php "$EX/check.php" -d extension="$dso"
    # the _dec_* helpers are module-private (a leading underscore): php sees
    # the six dec_* functions and nothing else
    vis=$("$PHP" -d extension="$dso" -r '$f = get_extension_funcs("decimal"); sort($f); echo implode(" ", $f);' 2>&1 | tr -d '\r')
    if [ "$vis" = "dec_add dec_cmp dec_div dec_mul dec_round dec_sub" ]; then
        say "published: the six dec_* functions and none of the _dec_* helpers"
    else
        bad "published: want the six dec_* functions, got: $vis"
    fi
    if "$PHP" -m | tr -d '\r' | grep -qix bcmath; then
        # the exit AND the exact summary: a weakened oracle that checked less
        # must not pass (the reviewer of #18)
        if "$PHP" -d extension="$dso" "$EX/bccheck.php" > "$tmp/bc.out" 2>&1 &&
           [ "$(tr -d '\r' < "$tmp/bc.out")" = "bcmath agrees: 1219 results, 0 wrong" ]; then
            say "$(tr -d '\r' < "$tmp/bc.out")"
        else
            bad "bccheck.php:"; sed 's/^/      /' "$tmp/bc.out"
        fi
    else
        skip "the bcmath cross-check: this php has no bcmath"
    fi
    # 1 000 000 calls in ONE request: every string a call builds is a Zend
    # block freed when its last reference goes, so php's own usage does not
    # move and its peak moves only as far as a call's temporaries grow with the
    # accumulator's digits (soak.php says why): a kilobyte is allowed, and one
    # leaked string a call would be tens of megabytes. The module used to
    # allocate out of a fixed arena and died near 29 000 calls.
    set -- $("$PHP" -d extension="$dso" "$EX/soak.php" 1000000 2>&1 | tr -d '\r')
    if [ "${2:-}" = 1000000 ] && [ "${4:-}" = 12500000.00 ] \
       && [ $((${8:-99999999} - ${6:-0})) -lt 1024 ] && [ $((${12:-99999999} - ${10:-0})) -lt 1024 ]; then
        say "soak: 1000000 dec_add calls in one request, usage $6 -> $8 bytes, peak ${10} -> ${12}"
    else
        bad "soak.php: want 1000000 calls, 12500000.00, and usage and peak that move under 1 KiB, got: $*"
    fi
    # How many strings a call BUILDS (MCPHP_STATS=1 counts every _emalloc of
    # one, a copy included): 100 calls of each operation on the bench's own
    # kind of arguments. Each is an exact number and a ceiling at once -- a
    # lowering that stopped reading substr() windows in place, answering an
    # empty concatenation side or a one-byte result without a new string, or
    # a chr() without one, moves it up. Before those (main at #22) the counts
    # were 800, 1000, 1300, 200 and 3400. decimal.php is c/decimal.c's
    # algorithm since the same-algorithm rewrite, which moved them: dec_div's
    # long division by repeated subtraction builds a remainder per step where
    # the twin subtracts in its one buffer -- a PHP string is a value, and a
    # helper cannot write into its caller's. decimal-2x moved them down from
    # 700, 700, 800, 300 and 10700: _dec_fmt's answer is one string (src/opt.mc's
    # rope) and `$d . str_repeat('0', n)` one (php_str_catrep); and dec_div's
    # from 10300 to 1300 when _dec_udivmod took the twin's one remainder
    # buffer, compared and subtracted in place; and 400 400 500 200 1200 when
    # _dec_fmt carried the index of its first kept digit, as the twin moves
    # its pointer, instead of a substr() of the rest; and dec_mul's 500 to
    # 400 when _dec_fmt's kept digits, `$w = ... ? '0' : substr(...)`, became
    # a window of the product (src/opt.mc, ph_view_fn's count along paths).
    sb=
    for op in "dec_add('123456.78', '1093.75', 2)" "dec_sub('123456.78', '2682.24', 2)" \
              "dec_mul('123456.78', '0.004375000000', 2)" "dec_cmp('123456.78', '0')" "dec_div('5.25', '1200', 12)"; do
        n=$(MCPHP_STATS=1 "$PHP" -d extension="$dso" -r "for (\$i = 0; \$i < 100; \$i++) $op;" 2>&1 | tr -d '\r' | sed -n 's/.*strings built //p')
        sb="$sb${sb:+ }${n:-?}"
    done
    if [ "$sb" = "400 400 400 200 1200" ]; then
        say "strings: 100 calls of add, sub, mul, cmp, div build $sb strings"
    else
        bad "strings: 100 calls of add, sub, mul, cmp, div built $sb strings (want 400 400 400 200 1200)"
    fi
    # the C twin (c/decimal.c): the same six functions written the ordinary
    # way, graded by the same check.php, and the reference the bench compares
    # against. It needs php-config and a C compiler; the COMPILER needs
    # neither, so without them this says so and the bench has two columns.
    cso=
    CC=${CC:-cc}
    if command -v php-config >/dev/null 2>&1 && command -v "$CC" >/dev/null 2>&1; then
        inc=$(php-config --includes)
        if "$CC" -O2 -bundle -undefined dynamic_lookup -o "$tmp/c-decimal.so" "$EX/c/decimal.c" $inc 2>"$tmp/c.err" ||
           "$CC" -O2 -shared -fPIC -o "$tmp/c-decimal.so" "$EX/c/decimal.c" $inc 2>>"$tmp/c.err"; then
            cso=$tmp/c-decimal.so
            differential "check.php (the C twin)" "$EX/check.php" -d extension="$cso"
        else
            bad "the C twin would not build:"; sed 's/^/      /' "$tmp/c.err"
        fi
    else
        skip "the C twin: no php-config or no $CC here -- the bench has no C column"
    fi
    # the bench row: three rounds, the processes interleaved, minimums
    bi=; bc=; bt=; ai=; ac=
    for r in 1 2 3; do
        set -- $("$PHP" "$EX/bench.php" | tr -d '\r')
        [ "$1" = interpreted ] || { bad "bench.php (interpreted): $*"; break; }
        bi=$(awk -v a="$bi" -v b="$2" 'BEGIN { print (a == "" || b < a) ? b : a }'); shift 2; ai=$*
        set -- $("$PHP" -d extension="$dso" "$EX/bench.php" | tr -d '\r')
        [ "$1" = compiled ] || { bad "bench.php (compiled): $*"; break; }
        bc=$(awk -v a="$bc" -v b="$2" 'BEGIN { print (a == "" || b < a) ? b : a }'); shift 2; ac=$*
        [ "$ai" = "$ac" ] || bad "bench.php: the two answers differ: $ai / $ac"
        if [ -n "$cso" ]; then
            set -- $("$PHP" -d extension="$cso" "$EX/bench.php" c | tr -d '\r')
            [ "$1" = c ] || { bad "bench.php (the C twin): $*"; break; }
            bt=$(awk -v a="$bt" -v b="$2" 'BEGIN { print (a == "" || b < a) ? b : a }'); shift 2
            [ "$ai" = "$*" ] || bad "bench.php: the C twin's answer differs: $*"
        fi
    done
    if [ -n "$bc" ]; then
        row="interpreted $bi ms, compiled $bc ms $(awk -v i="$bi" -v c="$bc" 'BEGIN { printf "(%.2fx)", i / c }')"
        [ -n "$bt" ] && row="$row, C twin $bt ms $(awk -v i="$bi" -v c="$bt" 'BEGIN { printf "(%.2fx)", i / c }')"
        say "bench: $row -- best of nine, three rounds interleaved; not gated"
    fi
fi

# --- db: sqlite3's C API called from PHP source ------------------------------
# examples/db/db.php declares libsqlite3 with #[Extern('sqlite3')] -- scalars,
# pointers and strings; slice 2 adds db_rows(), which assembles each row into a
# php associative array over those scalar reads (no new extern return type). The
# extension road resolves the symbols from php's own process, so it needs a php
# with sqlite3 loaded, and that is also what the oracle (oracle.php, php's
# SQLite3 class) uses. Not a differential (running the interpreted db.php against
# the module): interpreted, #[Extern] bodies are empty. The graded output is
# check.expect, and the oracle must print it too. Then the C twin (c/db.c),
# graded the same way, and the bench whose module/C ratio is the DONE bar
# (README.md) -- printed, as every bench here, not gated.
echo "  -- db"
EX=examples/db
dbso=$rootn/$EX/build/db.$sx
if [ "$host" = windows ]; then
    skip "db: an #[Extern] function is refused on Windows by name (the link names no library for it)"
elif ! "$PHP" -m | tr -d '\r' | grep -qix sqlite3; then
    skip "db: this php has no sqlite3 extension, so php's process has no sqlite3_* symbols and there is no oracle"
elif build "$EX" "$EX/mcphp$suf.toml" "db.$sx"; then
    say "built: $(wc -c < "$dbso" | tr -d ' ') bytes from $EX/db.php"
    "$PHP" -d extension="$dbso" "$EX/check.php" > "$tmp/db.out" 2> "$tmp/db.err"; drc=$?
    if [ "$drc" = 0 ] && [ ! -s "$tmp/db.err" ] && tr -d '\r' < "$tmp/db.out" | cmp -s - "$EX/check.expect"; then
        say "check.php: $(wc -l < "$tmp/db.out" | tr -d ' ') lines against check.expect, 1000 rows loaded through one prepared statement, pulled back as associative arrays (db_rows), in memory and on disk"
    else
        bad "db check.php: exit $drc, want check.expect"
        tr -d '\r' < "$tmp/db.out" | diff -u "$EX/check.expect" - | sed -n '3,20p' | sed 's/^/      /'
        sed 's/^/      /' "$tmp/db.err"
    fi
    "$PHP" "$EX/oracle.php" > "$tmp/dbo.out" 2> "$tmp/dbo.err"; orc=$?
    if [ "$orc" = 0 ] && [ ! -s "$tmp/dbo.err" ] && tr -d '\r' < "$tmp/dbo.out" | cmp -s - "$EX/check.expect"; then
        say "oracle.php: php's own SQLite3 class prints the same bytes, exit 0"
    else
        bad "db oracle.php: exit $orc, want check.expect and a quiet stderr"
        tr -d '\r' < "$tmp/dbo.out" | diff -u "$EX/check.expect" - | sed -n '3,20p' | sed 's/^/      /'
        sed 's/^/      /' "$tmp/dbo.err"
    fi
    vis=$("$PHP" -d extension="$dbso" -r '$f = get_extension_funcs("db"); sort($f); echo implode(" ", $f);' 2>&1 | tr -d '\r')
    if [ "$vis" = "db_close db_error db_exec db_load db_open db_rows db_scalar db_text" ]; then
        say "published: the eight db_* functions and none of the sqlite3_* declarations or _ helpers"
    else
        bad "db published: want the eight db_* functions, got: $vis"
    fi
    # a call leaves the request's memory where it found it: db.php's top-level
    # `const _SQLITE_TRANSIENT = -1;` used to be glued to _out8's body, so every
    # db_open, db_scalar and db_text registered the constant again and the
    # request grew by ~500 bytes a call until php's memory limit
    grow=$("$PHP" -d extension="$dbso" -r '$db = db_open(":memory:"); db_scalar($db, "SELECT 1"); db_text($db, "SELECT 1"); db_close(db_open(":memory:"));
        $m = memory_get_usage(); for ($i = 0; $i < 2000; $i++) { db_scalar($db, "SELECT 1"); db_text($db, "SELECT 1"); db_close(db_open(":memory:")); } echo memory_get_usage() - $m;' 2>&1 | tr -d '\r')
    if [ -n "$grow" ] && [ "$grow" -lt 4096 ] 2>/dev/null; then
        say "memory: 2000 calls each of db_scalar, db_text and db_open+db_close grow the request by $grow bytes"
    else
        bad "db memory: 2000 calls grew the request by $grow bytes (want under 4 KiB)"
    fi
    # the C twin (c/db.c): the same eight db_* functions written the ordinary
    # way, graded by the same check.php against check.expect, and the reference
    # the bench's DONE ratio is measured against. Like db.php it declares its own
    # sqlite3 symbols and links none, so it needs no sqlite3 dev package -- only
    # php-config and a C compiler; without them this says so and the bench has no
    # C column (and no DONE ratio).
    cso=
    CC=${CC:-cc}
    if command -v php-config >/dev/null 2>&1 && command -v "$CC" >/dev/null 2>&1; then
        inc=$(php-config --includes)
        if "$CC" -O2 -bundle -undefined dynamic_lookup -o "$tmp/c-db.so" "$EX/c/db.c" $inc 2>"$tmp/c.err" ||
           "$CC" -O2 -shared -fPIC -o "$tmp/c-db.so" "$EX/c/db.c" $inc 2>>"$tmp/c.err"; then
            cso=$tmp/c-db.so
            "$PHP" -d extension="$cso" "$EX/check.php" > "$tmp/dbc.out" 2> "$tmp/dbc.err"; dcrc=$?
            if [ "$dcrc" = 0 ] && [ ! -s "$tmp/dbc.err" ] && tr -d '\r' < "$tmp/dbc.out" | cmp -s - "$EX/check.expect"; then
                say "the C twin (c/db.c): check.php byte for byte check.expect, exit 0"
            else
                bad "the C twin check.php: exit $dcrc, want check.expect"
                tr -d '\r' < "$tmp/dbc.out" | diff -u "$EX/check.expect" - | sed -n '3,20p' | sed 's/^/      /'
                sed 's/^/      /' "$tmp/dbc.err"
            fi
        else
            bad "the C twin would not build:"; sed 's/^/      /' "$tmp/c.err"
        fi
    else
        skip "the C twin: no php-config or no $CC here -- the bench has no C column"
    fi
    # the bench row: the example's own workload (a 1000-row prepared bulk load,
    # three aggregates, a 200-row db_rows page), three rounds, the processes
    # interleaved, minimums. The module/C ratio is the DONE bar (README.md),
    # printed with the row; DONE is module/C < 2.0.
    bi=; bc=; bt=; ai=; ac=
    for r in 1 2 3; do
        set -- $("$PHP" "$EX/bench.php" | tr -d '\r')
        [ "$1" = interpreted ] || { bad "bench.php (interpreted): $*"; break; }
        bi=$(awk -v a="$bi" -v b="$2" 'BEGIN { print (a == "" || b < a) ? b : a }'); shift 2; ai=$*
        set -- $("$PHP" -d extension="$dbso" "$EX/bench.php" | tr -d '\r')
        [ "$1" = compiled ] || { bad "bench.php (compiled): $*"; break; }
        bc=$(awk -v a="$bc" -v b="$2" 'BEGIN { print (a == "" || b < a) ? b : a }'); shift 2; ac=$*
        [ "$ai" = "$ac" ] || bad "bench.php: the two answers differ: $ai / $ac"
        if [ -n "$cso" ]; then
            set -- $("$PHP" -d extension="$cso" "$EX/bench.php" c | tr -d '\r')
            [ "$1" = c ] || { bad "bench.php (the C twin): $*"; break; }
            bt=$(awk -v a="$bt" -v b="$2" 'BEGIN { print (a == "" || b < a) ? b : a }'); shift 2
            [ "$ai" = "$*" ] || bad "bench.php: the C twin's answer differs: $*"
        fi
    done
    if [ -n "$bc" ]; then
        row="interpreted $bi ms, compiled $bc ms $(awk -v i="$bi" -v c="$bc" 'BEGIN { printf "(%.2fx)", i / c }')"
        [ -n "$bt" ] && row="$row, C twin $bt ms, module/C $(awk -v m="$bc" -v c="$bt" 'BEGIN { printf "%.2fx", m / c }') (DONE < 2.0)"
        say "bench: $row -- best of nine, three rounds interleaved; not gated"
    fi
fi

# --- ctype: php-src's ext/ctype ported to PHP --------------------------------
# examples/ctype/ctype.php reproduces ext/ctype/ctype.c -- the eleven functions,
# the per-byte predicate delegated to the C library's is*() exactly as ctype.c
# does, and the int-argument quirk verbatim. ctype is COMPILED IN to this php
# (php -n still has it), so a redeclaration is impossible: the port publishes
# cty_* and check.php compares each against the built-in ctype_X over all 256
# bytes, the empty string, multi-character strings, ints across and outside the
# -128..255 window, and the non-int/non-string types -- byte for byte. The
# reference IS php's own ctype, so there is no twin and no oracle. The port is
# pure runtime -- strspn over compile-time literal sets, chr, strlen -- with no
# #[Extern] and no dylib. Then the bench, cty_* over php's own ctype_*, printed.
# SKIPPED on Windows only because it ships no mcphp.windows.toml build config.
echo "  -- ctype"
EX=examples/ctype
ctso=$rootn/$EX/build/ctype.$sx
if [ "$host" = windows ]; then
    skip "ctype: no mcphp.windows.toml build config (the port is pure runtime and would build; a Windows config is simply not shipped)"
elif build "$EX" "$EX/mcphp$suf.toml" "ctype.$sx"; then
    say "built: $(wc -c < "$ctso" | tr -d ' ') bytes from $EX/ctype.php"
    "$PHP" -d extension="$ctso" "$EX/check.php" > "$tmp/ct.out" 2> "$tmp/ct.err"; crc=$?
    if [ "$crc" = 0 ] && [ ! -s "$tmp/ct.err" ] && tr -d '\r' < "$tmp/ct.out" | cmp -s - "$EX/check.expect"; then
        say "check.php: $(sed -n 's/^cases //p' "$tmp/ct.out") cases against php's own ctype_*, byte for byte (all 256 bytes, the empty string, the int -128..255 quirk, the non-string types), exit 0"
    else
        bad "ctype check.php: exit $crc, want check.expect and a quiet stderr"
        tr -d '\r' < "$tmp/ct.out" | diff -u "$EX/check.expect" - | sed -n '3,20p' | sed 's/^/      /'
        sed 's/^/      /' "$tmp/ct.err"
    fi
    vis=$("$PHP" -d extension="$ctso" -r '$f = get_extension_funcs("ctype_port"); sort($f); echo implode(" ", $f);' 2>&1 | tr -d '\r')
    if [ "$vis" = "cty_alnum cty_alpha cty_cntrl cty_digit cty_graph cty_lower cty_print cty_punct cty_space cty_upper cty_xdigit" ]; then
        say "published: the eleven cty_* functions and none of the is*() declarations or _ helpers"
    else
        bad "ctype published: want the eleven cty_*, got: $vis"
    fi
    # the bench: cty_* against php's own compiled-in ctype_* in the same process,
    # best of nine interleaved. The reference is the C extension itself, so the
    # ratio is cty_* / ctype_*. It is over 2.0 -- a per-byte is*() call cannot
    # reach ctype.c's inlined rune-table loop, and the whole-string strspn() that
    # would close the gap hits an mc-php refcounting leak (README.md § The bench).
    # Printed, not gated, like every bench here.
    set -- $("$PHP" -d extension="$ctso" "$EX/bench.php" | tr -d '\r')
    if [ "$1" = cty ]; then
        say "bench: cty $2 ms, ctype $4 ms, module/ctype.so $6 -- best of nine interleaved; over 2.0, see README.md § The bench; not gated"
    else
        bad "ctype bench.php: $*"
    fi
fi

# --- bcmath: php-src's ext/bcmath ported to PHP ------------------------------
# examples/bcmath/bcmath.php reproduces ext/bcmath (libbcmath) over digit
# strings -- EXACT bcmath semantics, which means TRUNCATION at the scale, not
# rounding (that is examples/decimal). bcmath is loaded in this php and an
# internal name cannot be redeclared, so the port publishes bc_* and check.php
# is the byte-for-byte differential (module vs bcmath.php required), bccheck.php
# the second oracle against php's own built-in bcmath, then the C twin
# (c/bcmath.c) graded the same way and the bench whose module/C ratio is the
# DONE bar (README.md: < 2.0). SKIPPED on Windows only: it ships a
# mcphp.windows.toml and would build, but the C twin and bccheck need the
# host's bcmath, which the Windows legs' setup does not guarantee.
echo "  -- bcmath"
EX=examples/bcmath
bso=$rootn/$EX/build/bcmath_port.$sx
if build "$EX" "$EX/mcphp$suf.toml" "bcmath_port.$sx"; then
    say "built: $(wc -c < "$bso" | tr -d ' ') bytes from $EX/bcmath.php"
    differential check.php "$EX/check.php" -d extension="$bso"
    vis=$("$PHP" -d extension="$bso" -r '$f = get_extension_funcs("bcmath_port"); sort($f); echo implode(" ", $f);' 2>&1 | tr -d '\r')
    if [ "$vis" = "bc_add bc_ceil bc_comp bc_div bc_floor bc_mod bc_mul bc_pow bc_powmod bc_round bc_scale bc_sqrt bc_sub" ]; then
        say "published: the thirteen bc_* functions and none of the _bc_* helpers"
    else
        bad "bcmath published: want the thirteen bc_* functions, got: $vis"
    fi
    if "$PHP" -m | tr -d '\r' | grep -qix bcmath; then
        if "$PHP" -d extension="$bso" "$EX/bccheck.php" > "$tmp/bc.out" 2>&1 &&
           [ "$(tr -d '\r' < "$tmp/bc.out")" = "bcmath agrees: 10511 results, 0 wrong" ]; then
            say "$(tr -d '\r' < "$tmp/bc.out")"
        else
            bad "bcmath bccheck.php:"; sed 's/^/      /' "$tmp/bc.out"
        fi
    else
        skip "the bcmath cross-check: this php has no bcmath"
    fi
    # the C twin (c/bcmath.c): the same functions written the ordinary way,
    # bcmath.php's algorithm function by function, graded by the same check.php
    # and bccheck.php, and the reference the bench's module/C ratio is measured
    # against. It needs php-config and a C compiler; without them the bench has
    # no C column and no DONE ratio.
    cso=
    CC=${CC:-cc}
    if command -v php-config >/dev/null 2>&1 && command -v "$CC" >/dev/null 2>&1; then
        inc=$(php-config --includes)
        if "$CC" -O2 -bundle -undefined dynamic_lookup -o "$tmp/c-bcmath.so" "$EX/c/bcmath.c" $inc 2>"$tmp/c.err" ||
           "$CC" -O2 -shared -fPIC -o "$tmp/c-bcmath.so" "$EX/c/bcmath.c" $inc 2>>"$tmp/c.err"; then
            cso=$tmp/c-bcmath.so
            differential "check.php (the C twin)" "$EX/check.php" -d extension="$cso"
            if "$PHP" -m | tr -d '\r' | grep -qix bcmath; then
                if "$PHP" -d extension="$cso" "$EX/bccheck.php" > "$tmp/bc.out" 2>&1 &&
                   [ "$(tr -d '\r' < "$tmp/bc.out")" = "bcmath agrees: 10511 results, 0 wrong" ]; then
                    say "the C twin (c/bcmath.c): $(tr -d '\r' < "$tmp/bc.out") against the built-in"
                else
                    bad "the C twin bccheck.php:"; sed 's/^/      /' "$tmp/bc.out"
                fi
            fi
        else
            bad "the C twin would not build:"; sed 's/^/      /' "$tmp/c.err"
        fi
    else
        skip "the C twin: no php-config or no $CC here -- the bench has no C column"
    fi
    # the bench row: the mixed workload, three rounds interleaved, minimums; the
    # module/C ratio is the DONE bar (README.md), printed with the row.
    bi=; bc=; bt=; ai=; ac=
    for r in 1 2 3; do
        set -- $("$PHP" "$EX/bench.php" | tr -d '\r')
        [ "$1" = interpreted ] || { bad "bench.php (interpreted): $*"; break; }
        bi=$(awk -v a="$bi" -v b="$2" 'BEGIN { print (a == "" || b < a) ? b : a }'); shift 2; ai=$*
        set -- $("$PHP" -d extension="$bso" "$EX/bench.php" | tr -d '\r')
        [ "$1" = compiled ] || { bad "bench.php (compiled): $*"; break; }
        bc=$(awk -v a="$bc" -v b="$2" 'BEGIN { print (a == "" || b < a) ? b : a }'); shift 2; ac=$*
        [ "$ai" = "$ac" ] || bad "bench.php: the two answers differ: $ai / $ac"
        if [ -n "$cso" ]; then
            set -- $("$PHP" -d extension="$cso" "$EX/bench.php" c | tr -d '\r')
            [ "$1" = c ] || { bad "bench.php (the C twin): $*"; break; }
            bt=$(awk -v a="$bt" -v b="$2" 'BEGIN { print (a == "" || b < a) ? b : a }'); shift 2
            [ "$ai" = "$*" ] || bad "bench.php: the C twin's answer differs: $*"
        fi
    done
    if [ -n "$bc" ]; then
        row="interpreted $bi ms, compiled $bc ms $(awk -v i="$bi" -v c="$bc" 'BEGIN { printf "(%.2fx)", i / c }')"
        [ -n "$bt" ] && row="$row, C twin $bt ms, module/C $(awk -v m="$bc" -v c="$bt" 'BEGIN { printf "%.2fx", m / c }') (DONE < 2.0)"
        say "bench: $row -- best of nine, three rounds interleaved; not gated"
    fi
    # the per-function module/C ratios (MCPHP_EACH), the real DONE evidence --
    # each function under 2.0; printed, not gated
    if [ -n "$cso" ]; then
        MCPHP_EACH=1 "$PHP" -d extension="$bso" "$EX/bench.php" 2>/dev/null | tr -d '\r' > "$tmp/each.mod"
        MCPHP_EACH=1 "$PHP" -d extension="$cso" "$EX/bench.php" c 2>/dev/null | tr -d '\r' > "$tmp/each.c"
        pf=$(awk 'NR==FNR{if(NR>1)m[$1]=$2;next} FNR>1{printf "%s %.2f ", $1, m[$1]/$2}' "$tmp/each.mod" "$tmp/each.c")
        say "per-function module/C: $pf(DONE each < 2.0; not gated)"
    fi
fi

# --- two-extensions -------------------------------------------------------------
# Two extensions compiled from PHP, and B calls a function A publishes and
# B's source does not declare: looked up in php's function table when the
# call runs, as php does and as the C twins (c/extA.c, c/extB.c) do.
echo "  -- two-extensions"
EX=examples/two-extensions
aso=$rootn/$EX/build/extA.$sx; bso=$rootn/$EX/build/extB.$sx
if build "$EX" "$EX/extA$suf.toml" "extA.$sx" && build "$EX" "$EX/extB$suf.toml" "extB.$sx"; then
    say "built: extA $(wc -c < "$aso" | tr -d ' ') and extB $(wc -c < "$bso" | tr -d ' ') bytes from $EX/extA.php and extB.php"
    differential "check.php (A then B)" "$EX/check.php" -d extension="$aso" -d extension="$bso"
    differential "check.php (B then A)" "$EX/check.php" -d extension="$bso" -d extension="$aso"
    # B alone: php's own Error, "Call to undefined function a_add()", twice
    # (a failed lookup caches nothing)
    differential "alone.php (B without A)" "$EX/alone.php" -d extension="$bso"
    cao=; cbo=
    CC=${CC:-cc}
    if command -v php-config >/dev/null 2>&1 && command -v "$CC" >/dev/null 2>&1; then
        inc=$(php-config --includes)
        for x in A B; do
            if "$CC" -O2 -bundle -undefined dynamic_lookup -o "$tmp/c-ext$x.so" "$EX/c/ext$x.c" $inc 2>"$tmp/c.err" ||
               "$CC" -O2 -shared -fPIC -o "$tmp/c-ext$x.so" "$EX/c/ext$x.c" $inc 2>>"$tmp/c.err"; then
                :
            else
                bad "the C twin ext$x would not build:"; sed 's/^/      /' "$tmp/c.err"
            fi
        done
        if [ -f "$tmp/c-extA.so" ] && [ -f "$tmp/c-extB.so" ]; then
            cao=$tmp/c-extA.so; cbo=$tmp/c-extB.so
            differential "check.php (the C twins)" "$EX/check.php" -d extension="$cao" -d extension="$cbo"
            differential "alone.php (the C twin of B)" "$EX/alone.php" -d extension="$cbo"
        fi
    else
        skip "the C twins: no php-config or no $CC here -- the bench has no C column"
    fi
    # the bench row: the call through B into A, three rounds, the processes
    # interleaved, minimums; and the same work straight into A beside it
    bi=; bc=; bt=; di=; dc=; dt=; ai=
    for r in 1 2 3; do
        set -- $("$PHP" "$EX/bench.php" | tr -d '\r')
        [ "$1" = interpreted ] || { bad "bench.php (interpreted): $*"; break; }
        bi=$(awk -v a="$bi" -v b="$2" 'BEGIN { print (a == "" || b < a) ? b : a }')
        di=$(awk -v a="$di" -v b="$3" 'BEGIN { print (a == "" || b < a) ? b : a }'); shift 3; ai=$*
        set -- $("$PHP" -d extension="$aso" -d extension="$bso" "$EX/bench.php" | tr -d '\r')
        [ "$1" = compiled ] || { bad "bench.php (compiled): $*"; break; }
        bc=$(awk -v a="$bc" -v b="$2" 'BEGIN { print (a == "" || b < a) ? b : a }')
        dc=$(awk -v a="$dc" -v b="$3" 'BEGIN { print (a == "" || b < a) ? b : a }'); shift 3
        [ "$ai" = "$*" ] || bad "bench.php: the two answers differ: $ai / $*"
        if [ -n "$cao" ]; then
            set -- $("$PHP" -d extension="$cao" -d extension="$cbo" "$EX/bench.php" c | tr -d '\r')
            [ "$1" = c ] || { bad "bench.php (the C twins): $*"; break; }
            bt=$(awk -v a="$bt" -v b="$2" 'BEGIN { print (a == "" || b < a) ? b : a }')
            dt=$(awk -v a="$dt" -v b="$3" 'BEGIN { print (a == "" || b < a) ? b : a }'); shift 3
            [ "$ai" = "$*" ] || bad "bench.php: the C twins' answer differs: $*"
        fi
    done
    if [ -n "$bc" ]; then
        row="through B: interpreted $bi ms, compiled $bc ms $(awk -v i="$bi" -v c="$bc" 'BEGIN { printf "(%.2fx)", i / c }')"
        [ -n "$bt" ] && row="$row, C twins $bt ms $(awk -v i="$bi" -v c="$bt" 'BEGIN { printf "(%.2fx)", i / c }')"
        say "bench: $row -- best of nine, three rounds interleaved; not gated"
        row="straight into A: interpreted $di ms, compiled $dc ms"
        [ -n "$dt" ] && row="$row, C twin $dt ms"
        say "bench: $row"
    fi
fi
# two mc-php extensions that do NOT call each other, in one php: each carries
# the whole runtime, and each must keep using its own.
hso=$rootn/examples/hello/build/hello.$sx
# Built here and not reused: a .so an earlier run left behind may be another
# host's (the checkout is shared with the Linux container).
if build examples/hello "examples/hello/mcphp$suf.toml" "hello.$sx" && [ -f "$dso" ]; then
    for order in "$hso $dso" "$dso $hso"; do
        set -- $order
        got=$("$PHP" -d extension="$1" -d extension="$2" -r \
            'echo hello_greet(dec_add("40", "2.5", 1)), " ", dec_mul(hello_greet("x") === "hi x" ? "3" : "0", "7", 0);' 2>&1)
        if [ "$got" = "hi 42.5 21" ]; then
            say "hello and decimal in one php, $(basename "$1") first: both answer"
        else
            bad "hello and decimal in one php, $(basename "$1") first: want 'hi 42.5 21', got '$got'"
        fi
    done
fi

# The program-road bench rows below (threads, sync, await, connect) build at
# mc's -O (MCPHP_OPT=1), as every extension here does ([project].opt = 1):
# their twins are cc -O2.
# --- threads: the thread API on the program road --------------------------------
# examples/threads/primes.php counts the primes below 2 000 000 in slices, one
# thread each (docs/threads.md § Step 3), on 1 thread and on 4; the answer is
# checked against the one recorded here and against its C twin (pthreads or
# Win32 threads, c/primes.c), and the bench row -- mc-php's and the twin's
# wall clock on 1 and 4 threads, the best of three -- is printed, not gated.
echo "  -- threads"
EX=examples/threads
tw="primes below 2000000: 148933"
tb=$tmp/primes
t1=$(PRIMES_THREADS=1 MCPHP_OPT=1 MCPHP_BIN=$BIN MCPHP_OUT=$tb sh "$here/mcphp.sh" "$EX/primes.php" 2>&1 | tr -d '\r')
t4=$(PRIMES_THREADS=4 MCPHP_OPT=1 MCPHP_BIN=$BIN MCPHP_OUT=$tb sh "$here/mcphp.sh" "$EX/primes.php" 2>&1 | tr -d '\r')
if [ "$t1" = "$tw" ] && [ "$t4" = "$tw" ]; then
    say "primes.php: $tw, on 1 thread and on 4"
else
    bad "primes.php: want '$tw', got '$t1' on 1 thread and '$t4' on 4"
fi
tx=$tb; [ -f "$tb.exe" ] && tx=$tb.exe
CC=${CC:-cc}
if command -v "$CC" >/dev/null 2>&1 && "$CC" -O2 -o "$tmp/primes-c" "$EX/c/primes.c" -lpthread 2>"$tmp/c.err"; then
    tc=$tmp/primes-c; [ -f "$tc.exe" ] && tc=$tc.exe
    ct=$(PRIMES_THREADS=4 "$tc" | tr -d '\r')
    [ "$ct" = "$tw" ] && say "the C twin: $ct" || bad "the C twin: want '$tw', got '$ct'"
    # wall clock, best of three, measured by php itself
    row=$("$PHP" -r '
        $b = [];
        foreach ([[$argv[1], 1], [$argv[1], 4], [$argv[2], 1], [$argv[2], 4]] as $k => [$x, $n]) {
            $b[$k] = INF;
            for ($r = 0; $r < 3; $r++) {
                putenv("PRIMES_THREADS=$n");
                $t = hrtime(true); exec(escapeshellarg($x)); $d = (hrtime(true) - $t) / 1e6;
                if ($d < $b[$k]) $b[$k] = $d;
            }
        }
        printf("mc-php %.0f ms on 1 thread, %.0f ms on 4; C %.0f ms and %.0f ms", $b[0], $b[1], $b[2], $b[3]);' "$tx" "$tc")
    say "bench: $row -- best of three; not gated"
else
    skip "the C twin: no $CC here, or it would not build -- no C column"
fi

# --- sync: native sync on the program road --------------------------------------
# examples/sync/sync.php runs a bounded producer/consumer queue on eight
# threads -- a mutex, two condition variables, a semaphore, a wait group and
# atomics (docs/threads.md § Step 4) -- and prints a checksum both it and its C
# twin (pthreads + C11, c/sync.c) must reach exactly. The bench row is the two
# programs' wall clock, best of three, not gated.
echo "  -- sync"
EX=examples/sync
sb=$tmp/sync
sw="checksum 80000200000 expected 80000200000 ok"
sr=$(MCPHP_OPT=1 MCPHP_BIN=$BIN MCPHP_OUT=$sb sh "$here/mcphp.sh" "$EX/sync.php" 2>&1 | tr -d '\r')
if [ "$sr" = "$sw" ]; then
    say "sync.php: the checksum is exact on 4 producers and 4 consumers"
else
    bad "sync.php: want '$sw', got '$sr'"
fi
sx_bin=$sb; [ -f "$sb.exe" ] && sx_bin=$sb.exe
if [ "$host" = windows ]; then
    skip "the C twin of sync on Windows: pthreads and C11 threads are POSIX (README.md)"
elif command -v "$CC" >/dev/null 2>&1 && "$CC" -O2 -pthread -o "$tmp/sync-c" "$EX/c/sync.c" 2>"$tmp/c.err"; then
    cr=$("$tmp/sync-c" | tr -d '\r')
    [ "$cr" = "$sw" ] && say "the C twin: $cr" || bad "the C twin: want '$sw', got '$cr'"
    row=$("$PHP" -r '
        $b = [INF, INF];
        foreach ([$argv[1], $argv[2]] as $k => $x) {
            for ($r = 0; $r < 3; $r++) {
                $t = hrtime(true); exec(escapeshellarg($x)); $d = (hrtime(true) - $t) / 1e6;
                if ($d < $b[$k]) $b[$k] = $d;
            }
        }
        printf("mc-php %.0f ms, C %.0f ms (%.2fx)", $b[0], $b[1], $b[0] / $b[1]);' "$sx_bin" "$tmp/sync-c")
    say "bench: $row -- best of three; not gated"
else
    skip "the C twin of sync: no $CC here, or it would not build -- no C column"
fi

# --- await (step 5): the event loop, fibers and await of real I/O ---------------
# tests/c/18-await.php runs on the program road (a timer, a future, fibers that
# await a timer over ph_ctx_swap, a pipe read); its C twin (kqueue/epoll +
# ucontext, tests/c/await.c) must reach the SAME output byte for byte, and the
# two are timed. The .php is graded against tests/c/18-await.out by the fixture
# harness too; here it is the twin that proves the loop's semantics independently.
echo "  -- await"
aw=$tmp/await
# capture to a file (so the program's exit status survives, not tr's, and
# trailing newlines are not stripped by $(...)), normalize CRs to another file,
# and cmp byte for byte against the expected output
MCPHP_OPT=1 MCPHP_BIN=$BIN MCPHP_OUT=$aw sh "$here/mcphp.sh" tests/c/18-await.php > "$tmp/await.raw" 2>&1; arc=$?
aw_bin=$aw; [ -f "$aw.exe" ] && aw_bin=$aw.exe
tr -d '\r' < tests/c/18-await.out > "$tmp/await.want"
tr -d '\r' < "$tmp/await.raw" > "$tmp/await.got"
if [ "$arc" = 0 ] && cmp -s "$tmp/await.got" "$tmp/await.want"; then
    say "18-await.php: timer, future, spawned fibers over ph_ctx_swap, and a pipe read"
else
    bad "18-await.php: output differs from 18-await.out (exit $arc)"
fi
if [ "$host" = windows ]; then
    skip "the C twin of await on Windows: kqueue/epoll and ucontext are POSIX (the .php uses IOCP)"
elif command -v "$CC" >/dev/null 2>&1 && "$CC" -O2 -o "$tmp/await-c" tests/c/await.c 2>"$tmp/c.err"; then
    "$tmp/await-c" > "$tmp/await-c.raw"; crc=$?
    tr -d '\r' < "$tmp/await-c.raw" > "$tmp/await-c.got"
    { [ "$crc" = 0 ] && cmp -s "$tmp/await-c.got" "$tmp/await.want"; } \
        && say "the C twin (kqueue/epoll + ucontext): byte for byte the .php" \
        || bad "the C twin: output differs from the .php (exit $crc)"
    row=$("$PHP" -r '
        $b = [INF, INF];
        foreach ([$argv[1], $argv[2]] as $k => $x) {
            for ($r = 0; $r < 3; $r++) {
                $t = hrtime(true); exec(escapeshellarg($x)); $d = (hrtime(true) - $t) / 1e6;
                if ($d < $b[$k]) $b[$k] = $d;
            }
        }
        printf("mc-php %.0f ms, C %.0f ms (%.2fx)", $b[0], $b[1], $b[0] / $b[1]);' "$aw_bin" "$tmp/await-c")
    say "bench: $row -- best of three; not gated"
else
    skip "the C twin of await: no $CC here, or it would not build -- no C column"
fi

# --- connect (step 6b): a non-blocking TCP connect + read on the loop ----------
# tests/c/22-connect.php connects to a blocking loopback peer on another thread
# and reads its reply, both driven by the loop; its C twin (kqueue/epoll +
# pthread, tests/c/connect.c) must reach the SAME output byte for byte, and the
# two are timed. The .php is graded against 22-connect.out by the fixture
# harness on all five legs (IOCP on Windows); here the twin proves the POSIX
# backends' connect/read semantics independently.
echo "  -- connect"
cn=$tmp/connect
MCPHP_OPT=1 MCPHP_BIN=$BIN MCPHP_OUT=$cn sh "$here/mcphp.sh" tests/c/22-connect.php > "$tmp/connect.raw" 2>&1; crc=$?
cn_bin=$cn; [ -f "$cn.exe" ] && cn_bin=$cn.exe
tr -d '\r' < tests/c/22-connect.out > "$tmp/connect.want"
tr -d '\r' < "$tmp/connect.raw" > "$tmp/connect.got"
if [ "$crc" = 0 ] && cmp -s "$tmp/connect.got" "$tmp/connect.want"; then
    say "22-connect.php: a non-blocking connect and read driven by the loop"
else
    bad "22-connect.php: output differs from 22-connect.out (exit $crc)"
fi
if [ "$host" = windows ]; then
    skip "the C twin of connect on Windows: kqueue/epoll and pthreads are POSIX (the .php uses IOCP)"
elif command -v "$CC" >/dev/null 2>&1 && "$CC" -O2 -o "$tmp/connect-c" tests/c/connect.c 2>"$tmp/cc.err"; then
    "$tmp/connect-c" > "$tmp/connect-c.raw"; ccrc=$?
    tr -d '\r' < "$tmp/connect-c.raw" > "$tmp/connect-c.got"
    { [ "$ccrc" = 0 ] && cmp -s "$tmp/connect-c.got" "$tmp/connect.want"; } \
        && say "the C twin (kqueue/epoll + pthread): byte for byte the .php" \
        || bad "the C twin of connect: output differs from the .php (exit $ccrc)"
    crow=$("$PHP" -r '
        $b = [INF, INF];
        foreach ([$argv[1], $argv[2]] as $k => $x) {
            for ($r = 0; $r < 3; $r++) {
                $t = hrtime(true); exec(escapeshellarg($x)); $d = (hrtime(true) - $t) / 1e6;
                if ($d < $b[$k]) $b[$k] = $d;
            }
        }
        printf("mc-php %.0f ms, C %.0f ms (%.2fx)", $b[0], $b[1], $b[0] / $b[1]);' "$cn_bin" "$tmp/connect-c")
    say "bench: $crow -- best of three; not gated"
else
    skip "the C twin of connect: no $CC here, or it would not build -- no C column"
fi

# --- awaitable -----------------------------------------------------------------
# The compiled awaitable.src.php: a ZTS extension on native OS threads and native
# sync (docs/threads.md steps 3 and 4). parallel() runs each php callable on an
# OS thread of its own, which a thread-safe php runs as a php request of its own
# (§ 3b, opcache required), so it loads only into a ZTS php with opcache. macOS
# ships an NTS php, so this is SKIPPED there; CI runs it on the ZTS legs --
# macos/arm64, linux/{aarch64,x86_64} (in php:8.5-zts-alpine), and windows -- and
# tests/frankenphp.sh runs the ZTS road under a real threaded SAPI.
echo "  -- awaitable"
EX=examples/awaitable
if [ "$TSV" != zts ]; then
    skip "awaitable: needs a thread-safe (ZTS) php; this one is $TSV (docs/threads.md § 3b). CI's ZTS legs run it"
elif ! "$PHP" -m | tr -d '\r' | grep -qi opcache; then
    skip "awaitable: a php callable on a thread needs opcache (docs/threads.md § 3b); this php has none"
else
    # the compiled module: check.php byte for byte against check.expect, and the
    # timed demo. -d opcache.enable_cli=1: parallel()'s php callables are 3b
    # workers, which need the code opcache caches.
    if build "$EX" "$EX/mcphp$suf.toml" "awaitable.$sx"; then
        say "built: $(wc -c < "$EX/build/awaitable.$sx" | tr -d ' ') bytes from $EX/awaitable.src.php"
        "$PHP" -d extension="$EX/build/awaitable.$sx" -d opcache.enable_cli=1 "$EX/check.php" > "$tmp/aw.out" 2>&1; awrc=$?
        if [ "$awrc" = 0 ] && cmp -s "$tmp/aw.out" "$EX/check.expect"; then
            say "check.php: $(wc -l < "$tmp/aw.out" | tr -d ' ') lines, every one check.expect's"
        else
            bad "check.php exited $awrc, or differs from $EX/check.expect:"
            diff -u "$EX/check.expect" "$tmp/aw.out" | sed -n '3,24p' | sed 's/^/      /'
        fi
        "$PHP" -d extension="$EX/build/awaitable.$sx" -d opcache.enable_cli=1 "$EX/demo.php" > "$tmp/demo.out" 2>&1; demorc=$?
        if [ "$demorc" = 0 ] && grep -q '^same results: true$' "$tmp/demo.out"; then
            say "demo.php: $(sed -n 2p "$tmp/demo.out" | tr -s ' ')"
        else
            bad "demo.php (exit $demorc):"; sed -n '1,12p' "$tmp/demo.out" | sed 's/^/      /'
        fi
        rm -rf "$EX/build"
    fi
    # the C twin (c/awaitable.c): the same workload as an ordinary C extension,
    # on native pthreads -- the specification the module is measured against. Its
    # driver c/twin.php names each parallel workload (the twin has no php
    # interpreter per thread, so it runs the C EQUIVALENT), and prints
    # check.expect's bytes: the module's checksum. POSIX pthreads, so not Windows.
    CC=${CC:-cc}
    if [ "$host" = windows ]; then
        skip "the C twin of awaitable on Windows: pthreads are POSIX; CI's ZTS legs cover the module there (README.md)"
    elif command -v php-config >/dev/null 2>&1 && command -v "$CC" >/dev/null 2>&1; then
        inc=$(php-config --includes)
        if "$CC" -O2 -bundle -undefined dynamic_lookup -o "$tmp/c-awaitable.so" "$EX/c/awaitable.c" $inc -lpthread 2>"$tmp/c.err" ||
           "$CC" -O2 -shared -fPIC -o "$tmp/c-awaitable.so" "$EX/c/awaitable.c" $inc -lpthread 2>>"$tmp/c.err"; then
            "$PHP" -d extension="$tmp/c-awaitable.so" -d opcache.enable_cli=1 "$EX/c/twin.php" > "$tmp/awc.out" 2>&1; awcrc=$?
            if [ "$awcrc" = 0 ] && cmp -s "$tmp/awc.out" "$EX/check.expect"; then
                say "the C twin: twin.php $(wc -l < "$tmp/awc.out" | tr -d ' ') lines, every one check.expect's (the module's checksum)"
            else
                bad "the C twin: twin.php exited $awcrc, or differs from $EX/check.expect:"
                diff -u "$EX/check.expect" "$tmp/awc.out" | sed -n '3,24p' | sed 's/^/      /'
            fi
        else
            bad "the C twin of awaitable would not build:"; sed 's/^/      /' "$tmp/c.err"
        fi
    else
        skip "the C twin of awaitable: no php-config or no $CC here"
    fi
fi

[ "$fail" = 0 ] || { echo "  examples: something failed"; exit 1; }
echo "  examples: green"

# Sourced by tests/ext.sh and tests/examples.sh: the thread safety of the php
# under test, and the project file for it.
#
# Every project file in this repository says `thread_safety = "nts"`: the
# compiler never reads a php to find out (docs/mcphp-toml.md § [php]), so a
# gate run against a ZTS php builds from a COPY that says "zts". The copy sits
# beside the file it copies -- its relative paths mean what they meant there --
# under the hidden name `.mcphp-test-<file>` (.gitignore has the prefix), and
# mcphp_ts_clean removes every copy.
#
#   mcphp_ts_init     TSV=nts or zts, from "$PHP -i"
#   mcphp_ts_cfg F    prints F for an NTS php, else writes and prints the copy
mcphp_ts_init() {
    TSV=nts
    [ "$("$PHP" -i | tr -d '\r' | sed -n 's/^Thread Safety => //p' | head -1)" = enabled ] && TSV=zts
}
mcphp_ts_cfg() {
    if [ "$TSV" = nts ]; then printf '%s\n' "$1"; return; fi
    _c="$(dirname "$1")/.mcphp-test-$(basename "$1")"
    # php8.lib is the import library of an NTS php (php8.dll): a ZTS php is
    # php8ts.dll. Swapped as src/build.mc's "both" swaps it: in a Windows
    # project file only, and only where it is a whole word
    if grep -q '^os *= *"windows"' "$1"; then
        sed -E -e 's/^thread_safety = .*/thread_safety = "zts"/' \
            -e 's#(^|[^A-Za-z0-9_.-])php8\.lib([^A-Za-z0-9_.-]|$)#\1php8ts.lib\2#g' "$1" > "$_c"
    else
        sed -e 's/^thread_safety = .*/thread_safety = "zts"/' "$1" > "$_c"
    fi
    printf '%s\n' "$_c"
}
mcphp_ts_clean() {
    rm -f examples/*/.mcphp-test-*
}

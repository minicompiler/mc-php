# Sourced by tests/ext.sh and tests/examples.sh: the thread safety of the php
# under test, and the project file for it.
#
# Every project file in this repository says `thread_safety = "nts"`: the
# compiler never reads a php to find out (docs/mcphp-toml.md § [php]), so a
# gate run against a ZTS php builds from a COPY that says "zts". The copy sits
# beside the file it copies -- its relative paths mean what they meant there --
# under a hidden name, and mcphp_ts_clean removes every copy.
#
#   mcphp_ts_init     TSV=nts or zts, from "$PHP -i"
#   mcphp_ts_cfg F    prints F for an NTS php, else writes and prints the copy
mcphp_ts_init() {
    TSV=nts
    [ "$("$PHP" -i | tr -d '\r' | sed -n 's/^Thread Safety => //p' | head -1)" = enabled ] && TSV=zts
}
mcphp_ts_cfg() {
    if [ "$TSV" = nts ]; then printf '%s\n' "$1"; return; fi
    _c="$(dirname "$1")/.$(basename "$1").zts-test"
    # php8.lib is the import library of an NTS php (php8.dll): a ZTS php is
    # php8ts.dll, as src/build.mc's "both" swaps it
    sed -e 's/^thread_safety = .*/thread_safety = "zts"/' -e 's/php8\.lib/php8ts.lib/g' "$1" > "$_c"
    printf '%s\n' "$_c"
}
mcphp_ts_clean() {
    rm -f examples/*/.*.zts-test
}

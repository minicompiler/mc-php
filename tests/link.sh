# mcphp_link OBJ EXE -- link an mc-php object into a program with the host's
# linker and libc. Sourced by tests/mcphp.sh, tests/bench/bench10.sh and the
# linux smoke in tests/linux.sh so the proven per-host link command lives in
# ONE place.
#
# There is no one-step `--exe` road any more (docs/plan.md): mc-php writes an
# OBJECT on every host and the platform linker makes the program, against the
# platform libc. The three commands are the ones probes/drop-exe measured:
#
#   macOS    ld -lSystem -syslibroot <sdk>              ld ad-hoc signs, LC_MAIN
#   Linux    ld.lld -dynamic-linker ld-musl ... -lc     needs musl-dev (crt+libc)
#   Windows  lld-link -entry:mc_start -nodefaultlib ...  kernel32.lib + ucrtbase.lib
#
# The macOS SDK path is `xcrun --show-sdk-path`; a caller that links many
# programs (the grid) exports MCPHP_SDK once so this is not re-run per test.
# Windows reads MCPHP_WINLINK (the directory tests/winsys.sh fills) and
# MCPHP_WINMACHINE (the lld-link -machine for the arch).
mcphp_link() {
    _obj=$1
    _exe=$2
    case $(uname -s) in
        Darwin)
            _sdk=${MCPHP_SDK:-$(xcrun --show-sdk-path 2>/dev/null)}
            ld "$_obj" -lSystem -syslibroot "$_sdk" -o "$_exe"
            ;;
        Linux)
            ld.lld -dynamic-linker "/lib/ld-musl-$(uname -m).so.1" -L/usr/lib \
                /usr/lib/crt1.o /usr/lib/crti.o "$_obj" -lc /usr/lib/crtn.o \
                -o "$_exe"
            ;;
        MINGW*|MSYS*|CYGWIN*)
            lld-link -machine:"${MCPHP_WINMACHINE:-arm64}" -subsystem:console \
                -entry:mc_start -nodefaultlib -out:"$_exe" "$_obj" \
                "$MCPHP_WINLINK/kernel32.lib" "$MCPHP_WINLINK/ucrtbase.lib"
            ;;
        *)
            echo "mcphp_link: unknown host $(uname -s)" >&2
            return 2
            ;;
    esac
}

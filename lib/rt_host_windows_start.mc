// rt_host_windows_start.mc -- the entry point of a PROGRAM mc-php writes for
// Windows. A file of its own because it names `main`, and a php EXTENSION has
// no `main` (its statement stream is mc_php_minit): src/program.mc pushes this
// on the program road only.
//
// The loader enters with no arguments and there is no C runtime to call main;
// ExitProcess is the exit. The command line is not split: the runtime has no
// $argv to fill (a php program compiled here reads none), so there is nothing
// to split it into. On the one-step road mc keeps an `mc_start` the program
// defines (mc's docs/reference/objects.md § 8c); on the object road it is what
// `lld-link -entry:mc_start` names.
i64 mc_start() {
    ExitProcess(main());
    return 0;
}

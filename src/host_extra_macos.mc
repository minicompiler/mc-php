// host_extra_macos.mc -- what this compiler needs from the macOS host that
// mc's own macOS host layer does not declare (src/host_extra_linux.mc says
// why this is per entry).
//
// getpid(3): src/build.mc names the ZTS copy of a project file after this
// process, so two builds of one project at once never write the same file.
extern i64 getpid();

i64 ph_pid() { return c_int(getpid()); }

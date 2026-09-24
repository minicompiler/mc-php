// mc-php-windows-aarch64.mc -- the compiler hosted on windows/aarch64.
//
// src/mc-php.mc with the host layer named, for the reason
// src/mc-php-linux-x86_64.mc gives: `#include <mc/host>` resolves to the host
// of the compiler DOING the build.
//
// It is compiled to a COFF OBJECT and linked with lld-link next to two objects
// and an import library (tests/winsys.sh builds them; src/mc-php.windows-aarch64.toml
// names them). Not the one-step `--exe`: mc's core DECLARES `write`, `open`
// and the other POSIX names `extern` and `<sys_windows>` DEFINES them, and one
// translation unit cannot do both -- measured with mc 1.3.0,
// `lib/sys_windows.mc:94: function declared twice` (docs/plan.md § 5). mc's own
// Windows compiler is built the same way, for the same reason.
//
//   sh tests/winsys.sh aarch64 && mc build src --config src/mc-php.windows-aarch64.toml
#include <mc/host_windows_aarch64>
#include <mc/core>
#include "host_extra_windows.mc"
#include <float>
#include <machine_arm64_float>
#include <machine_x86_64_float>
#include "php.mc"

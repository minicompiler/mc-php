// mc-php-linux-aarch64.mc -- the compiler hosted on linux/aarch64.
//
// src/mc-php.mc with one line changed: the host layer. `#include <mc/host>`
// resolves to the host file of the compiler DOING the build (mc's own rule),
// so cross-building through it bakes the builder's host into the product. That
// was measured before this file existed: the ELF it produced linked and then
// refused to load, `Error relocating ./mcphp: _NSGetEnviron: symbol not
// found`, and the same for `_NSGetExecutablePath` -- both libSystem-only.
// Naming the host is the answer mc gives itself (src/mc_linux.mc).
//
// Nothing else about the compiler changes. The RUNTIME it pushes into every
// program it compiles is chosen separately, by src/program.mc, from host_os()
// and host_arch() -- which are this file's answers.
//
//   mc build src --config src/mc-php.linux-aarch64.toml
#include <mc/host_linux_aarch64>
#include <mc/core>
#include "host_extra_linux.mc"
#include <float>
#include <machine_arm64_float>
#include <machine_x86_64_float>
#include "php.mc"

// mc-php.mc -- the compiler's entry point.
//
// mc's own core, the float library (php's `float` is <float>'s f64, and the
// two float machines are what lower it on arm64 and x86-64), and this
// repository's module. `mc build` reads mc.toml and writes build/mc-php.
#include <mc/host>
#include <mc/core>
#include <float>
#include <machine_arm64_float>
#include <machine_x86_64_float>
#include "php.mc"

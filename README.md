# mc-php

**A compiler that turns PHP source into a native PHP extension -- no C, no `phpize`, no
autotools, no php development headers.** The front end is PHP 8.5 taught to
[mc](https://github.com/minicompiler/mc) as one Tier 3 module; the back end emits `get_module()`,
a `zend_module_entry` and the `zend_function_entry` tables that php loads.

The rule that makes it meaningful: **a `.php` source is PHP**. It runs under `php` and it compiles
with `mc-php`, and the two must agree -- the oracle is php-src's own `.phpt` corpus, run under
both. No dialect, no annotations, no "mc-php mode".

---

## The state today, honestly

This is a **proof of concept**, and what exists is the front end.

**What works.** The compiler reads PHP 8.5 and produces a native binary, on **macOS arm64,
linux/aarch64 and linux/x86_64** -- one binary per host, each of which was run on a host of its
own architecture and graded there against that host's own `php`. Over php-src's whole `.phpt`
corpus -- 21395 tests -- it agrees with `php` on **1705**, byte for byte on stdout and on the
exit code. Classes, interfaces, traits, enums, closures, exceptions, references, `match`,
heredocs, late static binding, `printf`, a 272-row library, `ext/json` written in mc: all of it
is in, and each of it is measured rather than claimed.

**What does not work yet.**

| | |
|---|---|
| **the extension back end** | **not written.** This repository compiles a PHP *program* to a binary today. `get_module()` and the module entry are proven by hand outside it (`probes/t1`..`t3`) and are the next step. |
| `mcphp.toml` | the project file is **designed and documented, not implemented** -- see [docs/mcphp-toml.md](docs/mcphp-toml.md). Today the compiler is driven as `mc-php --exe FILE.php -o BIN`. |
| Windows | **not built.** macOS arm64, linux/aarch64 and linux/x86_64 are built, run and graded; Windows is not, and [Install](#install) says exactly what it is missing. |
| generators | `yield` is not built. 252 of the 13623 disagreeing tests use it; the decision and its cost are in `docs/plan.md` D6. |
| `eval` and reflection | refused **by design**, by name, with exit 3 -- `docs/plan.md` D1 and D6. A refusal is an answer, not a failure. |
| most of the corpus | 14468 tests still disagree and 1929 are refused by design. The number below is the whole claim; nothing here rounds it up. |

---

## Install

Every tagged version is a GitHub release carrying a built compiler and its checksum, one archive
per host.

| host | archive | proved by |
|---|---|---|
| macOS arm64 | `mc-php-$V-macos-arm64.tar.gz` | built and graded on the release runner (`tests/run.sh`) |
| Linux aarch64 | `mc-php-$V-linux-arm64.tar.gz` | cross-built on that runner, then unpacked and graded on an `ubuntu-24.04-arm` runner (`tests/linux.sh`) |
| Linux x86_64 | `mc-php-$V-linux-x86_64.tar.gz` | the same, on `ubuntu-24.04` |

```sh
# the newest tag, so this block does not go stale with the next release
V=$(curl -fsSL https://api.github.com/repos/minicompiler/mc-php/releases/latest \
     | sed -n 's/.*"tag_name": *"v\([^"]*\)".*/\1/p')
A=mc-php-$V-macos-arm64          # or mc-php-$V-linux-arm64, mc-php-$V-linux-x86_64
BASE=https://github.com/minicompiler/mc-php/releases/download/v$V
curl -fsSLO $BASE/$A.tar.gz
curl -fsSLO $BASE/$A.tar.gz.sha256
shasum -a 256 -c $A.tar.gz.sha256      # sha256sum on Linux
tar -xzf $A.tar.gz
sudo mv $A/mc-php /usr/local/bin/
```

Verify the checksum before unpacking it, not after: the line above fails loudly if the archive is
not the one that was built.

**The archive is one binary and there is nothing to install beside it.** The runtime is inside the
compiler (`#embed`) and since the hosts branch it declares its own system calls, so a released
mc-php does not need mc, mc's library tree, a linker or a sysroot to compile a `.php`. The Linux
binaries are dynamic ELF64 against **musl** (`/lib/ld-musl-<arch>.so.1`); on a glibc distribution
run them in a musl container, or build your own with `libc = "gnu"` in `[target]`.

A row is here because something **ran** it. `file` saying "ELF 64-bit LSB executable" is not a
proof and no row rests on one.

### Why there is no Windows archive

Two things are missing and both are named rather than estimated.

**The compiler.** mc has a direct PE writer for windows/x86_64 (`pe-exe-x86_64`), which would need
no linker -- but not for a translation unit like this one. mc-php's entry would have to carry both
`<mc/host_windows_x86_64>` and `<sys_windows_host>`, and the two collide: measured,
`lib/sys_windows.mc:76: duplicate #define`, because `src/host_windows.mc` and `lib/sys_windows.mc`
both define `O_CREAT` and `O_TRUNC`. mc's own Windows compiler avoids it by compiling the layer
into a separate object (`mcrt.obj`) and linking, so mc-php would need the same road: `lld-link`,
`llvm-dlltool`, and a sysroot of three files it generates itself.

**The runtime.** `lib/rt_host_windows.mc` does not exist. kernel32 has no `stat`, `lseek`,
`access`, `getenv`, `unlink`, `rename`, `mkdir`, `rmdir`, `getpid`, `getcwd`, `chdir`, `chmod`,
`putenv` or `unsetenv` under those names, so every one of them is a shim over
`GetFileAttributesExA`, `SetFilePointerEx`, `GetEnvironmentVariableA` and the rest -- and `chmod`
has no honest equivalent at all, which is the kind of thing that has to be said in the file and
made to fail the way php fails, not quietly.

Neither is speculative work and neither is in this repository yet. Until it is run on a Windows
runner there is no row.

## What you need

Nothing that compiles C. That absence is the product, so it is stated rather than left to be
noticed: **no php header file is opened on any row, and `php-config`, `phpize` and the php
development package are on no row at all.** The only thing read out of php is four values from
`php -i`, and even those can be written into the project file so a cross-build needs no php on
the machine.

### To build the compiler and run the tests (today)

| | what | why |
|---|---|---|
| every OS | **mc 1.1.0 or newer** -- [a release](https://github.com/minicompiler/mc/releases), untarred, `mc` on `PATH` | `p_skip_to` and `syntax_expr("$")` landed in 1.1.0 and PHP's byte stream cannot be owned without them (`probes/t4`) |
| every OS | **php 8.5**, any build | only for the TESTS: every fixture is compared byte for byte against what `php` prints |
| every OS | **python3** | the `.phpt` grid runner and three source gates |
| for the grid only | **php-src at tag `php-8.5.10`**, cloned at the repository root | it is the oracle corpus, 21395 tests, and it is not committed |
| for `tests/linux.sh` only | **docker** | it runs the fixture gate inside `php:8.5-alpine`, on the host the Linux binary is for |

### What the extension road needs (the road being built)

One row per operating system, each naming the exact command that provides it.

| OS | what | provided by | note |
|---|---|---|---|
| **every** | mc 1.1.0+ | [a published mc release](https://github.com/minicompiler/mc/releases) | measured here |
| **every** | a `php` of the **target** build, *or* four values written into `mcphp.toml` | any php 8.5 install | only `PHP API`, `PHP Extension Build`, `Thread Safety` and `Debug Build` are read -- they are `zend_module_entry`'s `zend_api`, `build_id`, `zts` and `zend_debug`, and nothing else about php is consulted. **Cross-build: state the four and no php is needed.** |
| **macOS** | `ld`, and `xcrun --show-sdk-path` | `xcode-select --install` (the Xcode command line tools) | the link is `ld -bundle -undefined dynamic_lookup` |
| **Linux** | a linker that does `-shared -Bsymbolic` | `apt install lld` / `dnf install lld` -- `ld.lld` is what was measured | `-Bsymbolic` is **not optional**: mc takes the address of its own functions with `adrp`/`add`, and in a shared object a default-visibility symbol is preemptible, so the link is refused without it |
| **Windows** | `lld-link` and `llvm-dlltool` | one LLVM install ([releases](https://github.com/llvm/llvm-project/releases), or `brew install llvm` when cross-building) | there is no flat namespace there, so every `zend_*` comes from an import library -- and an import library is only a list of names, so a two-line `.def` plus `llvm-dlltool` replaces the whole development pack. **No Windows SDK, no php devel pack.** |

Provenance, because a dependency list is worth what its measurement is worth: the mc and php rows
and the macOS tools were verified on this host (macOS 26 / arm64, PHP 8.5.10 Homebrew NTS, mc
1.1.0) on 2026-09-22, and the four-value mapping was checked against `php-src/Zend/zend_modules.h`
at tag `php-8.5.10`. The Linux and Windows link lines in the table above are the owner's
measurements of the EXTENSION road, recorded here and not yet exercised; the **program** road has
run on Linux since the hosts branch -- see [Install](#install) and `tests/linux.sh`.

---

## Build

```sh
mc build                      # macOS -> build/mc-php
build/mc-php --exe hello.php -o hello && ./hello
```

`mc.toml` is the project file and there is no makefile: the same rule the compiler is being built
to offer, applied to itself.

### On Linux, and for any other host

There is one entry per host and `mc build` picks none of them for you.

```sh
mc build src --config src/mc-php.linux-aarch64.toml   # -> build/mc-php-linux-arm64
mc build src --config src/mc-php.linux-x86_64.toml    # -> build/mc-php-linux-x86_64
```

Those two are the **cross-build** road from any host *and* the **native** road on Linux: a
`[target]` equal to the host is an ordinary build. Neither needs a linker or a sysroot --
`os = "linux"` has a direct-executable backend since mc's M42, so mc writes the dynamic ELF64
itself.

`mc build` with no config is `src/mc-php.mc`, whose `#include <mc/host>` resolves to the host
layer of the compiler **doing the build**. That is right natively and wrong for a cross build --
through it a macOS layer went into a Linux binary, which linked and then would not load
(`Error relocating ./mcphp: _NSGetEnviron: symbol not found`) -- and it is also not enough on
Linux even natively: `src/stmt.mc` calls `realpath(3)` and only mc's **macOS** host layer
declares it, so `mc build` there is `src/stmt.mc:195: call to unknown function`. Measured with mc
1.1.0 natively on linux/aarch64, both ways: the config builds, the bare `mc build` does not. The
declaration cannot simply be added for every host, because a second `extern` of a name the host
layer already has is `function declared twice`; it is `src/host_extra_linux.mc`, which the two
Linux entries include.

### One thing about mc's library tree

`build/mc-php` is a **different binary from `mc`**, and `src/mc-php.mc` includes `<float>` and
the two float machines. Since mc's M52 those are *library* names, resolved out of a **tree** and
not out of the compiler's own blob -- so **building** mc-php needs one. If you installed mc with
`mc install`, `$HOME/.mc/libs/mc/v<version>/` is that tree and there is nothing to do. If you
just untarred an mc release, put the `lib/mc` it carries there:

```sh
mkdir -p ~/.mc/libs
cp -R /path/to/mc-1.1.0-macos-arm64/lib/mc ~/.mc/libs/mc
```

**Running** mc-php needs none of it. The runtime used to open with `#include <sys>` -- a library
name too -- so every program mc-php compiled needed the tree as well, and a released binary alone
answered `#include <sys>: not in this compiler and mc 1.1.0's library tree was not found: run mc
install`. It declares its own system calls now (`lib/rt_host_*.mc`), which is what makes a
one-binary archive honest.

## Test

```sh
sh tests/run.sh               # the fast gates, about three minutes
```

Seven gates, and they are what CI runs on every push:

| gate | what it asserts |
|---|---|
| `d8check` | every `.php` in the project is in a regime with an obligation (`docs/plan.md` D8) |
| `lencheck` | every hand-counted string length in `src/` and `lib/` is right |
| `aritycheck` | every library row's callee exists in the runtime with that many parameters |
| fixtures | `tests/g/*.php` byte for byte what `php` prints, on **both** streams and the exit code |
| refusals | `tests/r/*.php` parse under `php` and are refused **by name** by mc-php, exit 3 |
| D8 (a) | the workload's `TestCase` **run** in both worlds -- every declared `test*` executed in each, both exiting 0, and the two outputs identical |
| D8 (b) | `tests/bench/bench10.sh`, which refuses to time `main.php` and `heavy.php` unless the two worlds agree on both streams and the exit code |

The last two are there because `d8check` is a **static** classifier: it proves every `.php` is
reachable from a gate, not that one ever ran. A broken workload test passes it.

### On Linux

`tests/linux.sh` is the same fixture gate, run on the host the binary is **for** -- inside a
container that has a php 8.5 of its own, so each fixture is compared with php on that host and
not with a recording made on another one. That is not ceremony: a Linux `PHP_OS` is `"Linux"` and
a macOS one is `"Darwin"`, and a cross-host comparison would grade that as a failure and hide the
ones that matter.

```sh
mc build src --config src/mc-php.linux-aarch64.toml
sh tests/linux.sh aarch64          # docker, and nothing else
sh tests/linux.sh x86_64
```

It is what the CI Linux legs and the release's grading job run. On a macOS host with a Linux VM,
run it inside the VM against the same path -- the repository is mounted there:

```sh
limactl shell mc-k7 -- sh "$PWD/tests/linux.sh" aarch64
```

### The grid

The `.phpt` grid is the number this project answers with and it is **not** a per-commit gate --
21395 tests, about forty minutes, and it needs php-src:

```sh
git clone --depth 1 --branch php-8.5.10 https://github.com/php/php-src php-src
sh tests/grid.sh build/mc-php build/grid all
```

---

## The numbers

Measured **2026-09-23**, on macOS 26 / arm64, PHP 8.5.10 (Homebrew, NTS), mc 1.1.0, php-src
at tag `php-8.5.10`. Every number here was re-measured on this tree; none is quoted from
`probes/t10`.

| the `.phpt` grid | green | of | php-fail |
|---|---|---|---|
| the whole corpus | **1705** | 21049 | 346 |
| `Zend/tests` | 756 | 5306 | 6 |
| `tests/lang` | 104 | 293 | 1 |
| `ext/standard/tests/strings` | 263 | 734 | 0 |

**The corpus row carries a band and the three directory rows do not.** Runs over the whole corpus
have given 1692 / 21018, 1704 / 21050, 1693 / 21018 and 1705 / 21049, and the difference is php's
own: every test that changed outcome was `php-fail` in one of the runs -- php itself did not
produce an answer, so the pair could not be graded. Between the last two, which are the SAME tree
twice, **0 tests stopped being green and 12 started**, and all 12 were `php-fail` in the other
run; every one is a `dir/` or `file/` test. The three directory rows came out identical on all of
them, down to their `wrong`/`refused`/`skip` columns, and across the hosts branch they are
identical **test for test**: all fifteen of their five sets `cmp` equal against the pre-branch
compiler. **A block worth fewer than a few dozen tests should be read on the directories, never
on the corpus.**

That band is measured, not assumed, and the measurement is worth stating because it is what makes
a one-test change readable at all. Running only the **1271** corpus tests that mention
`DIRECTORY_SEPARATOR`, `PATH_SEPARATOR`, `PHP_OS`, `setlocale` or `flush()` under the pre-branch
compiler and under this one, exactly **one** test changed its answer:
`ext/standard/tests/directory/directory_constants.phpt`, `wrong` -> **`green`** -- the test that
asserts those two constants and nothing else. Every other difference was a test entering or
leaving `php-fail`, and the control says why: with the **same** binary, changing only the job
count from 12 to 8 moves two of them, and the seven that moved between the two compilers are
`php-fail` under **both** when run serially.

| the gates, macOS arm64 | |
|---|---|
| fixtures | **89 / 89** agree with `php` |
| refusals | **6 / 6** refused by name, exit 3 |
| `lencheck` | 529 literal lengths, 0 wrong (514 before; `ph_pre`'s pairs are covered since the hosts branch, which is the gate the two shadowed constants needed) |
| `aritycheck` | 272 library rows, 0 wrong (273 before; the duplicate `flush` row is gone) |
| `d8check` | 102 `.php`, every one in a regime |
| peak scratch disk, full grid | **3836 KiB** -- bounded by the job count, not the corpus |

The same gate, on the hosts the other two archives are for -- `tests/linux.sh`, inside
`php:8.5-alpine`, against PHP 8.5.10 on that host, measured in a Lima VM (Ubuntu 26.04,
kernel 7.0.0-30, aarch64):

| the gates, Linux | fixtures | refusals |
|---|---|---|
| linux/aarch64 | **89 / 89** | **6 / 6** |
| linux/x86_64 | **89 / 89** | **6 / 6** |

x86_64 ran under qemu emulation on this host, so it is a correctness measurement and not a
timing one. Both were run natively by CI's own legs.

Against `php` on a real workload (`tests/bench/`, seven interleaved repetitions, recorded in
`tests/bench/results/`): mc-php wins the whole program **7.13x** on `main.php` and **1.45x** on
`heavy.php`, because php pays about 38 ms of start-up -- and **loses the work**, 10x on the first
and 25x on the second. `docs/plan.md` D7 names the cause: every value is arena-allocated and
never freed, an array copies eagerly, a string is immutable.

---

## The layout

```
mc.toml              the mc project:  mc build -> build/mc-php
src/*.mc             the compiler -- one mc Tier 3 module, 17 files
src/mc-php*.mc       one entry per host, and src/mc-php.<target>.toml beside each
lib/php_rt.mc        the runtime, #embed'ed into the compiler and pushed into every program
lib/rt_host_*.mc     the runtime's system layer, one file per host, pushed ahead of it
tests/               the fixtures, the .phpt grid driver, the gates and tests/linux.sh
examples/            empty until the extension road can build one
docs/                the plan, the decisions, the mcphp.toml schema
probes/              the measurement record, T0..T10 -- FROZEN, never edited
php-src/             php's own source, cloned, not committed
```

[docs/layout.md](docs/layout.md) has a line for each `src/` and `lib/` file and the one rule about
`probes/`.

`src/` and `lib/` were carved out of `probes/t10/`, which keeps its own copies so it still
reproduces the number it published. `tests/carve.sh` proved the carve moved nothing by building
both and comparing the two binaries byte for byte; its own header said it dies with the first
commit that changes what the compiler does, and the host layer is that commit, so it is deleted.

---

## Where the design is written down

| | |
|---|---|
| [docs/plan.md](docs/plan.md) | **read this first.** The plan, the decisions D1..D10, the test grid, and the open mc gaps |
| [docs/mcphp-toml.md](docs/mcphp-toml.md) | the `mcphp.toml` project file: the schema, decided, not implemented |
| [docs/layout.md](docs/layout.md) | what is in each directory |
| [probes/README.md](probes/README.md) | the index of the measurements, T0..T10, each with its own `RESULTS.md` |
| [CLAUDE.md](CLAUDE.md) | the operating rules |

mc-php is a **consumer** of mc's 1.0 frozen surface (`docs/reference/hooks.md` § 8 there). Nothing
here edits mc's `src/`; a gap in mc's surface is reported to mc with a reproducer, never worked
around. Two such gaps were found and both were closed in mc 1.1.0; their reproducers are kept
under `probes/gap-*`.

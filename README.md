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

**What works.** The compiler reads PHP 8.5 and produces a native macOS arm64 binary. Over
php-src's whole `.phpt` corpus -- 21395 tests -- it agrees with `php` on **1704**, byte for byte
on stdout and on the exit code. Classes, interfaces, traits, enums, closures, exceptions,
references, `match`, heredocs, late static binding, `printf`, a 273-row library, `ext/json`
written in mc: all of it is in, and each of it is measured rather than claimed.

**What does not work yet.**

| | |
|---|---|
| **the extension back end** | **not written.** This repository compiles a PHP *program* to a binary today. `get_module()` and the module entry are proven by hand outside it (`probes/t1`..`t3`) and are the next step. |
| `mcphp.toml` | the project file is **designed and documented, not implemented** -- see [docs/mcphp-toml.md](docs/mcphp-toml.md). Today the compiler is driven as `mc-php --exe FILE.php -o BIN`. |
| hosts other than macOS arm64 | `lib/php_rt.mc` includes `<sys>`, mc's libSystem layer, so a program it writes is a macOS program. Nothing here has been run on Linux or Windows. |
| generators | `yield` is not built. 252 of the 13623 disagreeing tests use it; the decision and its cost are in `docs/plan.md` D6. |
| `eval` and reflection | refused **by design**, by name, with exit 3 -- `docs/plan.md` D1 and D6. A refusal is an answer, not a failure. |
| most of the corpus | 14470 tests still disagree and 1929 are refused by design. The number below is the whole claim; nothing here rounds it up. |

---

## Install

Every tagged version is a GitHub release carrying a built compiler and its checksum.

```sh
V=0.1.0
BASE=https://github.com/minicompiler/mc-php/releases/download/v$V
curl -fsSLO $BASE/mc-php-$V-macos-arm64.tar.gz
curl -fsSLO $BASE/mc-php-$V-macos-arm64.tar.gz.sha256
shasum -a 256 -c mc-php-$V-macos-arm64.tar.gz.sha256
tar -xzf mc-php-$V-macos-arm64.tar.gz
sudo mv mc-php-$V-macos-arm64/mc-php /usr/local/bin/
```

Verify the checksum before unpacking it, not after: the line above fails loudly if the archive is
not the one that was built.

The runtime is inside the binary, so there is nothing to install beside it. One archive, one
architecture: **macOS on arm64**. The reason is not the compiler but what it emits --
`lib/php_rt.mc` includes mc's libSystem layer, so a program mc-php compiles is a macOS program,
and a Linux build of the compiler would only produce binaries that machine cannot run. When the
extension back end lands that stops being true, because a `.so` and a `.dll` are already proven,
and the archive list grows with it.

To build it yourself instead, read [Build](#build) below.

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
at tag `php-8.5.10`. The Linux and Windows link lines are the owner's measurements, recorded here;
no leg of this repository has run on either host yet.

---

## Build

```sh
mc build                      # -> build/mc-php
build/mc-php --exe hello.php -o hello && ./hello
```

`mc.toml` is the project file and there is no makefile: the same rule the compiler is being built
to offer, applied to itself.

### One thing about mc's library tree

`build/mc-php` is a **different binary from `mc`**, and it is itself a compiler: when it compiles
a `.php` it pushes `lib/php_rt.mc`, whose first line is `#include <sys>` -- mc's libSystem layer.
Since mc's M52 that is a *library* name, resolved out of a **tree**, not out of the compiler's
own blob. `mc` finds its tree beside `mc`; `mc-php` needs one it can reach.

If you installed mc with `mc install`, `$HOME/.mc/libs/mc/v<version>/` is that tree and there is
nothing to do. If you just untarred a release, put the `lib/mc` it carries there:

```sh
mkdir -p ~/.mc/libs
cp -R /path/to/mc-1.1.0-macos-arm64/lib/mc ~/.mc/libs/mc
```

Copying it beside the binary instead (`cp -R .../lib build/lib`) works too, for a binary that
stays put -- but `tests/fixtures.sh` grades a **snapshot** of the compiler in a temporary
directory, and a snapshot has no tree beside it. The `$HOME` root is the one that survives being
copied, which is why it is the one `mc install` writes and the one CI installs.

Without it the compiler builds fine and then refuses every program with
`#include <sys>: not in this compiler and mc 1.1.0's library tree was not found: run mc install`,
which is mc telling you exactly this.

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

The `.phpt` grid is the number this project answers with and it is **not** a per-commit gate --
21395 tests, about forty minutes, and it needs php-src:

```sh
git clone --depth 1 --branch php-8.5.10 https://github.com/php/php-src php-src
sh tests/grid.sh build/mc-php build/grid all
```

---

## The numbers

Measured **2026-09-22/23**, on macOS 26 / arm64, PHP 8.5.10 (Homebrew, NTS), mc 1.1.0, php-src
at tag `php-8.5.10`. Every number here was re-measured on this tree; none is quoted from
`probes/t10`.

| the `.phpt` grid | green | of | php-fail |
|---|---|---|---|
| the whole corpus | **1704** | 21050 | 345 |
| `Zend/tests` | 756 | 5306 | 6 |
| `tests/lang` | 104 | 293 | 1 |
| `ext/standard/tests/strings` | 263 | 734 | 0 |

**The corpus row carries a band and the three directory rows do not.** The same binary run twice
over the whole corpus gave 1692 / 21018 and 1704 / 21050, and the difference is php's own: of the
33 tests that changed outcome, all 33 were `php-fail` in one of the two runs -- php itself did
not produce an answer, so the pair could not be graded. Nothing regressed in either direction
(the `refused` and `skip` sets are identical to the test, and not one test that was green stopped
being green). The three directory rows came out identical on both runs, down to their
`wrong`/`refused`/`skip` columns. **A block worth fewer than a few dozen tests should be read on
the directories, never on the corpus.**

| the gates | |
|---|---|
| fixtures | **89 / 89** agree with `php` |
| refusals | **6 / 6** refused by name, exit 3 |
| `lencheck` | 514 literal lengths, 0 wrong |
| `aritycheck` | 273 library rows, 0 wrong |
| `d8check` | 102 `.php`, every one in a regime |
| peak scratch disk, full grid | **3836 KiB** -- bounded by the job count, not the corpus (identical on both runs of 21395 tests) |

Against `php` on a real workload (`tests/bench/`, seven interleaved repetitions, recorded in
`tests/bench/results/`): mc-php wins the whole program **7.13x** on `main.php` and **1.45x** on
`heavy.php`, because php pays about 38 ms of start-up -- and **loses the work**, 10x on the first
and 25x on the second. `docs/plan.md` D7 names the cause: every value is arena-allocated and
never freed, an array copies eagerly, a string is immutable.

---

## The layout

```
mc.toml              the mc project:  mc build -> build/mc-php
src/*.mc             the compiler -- one mc Tier 3 module, 15 files
lib/php_rt.mc        the runtime, #embed'ed into the compiler and pushed into every program
tests/               the fixtures, the .phpt grid driver and the gates
examples/            empty until the extension road can build one
docs/                the plan, the decisions, the mcphp.toml schema
probes/              the measurement record, T0..T10 -- FROZEN, never edited
php-src/             php's own source, cloned, not committed
```

[docs/layout.md](docs/layout.md) has a line for each `src/` file and the one rule about `probes/`.

`src/` and `lib/` were carved out of `probes/t10/`, which keeps its own copies so it still
reproduces the number it published. `tests/carve.sh` proves the carve moved nothing, by building
both and comparing the two binaries byte for byte.

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

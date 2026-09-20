# The review backlog

GitHub's Copilot reviewer runs on every pull request here (automatically, when the PR is marked
ready for review) and it left **59 inline findings across #1..#7** that nothing acted on: the merge
watches filtered its checks out and nobody read the annotations. They are collected here, with the
verbatim provenance in `docs/copilot-raw.txt` (PR, file, line), grouped by what they cost. Work
them in this order; strike a line only with the measurement that closes it.

The three `minicompiler/mc` pull requests of the same days (#99, #100, #101) carry **no** findings:
the reviewer errored on all three ("Copilot encountered an error and was unable to review").

## What is NOT in question

The grid. `probes/t0/phpt-run.py` runs the candidate binary and compares stdout AND the exit code,
and T0 cross-checked it against php-src's own `run-tests.php` (`strings` exact, `Zend/tests` within
8 passes / 5 skips). `green 1450` stands. What the findings below corrupt is the ANALYSIS -- the
wrong-reason table, the arena count, the fixture gate, the benchmarks -- and those numbers have
been quoted in every report since T5.

## 1. The measurements that lie (first: they choose what everything else works on)

- `why.py` / `whytable.py` label a source `(compiled; output differs)` **without ever running the
  binary** (#6 `probes/t7/why.py:36`). Every "output differs" count since T5 really means
  "compiled".
- `diffgroup.py` compares stdout only, while the grid counts an exit-code mismatch as `wrong`
  (#6/#7 `diffgroup.py:82`). Matching output with a different exit code is grouped as agreeing.
- `arena.py` turns every exception -- compile failure, timeout, anything -- into `None` and still
  divides by `len(files)` (#6/#7 `arena.py:31`). "11 of 1396 exhaust the arena" counts failures it
  never saw.
- `fixtures.sh` merges the two streams with `2>&1`, and command substitution strips trailing
  newlines (#7 `fixtures.sh:22`). "46/46 byte-for-byte on both streams" is weaker than it reads.
- `bench/bench.sh` in t7 and t8 builds and runs **t6's** compiler, runtime and fixture
  (#6/#7 `bench/bench.sh:23`): the benchmark cannot see the work it claims to measure.
- `run.sh` reads `T6_JOBS` in t7 and t8 (#6/#7 `run.sh:32`, `:33`), so the documented knob is dead.
- `why.py` writes `<test>.why.php` beside the input and deletes it in `finally` (#4 `why.py:28`):
  it overwrites a sibling that already exists.

## 2. Language semantics that are wrong (a program can observe every one)

- **`&&` and `||` do not short-circuit** (#5 `php.mc:2202`): both operands are lowered and the RHS
  always runs.
- **Parameters are not by value** (#5 `php.mc:2968`, `:4498`): a `mixed`/untyped parameter gets the
  caller's zval, so `function f($x) { $x[] = 2; }` mutates the caller's array.
- **`finally` is skipped by a `return`** in the try or catch body (#5 `php.mc:3935`).
- **A pending exception does not stop the statement**: the check is appended after the whole
  statement, so a throwing call in a condition still runs the branch (#5 `php.mc:3101`, `:3098`),
  and a prologue continues into the body after `php_argcount()` sets `ph_exc` (#5 `php.mc:4850`,
  `:5084`).
- **Visibility is not enforced**: a failed check records an exception and still returns the
  property bucket (#5 `php_rt.txt:3438`, `:3453`, `:3494`); static properties get no caller scope
  (#5 `php.mc:2635`); static methods are never checked at all (#5 `php_rt.txt:3555`).
- **Global functions are not hoisted** (#4 `php.mc:1760`, #5 `php.mc:2921`): `f(); function f(){}`
  is a missing-function error, and so is any call to a function declared later.
- **Typed method parameters are bound as `PT_MIXED`** with no conversion and no check
  (#5 `php.mc:4834`, `:4874`, `:5062`).
- **`?->` is parsed and not honoured** (#5 `php.mc:1695`, `:4935`): it dispatches like `->`.
- **`mixed` is refused** although D4 defines it as a zval-backed PHP type (#5 `php.mc:1311`).
- `2 ** -1` answers 1, not 0.5 (#4 `php.mc:1251`).
- `array_values` copies the zval header only, so a nested array still aliases (#5 `php_rt.txt:1942`).
- `array_push($a, 1, null)` drops the explicit null (#5 `php_rt.txt:4640`).
- `spl_object_hash()` returns an integer id (#5 `php.mc:5217`).
- Runtime-thrown throwables carry the default `file`/`line` (#5 `php_rt.txt:4015`).
- `php_die` exits without flushing: output buffered before a fatal is lost (#4 `php_rt.txt:23`).
- `func_num_args`'s counter is capped at 10 while 12 parameters are accepted (#7 `php.mc:2544`,
  `:6727`, `:6765`).
- `<?=` is accepted and emits nothing (#4 `php.mc:2088`).
- `function_exists` always answers false (#4 `php.mc:1756`).
- A global-scope variable of the same name makes a parameter look like a D4 retype
  (#4 `php.mc:2413`).
- `implode(1, ["a"])` passes the integer separator as a string handle (#4 `php.mc:1661`).
- `sprintf()`/`printf()` with no arguments reads an argument that is not there (#4 `php.mc:1428`).
- `ph_dq_read` is unreachable for the core lexer's string tokens (#4 `php.mc:440`).

## 3. Process

- **D8 covers fixtures, and the owner's text says so** ("fixtures, any part of the runtime or
  standard library written in PHP, examples"). The `.php` under `probes/*/g` and `probes/*/r` carry
  no PHPUnit test in either world and no bench row (#4 `RESULTS.md:289`). Either they carry them,
  or the plan states why a `.phpt`-shaped fixture is exempt -- a probe cannot waive the rule for
  itself.
- A merge watch must not filter the reviewer's checks, and a pull request is not merged before its
  findings are read.

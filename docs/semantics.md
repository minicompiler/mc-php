# C semantics -- where a compiled program is not php

mc-php compiles php SOURCE, and by default the program it writes behaves the way C behaves
where C and php part ways. The goal is C's cost: a read is a read, and an addition is an addition.
Everything a program does when it stays inside its arrays and strings, and inside the range of
an int, is php's answer. The differences are the cases below, and each one can be put back.

**Warning: an out-of-range read is undefined behaviour, and a memory-safety risk.** With C's
rules a string offset or a packed array element read outside its range reads whatever memory
lies there, exactly as `s[i]` does in C. Inside an extension, that memory belongs to the php
process: a wrong index can read another request's data or crash php. Build with
`semantics = "c-debug"` to find such a read (it stops the program and names the line), and
use `semantics = "php"` for code that must not trust its indices.

## Choosing the semantics

| value | what it means |
|---|---|
| `c` | **the default.** The differences below apply. |
| `c-debug` | C's rules, and every read they leave unchecked is checked again: outside the range the program stops with `mc-php: out-of-range read: offset N, length L (FILE:LINE)` on stderr and exit code 134. |
| `php` | php's own rules everywhere this page names a difference. The phpt grid runs in this mode. |

The first of these that is set decides:

1. A line comment in a php source: `// mc-php: semantics=php`. It is a comment, so php itself
   runs the file unchanged. Only a real line comment counts: the same bytes inside a string, a
   heredoc, a nowdoc or a `/* */` comment are text and change nothing. A file that says what it
   needs is not overridden by the run: `tests/g` uses the comment for the six fixtures that read
   out of range on purpose, and they keep php's rules even under `MCPHP_SEMANTICS=c`.
2. `MCPHP_SEMANTICS=php` (or `c`, `c-debug`) in the COMPILER's environment. mc on Windows
   reads no environment, so on a Windows host use one of the other two.
3. The project file, `mcphp.toml`: `[php]` `semantics = "php"` ([mcphp-toml.md](mcphp-toml.md)).

A value other than these three is a compile error, so a misspelt `"php"` does not quietly
give C's rules. The choice is made once for the whole compilation, not per function.

## The differences

### 1. An int that overflows in `+`, `-` or `*`

| | |
|---|---|
| php | the result becomes a float (`PHP_INT_MAX + 1` is `float(9.2233720368547758E+18)`) |
| mc-php, `c` / `c-debug` | the result wraps, two's complement, as C's does: `PHP_INT_MAX + 1` is `PHP_INT_MIN`. Nothing is thrown. Unary minus wraps too: `-PHP_INT_MIN` is `PHP_INT_MIN`. |
| mc-php, `php` | on a packed array's element (and on what such an operation answered in the same expression), php's overflow test, and where php would make a float the named `ArithmeticError`, because a native int cannot hold a float |

**Plain int arithmetic wraps in `php` mode too.** An int held in an ordinary variable has
wrapped since before this page existed, where php makes a float. That is a known gap in `php`
mode, recorded in [plan.md](plan.md) (§ 7, "native int arithmetic WRAPS on overflow"). It is
not a C-mode choice.

**What still throws in every mode:** the cases where C itself traps are not made undefined.

- A division or a modulo by zero is php's `DivisionByZeroError`: `intdiv($a, 0)`, `$a % 0`.
- `intdiv(PHP_INT_MIN, -1)` is php's `ArithmeticError`.

### 2. A string offset read outside the string

`$s[$i]`, `ord($s[$i])` and `$s[$i] === 'c'` with `$i < 0` or `$i >= strlen($s)`:

| | |
|---|---|
| php | `Warning: Uninitialized string offset N`, and the value is `""` (so `ord` is `0`) |
| mc-php, `c` | **undefined behaviour**: the byte at that address is read, with no warning |
| mc-php, `c-debug` | the program stops: `mc-php: out-of-range read: offset N, length L (FILE:LINE)`, exit 134 |
| mc-php, `php` | php's warning and `""` |

A **negative offset written as a literal**, `$s[-1]`, is php's count-from-the-end in every
mode: it is not a read outside the string, and the compiler can see it. A negative offset held in
a variable is a read outside the string under C's rules.

`$s[$i] ?? $d` is php's quiet read in every mode: absent, the default is taken. Use it where an
index may be out of range.

### 3. A packed array element read by an int key outside the array

A packed array is an int array the compiler proved is a native buffer
([plan.md](plan.md), the packed int array). `$a[$k]` with `$k < 0` or `$k >= count($a)`:

| | |
|---|---|
| php | `Warning: Undefined array key K`, and the value is `null` |
| mc-php, `c` | **undefined behaviour**: the eight bytes at that address are read, as an int, with no warning |
| mc-php, `c-debug` | the program stops: `mc-php: out-of-range read: offset K, length N (FILE:LINE)`, exit 134 |
| mc-php, `php` | php's warning and `null` |

Under C's rules an element read is never php's `null`: it is always an int.

**A store outside the range still makes the array php's hash**, as it does under php's rules.
From then on a read is the hash's own lookup and not the unchecked one: a key the hash has
answers its value in every mode. Under C's rules the price of this is one test per read, the
packed-or-hashed state. A key the hash does NOT have is a read outside the array:

- `c` answers php's `null`, with no warning;
- `c-debug` stops the program, naming the line;
- `php` gives php's warning and `null`.

These are unchanged in every mode:

- A **store** outside the range is php's own: `$a[] = v` and `$a[count($a)] = v` append, and
  any other key makes the array php's hash (above).
- `$a[$k] ?? $d` is php's quiet read.

## What is NOT different

Strings are values in every mode. A string that has one owner may be written or grown in place
(`$s .= x`, `$s[$i] = c`), but no two names ever share a buffer that one of them writes: no
string is a mutable buffer two variables see.

Everything not named above is php's answer in every mode, and the fixtures are graded against
php itself (`tests/fixtures.sh`). `tests/c/` holds the recordings of C's answers: wrapping,
in-range reads, and the `c-debug` trap.

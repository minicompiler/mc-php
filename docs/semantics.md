# mc-php behaves like C -- every difference from php

mc-php compiles php SOURCE, and the program it writes behaves the way C behaves where C and php
part ways. That is not a mode. There is no switch that gives php's rules back. The goal is C's
cost: a read is a read, and an addition is an addition.

Everything a program does while it stays inside its strings and arrays, and inside the range of
an int, is php's answer, and the fixtures are graded against php itself (`tests/fixtures.sh`).
This page lists every case where it is not.

**Warning: a read outside a string or an array is undefined behaviour, and a memory-safety
risk.** It reads whatever memory lies there, exactly as `s[i]` does in C. Inside an extension
that memory belongs to the php process: a wrong index can read another request's data or crash
php. Build with `checked_reads` (below) to find such a read.

## `checked_reads`: the reads checked again, as a trap

```toml
[php]
checked_reads = true
```

This goes in the project file ([mcphp-toml.md](mcphp-toml.md)). Every read this page calls
unchecked is then checked again. Outside the range the program stops, and stderr says

```
mc-php: out-of-range read: offset N, length L (FILE:LINE)
```

and the exit code is 134. The default is `false`. The value is a TOML boolean: anything else is
a compile error at its own position in the file. It changes no answer inside the range.
`examples/decimal` measures it at the cost of php's own checks (its README).

## The differences

### 1. An int that overflows

| | |
|---|---|
| php | the result becomes a float (`PHP_INT_MAX + 1` is `float(9.2233720368547758E+18)`) |
| mc-php | `+`, `-`, `*`, unary `-` and `**` with a non-negative literal exponent wrap, two's complement, as C's do: `PHP_INT_MAX + 1` is `PHP_INT_MIN`, and `-PHP_INT_MIN` is `PHP_INT_MIN`. Nothing is thrown. |

`$a ** $b` with an exponent that is not a literal keeps php's rule, a float when it overflows.
The reason is that the same expression is a float whenever `$b` is negative, so it is php's
number either way.

**What still throws, as C traps:**

- A division or a modulo by zero is php's `DivisionByZeroError`: `intdiv($a, 0)`, `$a % 0`.
- `intdiv(PHP_INT_MIN, -1)` is php's `ArithmeticError`.

### 2. A string offset read outside the string

`$s[$i]`, `ord($s[$i])` and `$s[$i] === 'c'` with `$i < 0` or `$i >= strlen($s)`:

| | |
|---|---|
| php | `Warning: Uninitialized string offset N`, and the value is `""` (so `ord` is `0`) |
| mc-php | **undefined behaviour**: the byte at that address is read, with no warning |
| mc-php, `checked_reads` | the program stops: `mc-php: out-of-range read: ...`, exit 134 |

A **negative offset written as a literal**, `$s[-1]`, is php's count-from-the-end: the compiler
can see it, and it reads the last byte. Outside the string it gets php's warning. A negative
offset held in a variable is a read outside the string.

`$s[$i] ?? $d` is php's quiet read: absent, the default is taken. Use it where an index may be
out of range.

### 3. A packed array element read by an int key outside the array

A packed array is an int array the compiler proved is a native buffer ([plan.md](plan.md), the
packed int array). `$a[$k]` with `$k < 0` or `$k >= count($a)`:

| | |
|---|---|
| php | `Warning: Undefined array key K`, and the value is `null` |
| mc-php | **undefined behaviour**: the eight bytes at that address are read as an int, with no warning |
| mc-php, `checked_reads` | the program stops: `mc-php: out-of-range read: ...`, exit 134 |

An element read is always an int, never php's `null`.

**A store outside the range still makes the array php's hash**, as in php. `$a[] = v` and
`$a[count($a)] = v` append, and any other key turns the array into a hash under the same handle.

- From then on a read is the hash's own lookup, and a key the hash has answers its value. The
  price is one test per read, of whether the array is still packed.
- A key the hash does NOT have is a read outside the array. It answers php's `null` with no
  warning, and under `checked_reads` the program stops.

`$a[$k] ?? $d` is php's quiet read.

## What is NOT different

Strings are values. A string that has one owner may be written or grown in place (`$s .= x`,
`$s[$i] = c`), but no two names ever share a buffer that one of them writes.

The phpt grid runs php-src's own tests against the compiled program. Three of them differ from
php only because of § 2, and `tests/grid/expected-differences.txt` names them. The grid fails
on any other change (`tests/grid.sh`). `tests/c/` holds the recordings of what mc-php does where
php would differ: wrapping, in-range reads, a packed array that became a hash, and
`checked_reads`.

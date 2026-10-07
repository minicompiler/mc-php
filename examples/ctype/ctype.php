<?php
// ctype -- php-src's ext/ctype ported to PHP and compiled by mc-php.
//
//     mc-php build examples/ctype --config examples/ctype/mcphp.toml
//
// and build/ctype.so is what `php -d extension=...` loads. The eleven
// functions reproduce ext/ctype/ctype.c exactly, including the int-argument
// quirk, and are graded byte for byte against php's own ctype_* (check.php).
//
// Why cty_* and not ctype_*: ctype is COMPILED IN to the php this is graded on
// (it is not a loadable .so -- `php -n` still has it), and php refuses to
// redeclare an internal function. So the port publishes cty_* and check.php
// compares each cty_X against the built-in ctype_X in the same process -- the
// built-in ctype IS the reference, no twin needed.
//
// The per-byte predicate is the C library's is*(), exactly as ext/ctype/ctype.c
// delegates to <ctype.h>. The symbol isalnum() is EXPORTED by libSystem (and by
// glibc) and resolves from php's own process at load, like db's sqlite3_*
// (docs/php-extension.md) -- and the exported function is the same
// classification ctype.c inlines, so the module agrees with php's ctype on all
// 256 bytes, including 128..255, on whatever libc the host runs, with no
// hardcoded locale table. ctype.c indexes a rune table per byte where this
// calls isalnum() per byte; README.md (The bench) measures what that costs, and
// why the whole-string strspn() that would close the gap cannot be used yet.
//
// A leading underscore is module-private: the is*() declarations and the helper
// are never published, only the eleven cty_*.

#[Extern('c', name: 'isalnum')]  function _isalnum(int $c): int {}
#[Extern('c', name: 'isalpha')]  function _isalpha(int $c): int {}
#[Extern('c', name: 'iscntrl')]  function _iscntrl(int $c): int {}
#[Extern('c', name: 'isdigit')]  function _isdigit(int $c): int {}
#[Extern('c', name: 'isgraph')]  function _isgraph(int $c): int {}
#[Extern('c', name: 'islower')]  function _islower(int $c): int {}
#[Extern('c', name: 'isprint')]  function _isprint(int $c): int {}
#[Extern('c', name: 'ispunct')]  function _ispunct(int $c): int {}
#[Extern('c', name: 'isspace')]  function _isspace(int $c): int {}
#[Extern('c', name: 'isupper')]  function _isupper(int $c): int {}
#[Extern('c', name: 'isxdigit')] function _isxdigit(int $c): int {}

// which=0..10 selects the C predicate; $c is a byte 0..255.
function _ctype_is(int $which, int $c): int {
    if ($which === 0)  return _isalnum($c);
    if ($which === 1)  return _isalpha($c);
    if ($which === 2)  return _iscntrl($c);
    if ($which === 3)  return _isdigit($c);
    if ($which === 4)  return _isgraph($c);
    if ($which === 5)  return _islower($c);
    if ($which === 6)  return _isprint($c);
    if ($which === 7)  return _ispunct($c);
    if ($which === 8)  return _isspace($c);
    if ($which === 9)  return _isupper($c);
    return _isxdigit($c);
}

// The ctype.c algorithm, once. A string: non-empty AND every byte passes the
// predicate (the empty string is false). A non-string: ctype.c's fallback --
// an int in 0..255 is that byte, an int in -128..-1 is that byte + 256, an int
// > 255 is $allow_digits, an int < -128 is $allow_minus; anything that is not
// an int (float, bool, null, array) is false. $allow_digits / $allow_minus are
// the two per-function constants ctype.c passes.
function _ctype_chk(mixed $v, int $which, int $allow_digits, int $allow_minus): bool {
    if (is_string($v)) {
        $s = (string) $v;
        $n = strlen($s);
        if ($n === 0) {
            return false;
        }
        for ($i = 0; $i < $n; $i++) {
            if (_ctype_is($which, ord($s[$i])) === 0) {
                return false;
            }
        }
        return true;
    }
    if (is_int($v)) {
        $c = (int) $v;
        if ($c >= 0 && $c <= 255) {
            return _ctype_is($which, $c) !== 0;
        }
        if ($c >= -128 && $c < 0) {
            return _ctype_is($which, $c + 256) !== 0;
        }
        if ($c >= 0) {
            return $allow_digits !== 0;
        }
        return $allow_minus !== 0;
    }
    return false;
}

// The eleven published functions. The (which, allow_digits, allow_minus) triple
// of each is ext/ctype/ctype.c's ctype_impl() arguments, verbatim.
function cty_alnum(mixed $text): bool  { return _ctype_chk($text, 0, 1, 0); }
function cty_alpha(mixed $text): bool  { return _ctype_chk($text, 1, 0, 0); }
function cty_cntrl(mixed $text): bool  { return _ctype_chk($text, 2, 0, 0); }
function cty_digit(mixed $text): bool  { return _ctype_chk($text, 3, 1, 0); }
function cty_graph(mixed $text): bool  { return _ctype_chk($text, 4, 1, 1); }
function cty_lower(mixed $text): bool  { return _ctype_chk($text, 5, 0, 0); }
function cty_print(mixed $text): bool  { return _ctype_chk($text, 6, 1, 1); }
function cty_punct(mixed $text): bool  { return _ctype_chk($text, 7, 0, 0); }
function cty_space(mixed $text): bool  { return _ctype_chk($text, 8, 0, 0); }
function cty_upper(mixed $text): bool  { return _ctype_chk($text, 9, 0, 0); }
function cty_xdigit(mixed $text): bool { return _ctype_chk($text, 10, 1, 0); }

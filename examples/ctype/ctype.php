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
// How it classifies, and why it is fast: ext/ctype.c is table-driven -- for an
// ASCII byte it indexes the C locale's rune table, not a function call. This
// port is table-driven the same way. At MINIT (this file's top level runs once,
// when the extension loads) it asks the C library's is*() -- the very functions
// ctype.c delegates to, resolved from php's own process like db's sqlite3_*
// (docs/php-extension.md) -- for every one of the 256 bytes, and keeps, per
// predicate, the SET of bytes that pass. A whole string is then one binary-safe
// strspn() over that set -- one pass, the shape ctype.c's loop has, with no
// per-byte call. Building the sets from the live libc is what makes the module
// agree with php's ctype on every byte, including 128..255, on whatever libc
// the host runs -- no hardcoded locale table.
//
// A leading underscore is module-private: the is*() declarations, the sets and
// the helper are never published, only the eleven cty_*.

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

// which=0..10 selects the C predicate; $c is a byte 0..255. Called 256 times
// per predicate at MINIT to build the sets, and once per int argument (the rare
// non-string path) -- never on the hot string path.
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

// The eleven SETs, built once at MINIT: _ctype_set($w) is the string of every
// byte that passes predicate $w. Kept as named scalar globals (one per
// predicate) so the hot path reads a plain string, not an array element.
function _ctype_set(int $which): string {
    $set = '';
    for ($b = 0; $b < 256; $b++) {
        if (_ctype_is($which, $b) !== 0) { $set .= chr($b); }
    }
    return $set;
}
$_cs_alnum  = _ctype_set(0);
$_cs_alpha  = _ctype_set(1);
$_cs_cntrl  = _ctype_set(2);
$_cs_digit  = _ctype_set(3);
$_cs_graph  = _ctype_set(4);
$_cs_lower  = _ctype_set(5);
$_cs_print  = _ctype_set(6);
$_cs_punct  = _ctype_set(7);
$_cs_space  = _ctype_set(8);
$_cs_upper  = _ctype_set(9);
$_cs_xdigit = _ctype_set(10);

// The ctype.c algorithm, once. A string: non-empty AND every byte is in the
// predicate's SET -- strspn() over the whole subject, one pass (the empty
// string is false). A non-string: ctype.c's fallback -- an int in 0..255 is
// that byte, an int in -128..-1 is that byte + 256, an int > 255 is
// $allow_digits, an int < -128 is $allow_minus; anything that is not an int
// (float, bool, null, array) is false. $allow_digits / $allow_minus are the
// two per-function constants ctype.c passes. $set is the predicate's set, read
// from the module-persistent global by the public function. It must read the
// global and run strspn() in the SAME frame as the published function, so each
// cty_X below inlines the string path rather than passing $set across a call:
// reading a module-persistent string and using it in place is leak-free, but
// handing one to another function as an argument is not. The non-string path
// needs no set, so it delegates here -- passing only the value and two ints.
function _ctype_nonstr(mixed $v, int $which, int $allow_digits, int $allow_minus): bool {
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

// The eleven published functions. A string is non-empty and strspn() over the
// predicate's SET covers the whole subject -- one pass, the set read in this
// frame. Anything else is _ctype_nonstr, whose (which, allow_digits,
// allow_minus) are ext/ctype/ctype.c's ctype_impl() arguments, verbatim.
function cty_alnum(mixed $text): bool {
    if (is_string($text)) { global $_cs_alnum; $s = (string) $text; $n = strlen($s); return $n !== 0 && strspn($s, $_cs_alnum) === $n; }
    return _ctype_nonstr($text, 0, 1, 0);
}
function cty_alpha(mixed $text): bool {
    if (is_string($text)) { global $_cs_alpha; $s = (string) $text; $n = strlen($s); return $n !== 0 && strspn($s, $_cs_alpha) === $n; }
    return _ctype_nonstr($text, 1, 0, 0);
}
function cty_cntrl(mixed $text): bool {
    if (is_string($text)) { global $_cs_cntrl; $s = (string) $text; $n = strlen($s); return $n !== 0 && strspn($s, $_cs_cntrl) === $n; }
    return _ctype_nonstr($text, 2, 0, 0);
}
function cty_digit(mixed $text): bool {
    if (is_string($text)) { global $_cs_digit; $s = (string) $text; $n = strlen($s); return $n !== 0 && strspn($s, $_cs_digit) === $n; }
    return _ctype_nonstr($text, 3, 1, 0);
}
function cty_graph(mixed $text): bool {
    if (is_string($text)) { global $_cs_graph; $s = (string) $text; $n = strlen($s); return $n !== 0 && strspn($s, $_cs_graph) === $n; }
    return _ctype_nonstr($text, 4, 1, 1);
}
function cty_lower(mixed $text): bool {
    if (is_string($text)) { global $_cs_lower; $s = (string) $text; $n = strlen($s); return $n !== 0 && strspn($s, $_cs_lower) === $n; }
    return _ctype_nonstr($text, 5, 0, 0);
}
function cty_print(mixed $text): bool {
    if (is_string($text)) { global $_cs_print; $s = (string) $text; $n = strlen($s); return $n !== 0 && strspn($s, $_cs_print) === $n; }
    return _ctype_nonstr($text, 6, 1, 1);
}
function cty_punct(mixed $text): bool {
    if (is_string($text)) { global $_cs_punct; $s = (string) $text; $n = strlen($s); return $n !== 0 && strspn($s, $_cs_punct) === $n; }
    return _ctype_nonstr($text, 7, 0, 0);
}
function cty_space(mixed $text): bool {
    if (is_string($text)) { global $_cs_space; $s = (string) $text; $n = strlen($s); return $n !== 0 && strspn($s, $_cs_space) === $n; }
    return _ctype_nonstr($text, 8, 0, 0);
}
function cty_upper(mixed $text): bool {
    if (is_string($text)) { global $_cs_upper; $s = (string) $text; $n = strlen($s); return $n !== 0 && strspn($s, $_cs_upper) === $n; }
    return _ctype_nonstr($text, 9, 0, 0);
}
function cty_xdigit(mixed $text): bool {
    if (is_string($text)) { global $_cs_xdigit; $s = (string) $text; $n = strlen($s); return $n !== 0 && strspn($s, $_cs_xdigit) === $n; }
    return _ctype_nonstr($text, 10, 1, 0);
}

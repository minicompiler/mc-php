<?php
// ctype -- php-src's ext/ctype ported to PHP and compiled by mc-php.
//
//     mc-php build examples/ctype --config examples/ctype/mcphp.toml
//
// and build/ctype.so is what `php -d extension=...` loads. The eleven
// functions reproduce ext/ctype/ctype.c, including the int-argument quirk, and
// are graded byte for byte against php's own ctype_* (check.php).
//
// Why cty_* and not ctype_*: ctype is COMPILED IN to the php this is graded on
// (php -n still has it), and php refuses to redeclare an internal function. So
// the port publishes cty_* and check.php compares each cty_X against the
// built-in ctype_X in the same process -- the built-in ctype IS the reference.
//
// How it is fast, and the locale it targets. ext/ctype.c is table-driven: for
// each byte it indexes a static classification table, never rebuilt. This port
// is table-driven the same way, and the table is the one thing mc-php can
// precompute: a STRING LITERAL set. strspn($s, "<literal>") lowers to a run
// test (php_spn_r, lo <= c <= hi) for a contiguous class, or to php_spn over a
// byte map built ONCE at compile time (src/builtin.mc, ph_bmap_of) for a
// non-contiguous one -- so there is no per-call charmask rebuild and no
// module-global read. The sets are the C locale's classification (the
// standard 7-bit ASCII classes; no byte 128..255 is in any class). The port
// therefore matches ctype under the C locale, which is what check.php and
// bench.php set (setlocale(LC_CTYPE, "C")) for both the module and the
// reference. A program that selects a different LC_CTYPE at run time would see
// ctype.so adapt its 128..255 answers and this port not -- the one documented
// difference (README.md).
//
// Each cty_X inlines its literal at the strspn call (a literal handed to a
// variable or across a call is no longer a literal to mc-php, and loses the
// precompute). An int argument becomes the one-byte string it denotes and runs
// the same scan: ctype.c's fallback is an int in 0..255 as that byte, -128..-1
// as that byte + 256, > 255 as allow_digits, < -128 as allow_minus; a non-int
// non-string is false. allow_digits / allow_minus are ctype_impl()'s two
// constants, inlined per function as the >255 and <-128 results.

function cty_alnum(mixed $t): bool {
    if (is_string($t)) { $n = strlen($t); return $n !== 0 && strspn($t, "\x30\x31\x32\x33\x34\x35\x36\x37\x38\x39\x41\x42\x43\x44\x45\x46\x47\x48\x49\x4a\x4b\x4c\x4d\x4e\x4f\x50\x51\x52\x53\x54\x55\x56\x57\x58\x59\x5a\x61\x62\x63\x64\x65\x66\x67\x68\x69\x6a\x6b\x6c\x6d\x6e\x6f\x70\x71\x72\x73\x74\x75\x76\x77\x78\x79\x7a") === $n; }
    if (is_int($t)) { $c = (int) $t; if ($c > 255) return true; if ($c < -128) return false; if ($c < 0) { $c = $c + 256; } return strspn(chr($c), "\x30\x31\x32\x33\x34\x35\x36\x37\x38\x39\x41\x42\x43\x44\x45\x46\x47\x48\x49\x4a\x4b\x4c\x4d\x4e\x4f\x50\x51\x52\x53\x54\x55\x56\x57\x58\x59\x5a\x61\x62\x63\x64\x65\x66\x67\x68\x69\x6a\x6b\x6c\x6d\x6e\x6f\x70\x71\x72\x73\x74\x75\x76\x77\x78\x79\x7a") === 1; }
    return false;
}
function cty_alpha(mixed $t): bool {
    if (is_string($t)) { $n = strlen($t); return $n !== 0 && strspn($t, "\x41\x42\x43\x44\x45\x46\x47\x48\x49\x4a\x4b\x4c\x4d\x4e\x4f\x50\x51\x52\x53\x54\x55\x56\x57\x58\x59\x5a\x61\x62\x63\x64\x65\x66\x67\x68\x69\x6a\x6b\x6c\x6d\x6e\x6f\x70\x71\x72\x73\x74\x75\x76\x77\x78\x79\x7a") === $n; }
    if (is_int($t)) { $c = (int) $t; if ($c > 255) return false; if ($c < -128) return false; if ($c < 0) { $c = $c + 256; } return strspn(chr($c), "\x41\x42\x43\x44\x45\x46\x47\x48\x49\x4a\x4b\x4c\x4d\x4e\x4f\x50\x51\x52\x53\x54\x55\x56\x57\x58\x59\x5a\x61\x62\x63\x64\x65\x66\x67\x68\x69\x6a\x6b\x6c\x6d\x6e\x6f\x70\x71\x72\x73\x74\x75\x76\x77\x78\x79\x7a") === 1; }
    return false;
}
function cty_cntrl(mixed $t): bool {
    if (is_string($t)) { $n = strlen($t); return $n !== 0 && strspn($t, "\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\x10\x11\x12\x13\x14\x15\x16\x17\x18\x19\x1a\x1b\x1c\x1d\x1e\x1f\x7f") === $n; }
    if (is_int($t)) { $c = (int) $t; if ($c > 255) return false; if ($c < -128) return false; if ($c < 0) { $c = $c + 256; } return strspn(chr($c), "\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\x10\x11\x12\x13\x14\x15\x16\x17\x18\x19\x1a\x1b\x1c\x1d\x1e\x1f\x7f") === 1; }
    return false;
}
function cty_digit(mixed $t): bool {
    if (is_string($t)) { $n = strlen($t); return $n !== 0 && strspn($t, "\x30\x31\x32\x33\x34\x35\x36\x37\x38\x39") === $n; }
    if (is_int($t)) { $c = (int) $t; if ($c > 255) return true; if ($c < -128) return false; if ($c < 0) { $c = $c + 256; } return strspn(chr($c), "\x30\x31\x32\x33\x34\x35\x36\x37\x38\x39") === 1; }
    return false;
}
function cty_graph(mixed $t): bool {
    if (is_string($t)) { $n = strlen($t); return $n !== 0 && strspn($t, "\x21\x22\x23\x24\x25\x26\x27\x28\x29\x2a\x2b\x2c\x2d\x2e\x2f\x30\x31\x32\x33\x34\x35\x36\x37\x38\x39\x3a\x3b\x3c\x3d\x3e\x3f\x40\x41\x42\x43\x44\x45\x46\x47\x48\x49\x4a\x4b\x4c\x4d\x4e\x4f\x50\x51\x52\x53\x54\x55\x56\x57\x58\x59\x5a\x5b\x5c\x5d\x5e\x5f\x60\x61\x62\x63\x64\x65\x66\x67\x68\x69\x6a\x6b\x6c\x6d\x6e\x6f\x70\x71\x72\x73\x74\x75\x76\x77\x78\x79\x7a\x7b\x7c\x7d\x7e") === $n; }
    if (is_int($t)) { $c = (int) $t; if ($c > 255) return true; if ($c < -128) return true; if ($c < 0) { $c = $c + 256; } return strspn(chr($c), "\x21\x22\x23\x24\x25\x26\x27\x28\x29\x2a\x2b\x2c\x2d\x2e\x2f\x30\x31\x32\x33\x34\x35\x36\x37\x38\x39\x3a\x3b\x3c\x3d\x3e\x3f\x40\x41\x42\x43\x44\x45\x46\x47\x48\x49\x4a\x4b\x4c\x4d\x4e\x4f\x50\x51\x52\x53\x54\x55\x56\x57\x58\x59\x5a\x5b\x5c\x5d\x5e\x5f\x60\x61\x62\x63\x64\x65\x66\x67\x68\x69\x6a\x6b\x6c\x6d\x6e\x6f\x70\x71\x72\x73\x74\x75\x76\x77\x78\x79\x7a\x7b\x7c\x7d\x7e") === 1; }
    return false;
}
function cty_lower(mixed $t): bool {
    if (is_string($t)) { $n = strlen($t); return $n !== 0 && strspn($t, "\x61\x62\x63\x64\x65\x66\x67\x68\x69\x6a\x6b\x6c\x6d\x6e\x6f\x70\x71\x72\x73\x74\x75\x76\x77\x78\x79\x7a") === $n; }
    if (is_int($t)) { $c = (int) $t; if ($c > 255) return false; if ($c < -128) return false; if ($c < 0) { $c = $c + 256; } return strspn(chr($c), "\x61\x62\x63\x64\x65\x66\x67\x68\x69\x6a\x6b\x6c\x6d\x6e\x6f\x70\x71\x72\x73\x74\x75\x76\x77\x78\x79\x7a") === 1; }
    return false;
}
function cty_print(mixed $t): bool {
    if (is_string($t)) { $n = strlen($t); return $n !== 0 && strspn($t, "\x20\x21\x22\x23\x24\x25\x26\x27\x28\x29\x2a\x2b\x2c\x2d\x2e\x2f\x30\x31\x32\x33\x34\x35\x36\x37\x38\x39\x3a\x3b\x3c\x3d\x3e\x3f\x40\x41\x42\x43\x44\x45\x46\x47\x48\x49\x4a\x4b\x4c\x4d\x4e\x4f\x50\x51\x52\x53\x54\x55\x56\x57\x58\x59\x5a\x5b\x5c\x5d\x5e\x5f\x60\x61\x62\x63\x64\x65\x66\x67\x68\x69\x6a\x6b\x6c\x6d\x6e\x6f\x70\x71\x72\x73\x74\x75\x76\x77\x78\x79\x7a\x7b\x7c\x7d\x7e") === $n; }
    if (is_int($t)) { $c = (int) $t; if ($c > 255) return true; if ($c < -128) return true; if ($c < 0) { $c = $c + 256; } return strspn(chr($c), "\x20\x21\x22\x23\x24\x25\x26\x27\x28\x29\x2a\x2b\x2c\x2d\x2e\x2f\x30\x31\x32\x33\x34\x35\x36\x37\x38\x39\x3a\x3b\x3c\x3d\x3e\x3f\x40\x41\x42\x43\x44\x45\x46\x47\x48\x49\x4a\x4b\x4c\x4d\x4e\x4f\x50\x51\x52\x53\x54\x55\x56\x57\x58\x59\x5a\x5b\x5c\x5d\x5e\x5f\x60\x61\x62\x63\x64\x65\x66\x67\x68\x69\x6a\x6b\x6c\x6d\x6e\x6f\x70\x71\x72\x73\x74\x75\x76\x77\x78\x79\x7a\x7b\x7c\x7d\x7e") === 1; }
    return false;
}
function cty_punct(mixed $t): bool {
    if (is_string($t)) { $n = strlen($t); return $n !== 0 && strspn($t, "\x21\x22\x23\x24\x25\x26\x27\x28\x29\x2a\x2b\x2c\x2d\x2e\x2f\x3a\x3b\x3c\x3d\x3e\x3f\x40\x5b\x5c\x5d\x5e\x5f\x60\x7b\x7c\x7d\x7e") === $n; }
    if (is_int($t)) { $c = (int) $t; if ($c > 255) return false; if ($c < -128) return false; if ($c < 0) { $c = $c + 256; } return strspn(chr($c), "\x21\x22\x23\x24\x25\x26\x27\x28\x29\x2a\x2b\x2c\x2d\x2e\x2f\x3a\x3b\x3c\x3d\x3e\x3f\x40\x5b\x5c\x5d\x5e\x5f\x60\x7b\x7c\x7d\x7e") === 1; }
    return false;
}
function cty_space(mixed $t): bool {
    if (is_string($t)) { $n = strlen($t); return $n !== 0 && strspn($t, "\x09\x0a\x0b\x0c\x0d\x20") === $n; }
    if (is_int($t)) { $c = (int) $t; if ($c > 255) return false; if ($c < -128) return false; if ($c < 0) { $c = $c + 256; } return strspn(chr($c), "\x09\x0a\x0b\x0c\x0d\x20") === 1; }
    return false;
}
function cty_upper(mixed $t): bool {
    if (is_string($t)) { $n = strlen($t); return $n !== 0 && strspn($t, "\x41\x42\x43\x44\x45\x46\x47\x48\x49\x4a\x4b\x4c\x4d\x4e\x4f\x50\x51\x52\x53\x54\x55\x56\x57\x58\x59\x5a") === $n; }
    if (is_int($t)) { $c = (int) $t; if ($c > 255) return false; if ($c < -128) return false; if ($c < 0) { $c = $c + 256; } return strspn(chr($c), "\x41\x42\x43\x44\x45\x46\x47\x48\x49\x4a\x4b\x4c\x4d\x4e\x4f\x50\x51\x52\x53\x54\x55\x56\x57\x58\x59\x5a") === 1; }
    return false;
}
function cty_xdigit(mixed $t): bool {
    if (is_string($t)) { $n = strlen($t); return $n !== 0 && strspn($t, "\x30\x31\x32\x33\x34\x35\x36\x37\x38\x39\x41\x42\x43\x44\x45\x46\x61\x62\x63\x64\x65\x66") === $n; }
    if (is_int($t)) { $c = (int) $t; if ($c > 255) return true; if ($c < -128) return false; if ($c < 0) { $c = $c + 256; } return strspn(chr($c), "\x30\x31\x32\x33\x34\x35\x36\x37\x38\x39\x41\x42\x43\x44\x45\x46\x61\x62\x63\x64\x65\x66") === 1; }
    return false;
}

<?php
// The predefined constants whose value is the HOST's, and the only gate on
// them. Four of these were wrong before the hosts branch and no gate saw it:
// DIRECTORY_SEPARATOR and PATH_SEPARATOR were registered twice, the first pair
// with the string LENGTH written as 0, and ph_pre_find returns the first match
// -- so both compiled to the empty string (issue #11); PHP_OS and
// PHP_OS_FAMILY said "Darwin" on every host.
//
// It is a differential fixture, so what it asserts is not a table written here
// but "mc-php says what php on THIS host says" -- which is what makes it grade
// the host SELECTION and not only the values. tests/linux.sh runs the same
// fixture on linux/aarch64 and linux/x86_64, where the first four answer
// Linux / Linux / "/" / ":".
//
// The names are written out rather than reached through constant(): a
// predefined constant is resolved at COMPILE time here (docs/plan.md D1), and
// the compile-time path is the one the bug was in.
//
// Two are deliberately not here, because they would assert something other
// than the host:
//
//   PHP_BINARY   php answers the absolute path of the running php binary
//                (/opt/homebrew/Cellar/php/8.5.10/bin/php on the host this was
//                written on) and mc-php answers "php". A compiled program has
//                no php binary, so there is nothing for the two to agree on.
//   PHP_VERSION  it is a constant in src/consts.mc and php's is php's, so the
//                fixture would fail on an 8.5.x bump for a reason that has
//                nothing to do with hosts.
echo "sep=", DIRECTORY_SEPARATOR, "\n";
echo "path=", PATH_SEPARATOR, "\n";
echo "os=", PHP_OS, "\n";
echo "family=", PHP_OS_FAMILY, "\n";
echo "sapi=", PHP_SAPI, "\n";
echo "extra=[", PHP_EXTRA_VERSION, "]\n";
echo "eol=[", PHP_EOL, "]\n";

// The lengths too: the bug was a wrong LENGTH beside a right literal, and a
// value that is one byte short still prints as something.
echo strlen(DIRECTORY_SEPARATOR), strlen(PATH_SEPARATOR), strlen(PHP_EOL), "\n";
echo strlen(PHP_OS), strlen(PHP_OS_FAMILY), "\n";

// setlocale's categories are the host's numbers too (BSD and the Microsoft CRT
// number from LC_ALL, glibc and musl from LC_CTYPE with LC_ALL last), and they
// reach libc unchanged -- so a wrong one asks the host about the wrong
// category. Naming a locale this runtime does not have is the host libc's
// answer and is NOT asserted here: macOS and glibc answer false and musl hands
// the name back (tests/g/58-sscanf.php covers that, differentially).
var_dump(setlocale(LC_ALL, "C"));
var_dump(setlocale(LC_ALL, 0));

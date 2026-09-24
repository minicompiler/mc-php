<?php
// dirname() and basename() are php's zend_dirname and php_basename, and three
// of their answers are the HOST's: what separates (a backslash too on
// Windows), what a root is written as ("\" on Windows whatever the path
// used), and whether "C:" is a drive (only on Windows). So this fixture asks
// the same questions everywhere and it is graded against the php of each
// host -- on macOS and Linux a backslash is an ordinary byte and "C:" is a
// file name, and the two worlds must agree on that too.
$paths = ["", "/", "//", "/a", "/a/", "a", "a/b", "a//b", "a/b/", "/a/b//c",
          ".", "..", "C:", "C:\\", "C:\\foo", "C:\\foo\\bar", "C:/foo/", "C:foo",
          "\\", "\\x", "a\\b", "x/y\\z"];
foreach ($paths as $p) {
    echo "[", $p, "] dirname [", dirname($p), "] basename [", basename($p), "]\n";
}

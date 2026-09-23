<?php
// docs/plan.md D10: a php string is BYTES and is never encoding-validated
$e = "\xc3\xa9";
var_dump(strlen($e));
var_dump($e);
var_dump(strlen("\x00\x01"));
echo 'it\'s a literal $x with \n in it', "\n";

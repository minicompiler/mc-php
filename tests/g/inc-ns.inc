<?php
// Required by 121-namespace-blocks.php from inside a braced block: a file
// declares its own namespace, whatever block the file requiring it is in.
namespace incns;
const WHO = "incns";
function tag(): string { return __FUNCTION__ . " " . WHO; }

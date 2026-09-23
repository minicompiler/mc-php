<?php
// D6: no reflection -- a binary carries no run-time type tables
$o = new stdClass;
var_dump(get_object_vars($o));

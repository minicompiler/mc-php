<?php
$c = getcwd();
var_dump(is_string($c) && strlen($c) > 0);
var_dump(chdir("/tmp"), basename(getcwd()));
var_dump(putenv("MCPHP_T9=1"), getenv("MCPHP_T9"));
var_dump(putenv("MCPHP_T9"), getenv("MCPHP_T9"));
var_dump(chdir("/no/such/dir/here"));

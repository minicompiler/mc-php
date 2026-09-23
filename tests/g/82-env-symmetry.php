<?php
// The harness must not be visible to the program: the wrapper's own scratch
// path was exported for mc-php's side and php ran with it in the environment.
var_dump(getenv("MCPHP_OUT"));
var_dump(getenv("MCPHP_BIN"));
var_dump(getenv("MCPHP_TMP"));

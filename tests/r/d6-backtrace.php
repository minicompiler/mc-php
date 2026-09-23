<?php
// D6: debug_backtrace needs the call stack shape at run time, which is the
// table D6 is about. func_get_args does NOT and was corrected back in.
function f() { return debug_backtrace(); }
var_dump(f());

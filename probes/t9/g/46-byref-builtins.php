<?php
var_dump(similar_text("World", "word", $p), $p);
var_dump(str_replace("a", "b", "banana", $c), $c);
var_dump(str_replace("x", "y", "banana", $d), $d);
try { str_decrement(""); } catch (ValueError $e) { echo $e->getMessage(), "\n"; }
var_dump(unserialize("bogus"));

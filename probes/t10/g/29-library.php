<?php
class Base { public $x = 5; }
class_alias('Base', 'Ali');
$o = new Ali;
var_dump($o->x, $o instanceof Base);
register_shutdown_function(function () { echo "shutdown ran\n"; });
$t = strtok("a,b;;c", ",;");
while ($t !== false) { echo "[$t]"; $t = strtok(",;"); }
echo "\n";
var_dump(strnatcmp("img12", "img10"), strnatcmp("img2", "img10"),
         strnatcasecmp("IMG2", "img10"), strnatcmp("a", "a"));
var_dump(addcslashes("foo[bar]", 'A..Z'), addcslashes("zoo['.']", 'z..A'),
         addcslashes("\n\t x", "\0..\37"));
echo "end\n";

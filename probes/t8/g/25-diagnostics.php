<?php
// php's diagnostic channel: the text, the file, the line and the order.
echo "start\n";
echo $undef;
echo "|\n";
$a = ['k' => 1];
echo $a['nope'];
echo $a[7];
echo "|\n";
$arr = [1, 2];
echo "as string: " . $arr . "\n";
echo "5 apples" + 1, "\n";
$f = 3.5;
$h = [];
$h[$f] = 'x';
$n = null;
echo $n[0], "|\n";
$i = 5;
echo $i[0], "|\n";
class C { public $a = 1; }
$o = new C;
echo $o->zz, "|\n";
echo $n->p, "|\n";
echo @$undef2, "|\n";
echo @$a['gone'], "|\n";
echo $a['gone'] ?? 'default', "\n";
echo "end\n";

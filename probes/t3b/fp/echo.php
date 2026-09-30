<?php
// probes/t3b under FrankenPHP: a worker's php context writes output
$f = function (int $i): string { echo "from worker $i\n"; return "r$i"; };
echo implode(",", t3b_run($f, 3, 2, 0)), "\n";

<?php
$x = 3;
$h = <<<EOT
a heredoc interpolates: {$GLOBALS["x"]}
EOT;
echo $h, "\n";

<?php
// A nowdoc's body is text, never code: `$GLOBALS` inside it is four words of
// prose, not the refused array (tests/r/d6-globals-heredoc.php is the
// heredoc, which interpolates). Heredocs of every opening form, and closing
// identifiers indented or followed by other code, end where php ends them.
$a = <<<'TXT'
the $GLOBALS array, $x and {$y} are not read here
TXT;
$b = <<<"EOT"
  a quoted heredoc
  EOT;
$v = "v";
$c = <<<EOT
a plain one, with $v, and EOT_ is not its end
EOT . "!";
echo $a, "\n", $b, "\n", $c, "\n";

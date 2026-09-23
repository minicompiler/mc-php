<?php
try { sprintf(); } catch (ArgumentCountError $e) { echo "ACE\n"; }
echo sprintf("%s-%d", "a", 5), "\n";

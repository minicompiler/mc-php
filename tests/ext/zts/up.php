<?php
// tests/frankenphp.sh: FrankenPHP is up when this answers. It calls nothing
// in the module, so no php thread has measured anything before the
// warm-up's first requests arrive together.
echo "up\n";

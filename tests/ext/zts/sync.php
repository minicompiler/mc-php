<?php
// tests/frankenphp.sh: native sync (threads step 4) under a threaded SAPI.
// Each request makes a mutex and an atomic starting at n, adds 1 to it under
// the mutex on this php thread and on a compiled thread of its own, and
// answers n|n+2|the larger handle index; `?hits` answers how many requests
// the atomic made at MINIT counted.
if (isset($_GET['hits'])) { echo zts_sync_hits(), "\n"; return; }
echo zts_sync((int) ($_GET['n'] ?? 0)), "\n";

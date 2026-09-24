<?php
// Drive php's built-in server through N requests and print every response,
// so a module's request lifecycle can be compared with the interpreted
// source's (tests/ext.sh step 10). php drives php here, and not the shell: a
// server started with proc_open is one proc_terminate away from stopped on
// every host, Windows included.
//
//     php requests.php ROUTER N [EXTENSION]
[, $router, $n] = $argv;
$ext = $argv[3] ?? '';
$s = stream_socket_server('tcp://127.0.0.1:0');
$name = stream_socket_get_name($s, false);
fclose($s);
$port = (int) substr($name, strrpos($name, ':') + 1);
$cmd = [PHP_BINARY];
if ($ext !== '') { array_push($cmd, '-d', "extension=$ext"); }
array_push($cmd, '-S', "127.0.0.1:$port", basename($router));
$null = DIRECTORY_SEPARATOR === '\\' ? 'NUL' : '/dev/null';
$p = proc_open($cmd, [0 => ['pipe', 'r'], 1 => ['file', $null, 'w'], 2 => ['file', $null, 'w']],
               $pipes, dirname($router), null, ['bypass_shell' => true]);
if (!is_resource($p)) { echo "cannot start php -S\n"; exit(1); }
$up = false;
for ($t = 0; $t < 200 && !$up; $t++) {
    $c = @fsockopen('127.0.0.1', $port, $errno, $errstr, 0.2);
    if ($c) { fclose($c); $up = true; } else { usleep(50000); }
}
$rc = 0;
if (!$up) { echo "php -S did not come up on port $port\n"; $rc = 1; }
for ($i = 0; $up && $i < (int) $n; $i++) {
    $body = @file_get_contents("http://127.0.0.1:$port/");
    if ($body === false) { echo "request ", $i + 1, " failed\n"; $rc = 1; break; }
    echo $body;
}
proc_terminate($p);
proc_close($p);
exit($rc);

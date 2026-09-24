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
$log = dirname($router) . '/php-S.log';

// A free port is found by binding one and letting it go, which another
// process may take before the server binds it: the server is started up to
// three times, on a new port each time, before this gives up.
function start(string $router, string $ext, string $log): array {
    $s = stream_socket_server('tcp://127.0.0.1:0');
    $name = stream_socket_get_name($s, false);
    fclose($s);
    $port = (int) substr($name, strrpos($name, ':') + 1);
    $cmd = [PHP_BINARY];
    if ($ext !== '') { array_push($cmd, '-d', "extension=$ext"); }
    array_push($cmd, '-S', "127.0.0.1:$port", basename($router));
    $p = proc_open($cmd, [0 => ['pipe', 'r'], 1 => ['file', $log, 'w'], 2 => ['file', $log, 'a']],
                   $pipes, dirname($router), null, ['bypass_shell' => true]);
    if (!is_resource($p)) { return [null, $port]; }
    // up to a minute: an emulated php (a Windows-on-ARM runner) starts slowly
    $t0 = microtime(true);
    while (microtime(true) - $t0 < 60) {
        $c = @fsockopen('127.0.0.1', $port, $errno, $errstr, 0.5);
        if ($c) { fclose($c); return [$p, $port]; }
        if (!proc_get_status($p)['running']) { break; }       // it died: the port was taken
        usleep(100000);
    }
    proc_terminate($p);
    proc_close($p);
    return [null, $port];
}

$p = null;
for ($try = 0; $try < 3 && !$p; $try++) { [$p, $port] = start($router, $ext, $log); }
if (!$p) {
    echo "php -S did not come up (three ports tried); its last log:\n", @file_get_contents($log);
    exit(1);
}
$rc = 0;
$ctx = stream_context_create(['http' => ['timeout' => 60]]);
for ($i = 0; $i < (int) $n; $i++) {
    $body = @file_get_contents("http://127.0.0.1:$port/", false, $ctx);
    if ($body === false) {
        echo "request ", $i + 1, " failed: ", error_get_last()['message'] ?? '(no message)', "\n";
        $rc = 1;
        break;
    }
    echo $body;
}
proc_terminate($p);
proc_close($p);
exit($rc);

<?php
// Step 6b self-test (docs/threads.md § Step 6b): a non-blocking TCP connect and
// read driven by the event loop. A blocking loopback listener on another thread
// accepts one connection and sends a reply; the main thread connects and reads
// through the loop (connect = a writable arm on kqueue/epoll, a ConnectEx on
// IOCP; read = the arm-and-go of step 5). No network: 127.0.0.1 only. Program
// road, no php engine on the fiber. Graded against 22-connect.out.

$lp = mcphp_tcp_listen(0);                 // (listen_fd << 32 | the ephemeral port)
$lfd = $lp >> 32;
$port = $lp & 0xffffffff;

// the peer: accept one connection and send a reply, on a thread of its own
$w = mcphp_thread_start(function (int $lfd): int {
    mcphp_tcp_accept_send($lfd, "hello socket");
    return 0;
}, $lfd);

$fd = mcphp_connect(0x7f000001, $port);    // suspends until the socket connects
$resp = mcphp_io_read($fd, 64);            // suspends until the reply is in
echo "socket connect+read: ", $resp, "\n";

mcphp_fd_close($fd);
mcphp_thread_join($w);
mcphp_tcp_close($lfd);
echo "done\n";

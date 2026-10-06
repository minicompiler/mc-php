// The C twin of mc-php's non-blocking connect + read (docs/threads.md § Step 6b,
// the gate). The same workload as tests/c/22-connect.php -- a blocking loopback
// listener on a thread, a non-blocking connect driven by raw kqueue (macOS) /
// epoll (Linux) with SO_ERROR checked on writable, and a read driven by the
// same reactor -- so the loop's socket semantics are validated independently
// and its output is byte for byte the .php's (tests/examples.sh compares them,
// and times both). mc-php's connect is lib/rt_host_*.mc; here the twin uses the
// raw reactor and a pthread.
#define _XOPEN_SOURCE 700
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#if defined(__APPLE__)
#include <sys/event.h>
#else
#include <sys/epoll.h>
#endif

static int evfd;

#if defined(__APPLE__)
static void arm_w(int fd) {
    struct kevent ke; EV_SET(&ke, fd, EVFILT_WRITE, EV_ADD | EV_ONESHOT, 0, 0, 0);
    kevent(evfd, &ke, 1, 0, 0, 0);
}
static void arm_r(int fd) {
    struct kevent ke; EV_SET(&ke, fd, EVFILT_READ, EV_ADD | EV_ONESHOT, 0, 0, 0);
    kevent(evfd, &ke, 1, 0, 0, 0);
}
static void wait1(void) {
    struct kevent el[1];
    kevent(evfd, 0, 0, el, 1, 0);
}
#else
static void arm_w(int fd) {
    struct epoll_event ee; ee.events = EPOLLOUT | EPOLLONESHOT; ee.data.fd = fd;
    if (epoll_ctl(evfd, EPOLL_CTL_ADD, fd, &ee) < 0) epoll_ctl(evfd, EPOLL_CTL_MOD, fd, &ee);
}
static void arm_r(int fd) {
    struct epoll_event ee; ee.events = EPOLLIN | EPOLLONESHOT; ee.data.fd = fd;
    if (epoll_ctl(evfd, EPOLL_CTL_ADD, fd, &ee) < 0) epoll_ctl(evfd, EPOLL_CTL_MOD, fd, &ee);
}
static void wait1(void) {
    struct epoll_event el[1];
    epoll_wait(evfd, el, 1, -1);
}
#endif

// the blocking loopback peer: accept one connection, send a reply, close it
static int listen_fd;
static void *peer(void *arg) {
    (void) arg;
    int c = accept(listen_fd, 0, 0);
    if (c >= 0) { (void)!write(c, "hello socket", 12); close(c); }
    return 0;
}

int main(void) {
#if defined(__APPLE__)
    evfd = kqueue();
#else
    evfd = epoll_create1(0);
#endif
    // a loopback listener on an ephemeral port
    listen_fd = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1; setsockopt(listen_fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    struct sockaddr_in sa; memset(&sa, 0, sizeof sa);
    sa.sin_family = AF_INET; sa.sin_addr.s_addr = htonl(0x7f000001); sa.sin_port = 0;
    bind(listen_fd, (struct sockaddr *) &sa, sizeof sa);
    listen(listen_fd, 16);
    socklen_t sl = sizeof sa; getsockname(listen_fd, (struct sockaddr *) &sa, &sl);
    int port = ntohs(sa.sin_port);

    pthread_t th; pthread_create(&th, 0, peer, 0);

    // a non-blocking connect driven by the reactor (writable, then SO_ERROR)
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    fcntl(fd, F_SETFL, O_NONBLOCK);
    struct sockaddr_in to; memset(&to, 0, sizeof to);
    to.sin_family = AF_INET; to.sin_addr.s_addr = htonl(0x7f000001); to.sin_port = htons(port);
    int r = connect(fd, (struct sockaddr *) &to, sizeof to);
    if (r != 0 && errno == EINPROGRESS) { arm_w(fd); wait1(); }
    int err = 0; socklen_t el = sizeof err; getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &el);

    // a read driven by the reactor
    arm_r(fd); wait1();
    char buf[64]; int nb = read(fd, buf, 64); if (nb < 0) nb = 0; buf[nb] = 0;
    printf("socket connect+read: %s\n", buf);

    close(fd);
    pthread_join(th, 0);
    close(listen_fd);
    printf("done\n");
    return 0;
}

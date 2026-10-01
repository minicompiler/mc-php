// The C twin of mc-php's event loop (docs/threads.md § Step 5, the gate).
// The same workload as tests/c/18-await.php -- a timer, a future completed and
// failed, fibers that await a timer, and a pipe read awaited on a fiber -- on
// raw kqueue (macOS) / epoll (Linux) and ucontext fibers, so the loop's
// semantics are validated independently and its output is byte for byte the
// .php's (tests/await.sh compares them, and times both). mc-php's own fibers
// are ph_ctx_swap (lib/rt_fiber_*.mc); here the twin uses ucontext.
#define _XOPEN_SOURCE 700       // macOS: the ucontext routines require it
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <ucontext.h>
#include <time.h>
#if defined(__APPLE__)
#include <sys/event.h>
#else
#include <sys/epoll.h>
#include <fcntl.h>
#endif

// --- a tiny future ---------------------------------------------------------
typedef struct Fut {
    int   state;            // 0 pending, 1 done, 2 failed
    long  ival;             // an int value
    char  sval[256];        // a string value
    int   is_str;
    char  err[256];         // a failure message
    long  deadline;         // a timer's monotonic deadline (ms), 0 = none
    int   fd, len;          // a pending read
    struct Fiber *waiter;   // the fiber awaiting this
    struct Fut *tnext;      // the sorted timer list
} Fut;

// --- a fiber ---------------------------------------------------------------
typedef struct Fiber {
    ucontext_t ctx;
    char      *stack;
    int        state;       // 0 new, 1 suspended, 3 done
    void     (*fn)(struct Fiber *);
    long       arg;
    Fut       *result;      // completed with the fiber's return
    long       ret;
    struct Fiber *rnext;    // ready queue
} Fiber;

static ucontext_t loop_ctx;
static Fiber *cur;
static Fiber *ready_h, *ready_t;
static Fut *timers;
static int npend;
static int evfd;

static long now_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1000 + t.tv_nsec / 1000000;
}

static void ready_push(Fiber *f) { f->rnext = 0; if (ready_t) ready_t->rnext = f; else ready_h = f; ready_t = f; }
static Fiber *ready_pop(void) { Fiber *f = ready_h; if (!f) return 0; ready_h = f->rnext; if (!ready_h) ready_t = 0; return f; }

static void fut_done_i(Fut *fut, long v) { fut->state = 1; fut->ival = v; if (fut->waiter) { ready_push(fut->waiter); fut->waiter = 0; } }
static void fut_done_s(Fut *fut, const char *s, int n) { fut->state = 1; fut->is_str = 1; memcpy(fut->sval, s, n); fut->sval[n] = 0; if (fut->waiter) { ready_push(fut->waiter); fut->waiter = 0; } }
static void fut_fail(Fut *fut, const char *e) { fut->state = 2; strcpy(fut->err, e); if (fut->waiter) { ready_push(fut->waiter); fut->waiter = 0; } }

static void timer_insert(Fut *fut) {
    Fut **p = &timers;
    while (*p && (*p)->deadline <= fut->deadline) p = &(*p)->tnext;
    fut->tnext = *p; *p = fut; npend++;
}

static Fut *mk_timer(long ms) {
    Fut *f = calloc(1, sizeof *f); f->fd = -1;
    f->deadline = now_ms() + ms; timer_insert(f); return f;
}

#if defined(__APPLE__)
static void ev_arm(int fd, Fut *ud) {
    struct kevent ke; EV_SET(&ke, fd, EVFILT_READ, EV_ADD | EV_ONESHOT, 0, 0, ud);
    kevent(evfd, &ke, 1, 0, 0, 0);
}
static int ev_wait(Fut **out, int max, int ms) {
    struct kevent el[64]; struct timespec ts, *tsp = 0;
    if (ms >= 0) { ts.tv_sec = ms / 1000; ts.tv_nsec = (ms % 1000) * 1000000; tsp = &ts; }
    int n = kevent(evfd, 0, 0, el, max < 64 ? max : 64, tsp);
    if (n < 0) n = 0;
    for (int i = 0; i < n; i++) out[i] = (Fut *) el[i].udata;
    return n;
}
#else
static void ev_arm(int fd, Fut *ud) {
    struct epoll_event ee; ee.events = EPOLLIN | EPOLLONESHOT; ee.data.ptr = ud;
    if (epoll_ctl(evfd, EPOLL_CTL_ADD, fd, &ee) < 0) epoll_ctl(evfd, EPOLL_CTL_MOD, fd, &ee);
}
static int ev_wait(Fut **out, int max, int ms) {
    struct epoll_event el[64];
    int n = epoll_wait(evfd, el, max < 64 ? max : 64, ms);
    if (n < 0) n = 0;
    for (int i = 0; i < n; i++) out[i] = (Fut *) el[i].data.ptr;
    return n;
}
#endif

static void drive(Fut *stop);

// await: on a fiber, park and swap to the loop; else nested-drive.
static void await_fut(Fut *fut) {
    if (fut->state == 0) {
        if (cur) { fut->waiter = cur; cur->state = 1; swapcontext(&cur->ctx, &loop_ctx); }
        else drive(fut);
    }
}

static void io_complete(Fut *fut) {
    char buf[256];
    int nb = read(fut->fd, buf, fut->len < 255 ? fut->len : 255);
    if (nb < 0) nb = 0;
    npend--;
    fut_done_s(fut, buf, nb);
}

static void timers_fire(void) {
    long t = now_ms();
    while (timers && timers->deadline <= t) { Fut *c = timers; timers = c->tnext; npend--; fut_done_i(c, 0); }
}

static void fiber_entry(void) {
    Fiber *f = cur;
    f->fn(f);
    f->result->state = 1;
    if (!f->result->is_str) f->result->ival = f->ret;   // a string result is set by fn
    f->state = 3;
    swapcontext(&f->ctx, &loop_ctx);
}

static void fib_resume(Fiber *f) {
    cur = f; f->state = 2;
    swapcontext(&loop_ctx, &f->ctx);
    cur = 0;
    if (f->state == 3) { free(f->stack); free(f); }
}

static void drive(Fut *stop) {
    Fut *evb[64];
    for (;;) {
        Fiber *f; while ((f = ready_pop())) fib_resume(f);
        if (stop) { if (stop->state != 0) return; }
        else if (!ready_h && !npend) return;
        if (ready_h) continue;
        long ms = -1;
        if (timers) { ms = timers->deadline - now_ms(); if (ms < 0) ms = 0; }
        if (ms < 0 && !npend) return;
        int n = ev_wait(evb, 64, (int) ms);
        timers_fire();
        for (int i = 0; i < n; i++) io_complete(evb[i]);
    }
}

static Fut *spawn(void (*fn)(Fiber *), long arg) {
    Fiber *f = calloc(1, sizeof *f);
    f->stack = malloc(1 << 17);
    getcontext(&f->ctx);
    f->ctx.uc_stack.ss_sp = f->stack;
    f->ctx.uc_stack.ss_size = 1 << 17;
    f->ctx.uc_link = 0;
    makecontext(&f->ctx, fiber_entry, 0);
    f->fn = fn; f->arg = arg;
    f->result = calloc(1, sizeof(Fut)); f->result->fd = -1;
    ready_push(f);
    return f->result;
}

// a fiber body: await a 5ms timer, return arg+1
static void work(Fiber *f) { Fut *t = mk_timer(5); await_fut(t); f->ret = f->arg + 1; }
// a fiber body: await a read on f->arg (an fd), return the bytes
static void reader(Fiber *f) {
    Fut *io = calloc(1, sizeof *io); io->fd = (int) f->arg; io->len = 64;
    ev_arm(io->fd, io); npend++;
    await_fut(io);
    f->result->is_str = 1; strcpy(f->result->sval, io->sval);
}

int main(void) {
#if defined(__APPLE__)
    evfd = kqueue();
#else
    evfd = epoll_create1(0);
#endif

    // a top-level timer await
    Fut *t0 = mk_timer(10); await_fut(t0);
    printf("timer done\n");

    // a future completed and failed
    Fut *fv = calloc(1, sizeof *fv); fv->fd = -1; fut_done_i(fv, 42);
    printf("future value: %ld\n", fv->ival);
    Fut *gf = calloc(1, sizeof *gf); gf->fd = -1; fut_fail(gf, "boom");
    printf("future fail caught: %s\n", gf->err);

    // fibers that await a timer
    Fut *a = spawn(work, 2), *b = spawn(work, 6), *c = spawn(work, 10);
    drive(0);
    printf("spawn results: %ld %ld %ld\n", a->ival, b->ival, c->ival);

    // a pipe read awaited on a fiber
    int p[2]; (void)!pipe(p);
#if !defined(__APPLE__)
    fcntl(p[0], F_SETFL, O_NONBLOCK);
#endif
    Fut *rd = spawn(reader, p[0]);
    (void)!write(p[1], "hello pipe", 10);
    drive(0);
    printf("pipe read: %s\n", rd->sval);
    close(p[0]); close(p[1]);

    printf("done\n");
    return 0;
}

/* examples/sync/c/sync.c -- the C twin of ../sync.php: the same bounded
 * producer/consumer workload, in C with pthreads and C11 atomics. A counting
 * semaphore and a wait group are built from a mutex and a condition variable
 * (POSIX unnamed semaphores are unavailable on macOS), so the shape matches
 * mc-php's, which builds its own on futex/__ulock/WaitOnAddress.
 *
 *     cc -O2 -pthread sync.c -o sync-c
 *
 * Prints the same line ../sync.php prints; tests/examples.sh checks the two
 * checksums match and times both. */
#include <stdio.h>
#include <stdint.h>
#include <stdatomic.h>
#include <pthread.h>

enum { PRODUCERS = 4, CONSUMERS = 4, ITEMS = 100000, CAP = 16, PERMITS = 2 };

/* a counting semaphore from a mutex and a condition variable */
typedef struct { pthread_mutex_t m; pthread_cond_t c; long n; } sem_t2;
static void sem_init2(sem_t2 *s, long n) { pthread_mutex_init(&s->m, 0); pthread_cond_init(&s->c, 0); s->n = n; }
static void sem_acquire(sem_t2 *s) { pthread_mutex_lock(&s->m); while (s->n == 0) pthread_cond_wait(&s->c, &s->m); s->n--; pthread_mutex_unlock(&s->m); }
static void sem_release(sem_t2 *s) { pthread_mutex_lock(&s->m); s->n++; pthread_cond_signal(&s->c); pthread_mutex_unlock(&s->m); }

/* a wait group from a mutex and a condition variable */
typedef struct { pthread_mutex_t m; pthread_cond_t c; long n; } wg_t;
static void wg_init(wg_t *w) { pthread_mutex_init(&w->m, 0); pthread_cond_init(&w->c, 0); w->n = 0; }
static void wg_add(wg_t *w, long d) { pthread_mutex_lock(&w->m); w->n += d; if (w->n == 0) pthread_cond_broadcast(&w->c); pthread_mutex_unlock(&w->m); }
static void wg_wait(wg_t *w) { pthread_mutex_lock(&w->m); while (w->n != 0) pthread_cond_wait(&w->c, &w->m); pthread_mutex_unlock(&w->m); }

static pthread_mutex_t mtx = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t not_empty = PTHREAD_COND_INITIALIZER;
static pthread_cond_t not_full = PTHREAD_COND_INITIALIZER;
static sem_t2 sem;
static wg_t wg;
static _Atomic long head = 0, tail = 0, done = 0, sum = 0;

static void *producer(void *arg) {
    (void) arg;
    sem_acquire(&sem);
    for (int k = 0; k < ITEMS; k++) {
        pthread_mutex_lock(&mtx);
        while (atomic_load(&head) - atomic_load(&tail) >= CAP) pthread_cond_wait(&not_full, &mtx);
        atomic_fetch_add(&head, 1);
        pthread_cond_signal(&not_empty);
        pthread_mutex_unlock(&mtx);
    }
    sem_release(&sem);
    wg_add(&wg, -1);
    return 0;
}
static void *consumer(void *arg) {
    (void) arg;
    for (;;) {
        pthread_mutex_lock(&mtx);
        while (atomic_load(&head) - atomic_load(&tail) <= 0 && atomic_load(&done) == 0) pthread_cond_wait(&not_empty, &mtx);
        if (atomic_load(&head) - atomic_load(&tail) <= 0) { pthread_mutex_unlock(&mtx); break; }
        long i = atomic_load(&tail);
        atomic_fetch_add(&tail, 1);
        pthread_cond_signal(&not_full);
        pthread_mutex_unlock(&mtx);
        atomic_fetch_add(&sum, i + 1);
    }
    return 0;
}

int main(void) {
    sem_init2(&sem, PERMITS);
    wg_init(&wg);
    wg_add(&wg, PRODUCERS);
    pthread_t ph[PRODUCERS], ch[CONSUMERS];
    for (int i = 0; i < PRODUCERS; i++) pthread_create(&ph[i], 0, producer, 0);
    for (int i = 0; i < CONSUMERS; i++) pthread_create(&ch[i], 0, consumer, 0);
    wg_wait(&wg);
    pthread_mutex_lock(&mtx);
    atomic_store(&done, 1);
    pthread_cond_broadcast(&not_empty);
    pthread_mutex_unlock(&mtx);
    for (int i = 0; i < PRODUCERS; i++) pthread_join(ph[i], 0);
    for (int i = 0; i < CONSUMERS; i++) pthread_join(ch[i], 0);
    long long T = (long long) PRODUCERS * ITEMS;
    long long expected = T * (T + 1) / 2;
    long long got = atomic_load(&sum);
    printf("checksum %lld expected %lld %s\n", got, expected, got == expected ? "ok" : "MISMATCH");
    return 0;
}

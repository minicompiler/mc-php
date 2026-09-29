/* examples/threads/c/primes.c -- the C twin of primes.php: the same slices,
 * one pthread (or Win32 thread) each, joined and added. For reference and for
 * the bench row tests/examples.sh prints; built with cc -O2.
 *
 *     cc -O2 -o primes-c c/primes.c -lpthread && PRIMES_THREADS=4 ./primes-c
 */
#include <stdio.h>
#include <stdlib.h>
#ifdef _WIN32
#include <windows.h>
#else
#include <pthread.h>
#include <unistd.h>
#endif

typedef struct { long lo, hi, n; } slice;

static long count_primes(long lo, long hi) {
    long n = 0;
    for (long i = lo; i < hi; i++) {
        if (i < 2) continue;
        int p = 1;
        for (long d = 2; d * d <= i; d++) {
            if (i % d == 0) { p = 0; break; }
        }
        n += p;
    }
    return n;
}

#ifdef _WIN32
static DWORD WINAPI run(LPVOID a) { slice *s = a; s->n = count_primes(s->lo, s->hi); return 0; }
static long ncpu(void) { SYSTEM_INFO si; GetSystemInfo(&si); return si.dwNumberOfProcessors; }
#else
static void *run(void *a) { slice *s = a; s->n = count_primes(s->lo, s->hi); return 0; }
static long ncpu(void) { return sysconf(_SC_NPROCESSORS_ONLN); }
#endif

int main(void) {
    long limit = 2000000;
    const char *e = getenv("PRIMES_THREADS");
    long nt = e && *e ? atol(e) : ncpu();
    if (nt < 1) nt = 1;
    long step = (limit + nt - 1) / nt;
    slice *s = calloc(nt, sizeof *s);
#ifdef _WIN32
    HANDLE *h = calloc(nt, sizeof *h);
#else
    pthread_t *h = calloc(nt, sizeof *h);
#endif
    for (long t = 0; t < nt; t++) {
        s[t].lo = t * step;
        s[t].hi = s[t].lo + step < limit ? s[t].lo + step : limit;
#ifdef _WIN32
        h[t] = CreateThread(0, 0, run, &s[t], 0, 0);
#else
        pthread_create(&h[t], 0, run, &s[t]);
#endif
    }
    long total = 0;
    for (long t = 0; t < nt; t++) {
#ifdef _WIN32
        WaitForSingleObject(h[t], INFINITE);
        CloseHandle(h[t]);
#else
        pthread_join(h[t], 0);
#endif
        total += s[t].n;
    }
    printf("primes below %ld: %ld\n", limit, total);
    return 0;
}

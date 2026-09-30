/* awaitable.c -- the C TWIN of awaitable.src.php: the same extension written
 * as an ordinary C extension, the way php-src's own are. It is a hand-written
 * mirror of THIS example's workload and concurrency STRUCTURE, on native OS
 * threads and native sync -- no fork, no pipe, no dlsym, no libcurl:
 *
 *   await($fn, ...$args)       zend_fcall_info over the callable, run on the
 *                              calling thread, the answer or the pending
 *                              exception put in an Intent
 *   parallel($which, ...$args) one pthread per argument, each running the C
 *                              EQUIVALENT of this example's workload named by
 *                              $which (heavy/bracket/shout/strrev/throw); the
 *                              threads share this process, joined in order.
 *                              The mc-php module runs a php callable on each
 *                              thread instead (docs/threads.md § 3b); the twin
 *                              mirrors the fan-out with plain C functions, so
 *                              it needs no php interpreter per thread. c/twin.php
 *                              drives it and prints check.expect's bytes.
 *   http_get / http_get_many   one pthread per url, the file the url names read
 *                              with C stdio; every thread passes through the
 *                              bound Semaphore, if any, and counts live/peak
 *   Semaphore / WaitGroup      a mutex and a condition variable each
 *   Mutex                      a mutex
 *
 * The native handle of each sync object lives in a PRIVATE property (the caller
 * must not hand a pointer of its choosing to a thread). A sync object frees its
 * handle with itself and cannot be cloned.
 *
 * It is a ZTS extension (a thread-safe php loads it), built and graded in
 * Docker php:8.5-zts-alpine by tests/examples.sh:
 *
 *     cc -O2 -shared -fPIC -o awaitable.so awaitable.c $(php-config --includes) -lpthread
 *
 * POSIX pthreads; on Windows the twin is not built and CI's ZTS legs cover the
 * compiled module there (README.md).
 */
#include "php.h"
#include "zend_exceptions.h"
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <stdio.h>
#include <unistd.h>

/* --- sync: mutex + condvar ------------------------------------------------ */
typedef struct { pthread_mutex_t m; pthread_cond_t c; zend_long n; } sync_t;

static void sync_init(sync_t *s, zend_long n) { pthread_mutex_init(&s->m, NULL); pthread_cond_init(&s->c, NULL); s->n = n; }
static void sem_acquire(sync_t *s) {
    pthread_mutex_lock(&s->m);
    while (s->n <= 0) pthread_cond_wait(&s->c, &s->m);
    s->n--;
    pthread_mutex_unlock(&s->m);
}
static void sem_release(sync_t *s) {
    pthread_mutex_lock(&s->m); s->n++; pthread_cond_signal(&s->c); pthread_mutex_unlock(&s->m);
}
static void wg_add(sync_t *w, zend_long n) { pthread_mutex_lock(&w->m); w->n += n; pthread_mutex_unlock(&w->m); }
static void wg_done(sync_t *w) {
    pthread_mutex_lock(&w->m); w->n--;
    if (w->n <= 0) pthread_cond_broadcast(&w->c);
    pthread_mutex_unlock(&w->m);
}
static void wg_wait(sync_t *w) {
    pthread_mutex_lock(&w->m);
    while (w->n > 0) pthread_cond_wait(&w->c, &w->m);
    pthread_mutex_unlock(&w->m);
}

/* --- the counters and the bound semaphore --------------------------------- */
/* Shared by parallel and http_get_many, as the module's atomics are: since
 * reset(), peak is the greatest number of tasks that ran at once, completed
 * the tasks that returned, errors the ones that threw. */
static pthread_mutex_t statm = PTHREAD_MUTEX_INITIALIZER;
static zend_long live, peak, done_n, errn;
static sync_t *gsem;

/* --- one fetch on a thread: pure C, it never touches a php value ----------- */
typedef struct { pthread_t tid; char *path; char *buf; size_t len; int err; int joined; } job_t;

/* a file:// url is a path; read it whole with C stdio */
static char *read_file(const char *path, size_t *out) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    size_t cap = 4096, n = 0;
    char *b = malloc(cap);
    if (!b) { fclose(f); return NULL; }
    for (;;) {
        if (n == cap) { cap *= 2; char *nb = realloc(b, cap); if (!nb) { free(b); fclose(f); return NULL; } b = nb; }
        size_t k = fread(b + n, 1, cap - n, f);
        n += k;
        if (k == 0) break;
    }
    fclose(f);
    *out = n;
    return b;
}

static void *fetch_worker(void *arg) {
    job_t *job = arg;
    sync_t *s = gsem;
    if (s) sem_acquire(s);
    pthread_mutex_lock(&statm);
    live++;
    if (live > peak) peak = live;
    pthread_mutex_unlock(&statm);
    job->buf = read_file(job->path, &job->len);
    if (!job->buf) job->err = 1;
    pthread_mutex_lock(&statm);
    live--; done_n++;
    pthread_mutex_unlock(&statm);
    if (s) sem_release(s);
    return NULL;
}

static const char *url_path(const char *u) { return strncmp(u, "file://", 7) == 0 ? u + 7 : u; }

static job_t *run_fetch(zend_string *url) {
    job_t *job = calloc(1, sizeof *job);
    job->path = strdup(url_path(ZSTR_VAL(url)));
    if (pthread_create(&job->tid, NULL, fetch_worker, job) != 0) { job->err = 1; job->joined = 1; }
    return job;
}
static void join_job(job_t *job) { if (!job->joined) { pthread_join(job->tid, NULL); job->joined = 1; } }
static void free_job(job_t *job) { free(job->buf); free(job->path); free(job); }

PHP_FUNCTION(http_get) {
    zend_string *url;
    ZEND_PARSE_PARAMETERS_START(1, 1)
        Z_PARAM_STR(url)
    ZEND_PARSE_PARAMETERS_END();
    job_t *job = run_fetch(url);
    join_job(job);
    if (job->err || !job->buf) zend_throw_exception_ex(zend_ce_exception, 0, "awaitable\\http_get: cannot read %s", ZSTR_VAL(url));
    else RETVAL_STRINGL(job->buf, job->len);
    free_job(job);
}

/* every url on its own thread, and it returns when the last one is in */
PHP_FUNCTION(http_get_many) {
    zval *urls; uint32_t n;
    ZEND_PARSE_PARAMETERS_START(1, -1)
        Z_PARAM_VARIADIC('+', urls, n)
    ZEND_PARSE_PARAMETERS_END();
    if (n > 64) { zend_type_error("awaitable\\http_get_many(): at most 64 urls"); RETURN_THROWS(); }
    for (uint32_t i = 0; i < n; i++)
        if (Z_TYPE(urls[i]) != IS_STRING) { zend_type_error("awaitable\\http_get_many(): every argument must be a string"); RETURN_THROWS(); }
    job_t *jobs[64];
    for (uint32_t i = 0; i < n; i++) jobs[i] = run_fetch(Z_STR(urls[i]));
    array_init_size(return_value, n);
    for (uint32_t i = 0; i < n; i++) {
        join_job(jobs[i]);
        if (jobs[i]->err || !jobs[i]->buf) add_next_index_stringl(return_value, "", 0);
        else add_next_index_stringl(return_value, jobs[i]->buf, jobs[i]->len);
        free_job(jobs[i]);
    }
}

/* --- parallel: the C EQUIVALENT of this example's workload, one per thread -- */
enum { W_HEAVY, W_BRACKET, W_SHOUT, W_STRREV, W_THROW, W_UNKNOWN };

static int which_of(const char *s) {
    if (!strcmp(s, "heavy"))   return W_HEAVY;
    if (!strcmp(s, "bracket")) return W_BRACKET;
    if (!strcmp(s, "shout"))   return W_SHOUT;
    if (!strcmp(s, "strrev"))  return W_STRREV;
    if (!strcmp(s, "throw"))   return W_THROW;
    return W_UNKNOWN;
}

/* the heavy workload, byte for byte awaitable.src.php's heavy(): the sum over
 * i in 1..200000 of (i * (int) $n) % 7 */
static zend_long heavy_sum(zend_long k) {
    zend_long s = 0;
    for (zend_long i = 1; i <= 200000; i++) s += (i * k) % 7;
    return s;
}

typedef struct {
    pthread_t tid;
    int kind;
    char *arg;
    /* the result the main thread turns into a zval after the join */
    zend_long sum;
    char *sval;
    int is_err;
} ptask_t;

static char *dup_bracket(const char *s) { size_t n = strlen(s); char *r = malloc(n + 3); r[0] = '['; memcpy(r + 1, s, n); r[n + 1] = ']'; r[n + 2] = 0; return r; }
static char *dup_shout(const char *s) { size_t n = strlen(s); char *r = malloc(n + 2); for (size_t i = 0; i < n; i++) r[i] = (char) toupper((unsigned char) s[i]); r[n] = '!'; r[n + 1] = 0; return r; }
static char *dup_strrev(const char *s) { size_t n = strlen(s); char *r = malloc(n + 1); for (size_t i = 0; i < n; i++) r[i] = s[n - 1 - i]; r[n] = 0; return r; }
static char *dup_throw(const char *s) { size_t n = strlen(s); const char *p = "failed on "; size_t pn = strlen(p); char *r = malloc(pn + n + 1); memcpy(r, p, pn); memcpy(r + pn, s, n); r[pn + n] = 0; return r; }

static void *ptask_worker(void *a) {
    ptask_t *t = a;
    switch (t->kind) {
        case W_HEAVY:   t->sum = heavy_sum(strtol(t->arg, NULL, 10)); break;
        case W_BRACKET: t->sval = dup_bracket(t->arg); break;
        case W_SHOUT:   t->sval = dup_shout(t->arg); break;
        case W_STRREV:  t->sval = dup_strrev(t->arg); break;
        case W_THROW:   t->sval = dup_throw(t->arg); t->is_err = 1; break;
        default:        t->sval = strdup(""); t->is_err = 1; break;
    }
    return NULL;
}

PHP_FUNCTION(parallel) {
    zend_string *which;
    zval *args; uint32_t n;
    ZEND_PARSE_PARAMETERS_START(2, -1)
        Z_PARAM_STR(which)
        Z_PARAM_VARIADIC('+', args, n)
    ZEND_PARSE_PARAMETERS_END();
    if (n > 64) { zend_type_error("awaitable\\parallel(): at most 64 jobs"); RETURN_THROWS(); }
    int kind = which_of(ZSTR_VAL(which));
    ptask_t task[64];
    for (uint32_t i = 0; i < n; i++) {
        convert_to_string(&args[i]);
        task[i].kind = kind;
        task[i].arg = strndup(Z_STRVAL(args[i]), Z_STRLEN(args[i]));
        task[i].sum = 0; task[i].sval = NULL; task[i].is_err = 0;
        if (pthread_create(&task[i].tid, NULL, ptask_worker, &task[i]) != 0) { task[i].is_err = 1; task[i].sval = strdup(""); }
    }
    /* every task is outstanding until the joins begin */
    pthread_mutex_lock(&statm);
    if ((zend_long) n > peak) peak = n;
    pthread_mutex_unlock(&statm);
    array_init_size(return_value, n);
    for (uint32_t i = 0; i < n; i++) {
        pthread_join(task[i].tid, NULL);
        if (task[i].kind == W_HEAVY) {
            zval row;
            array_init(&row);
            add_assoc_stringl(&row, "arg", task[i].arg, strlen(task[i].arg));
            add_assoc_long(&row, "sum", task[i].sum);
            add_assoc_long(&row, "pid", (zend_long) getpid());
            add_next_index_zval(return_value, &row);
            done_n++;
        } else if (task[i].is_err && task[i].kind == W_THROW) {
            errn++;
            add_next_index_string(return_value, task[i].sval);
        } else {
            add_next_index_string(return_value, task[i].sval);
            done_n++;
        }
        free(task[i].arg);
        free(task[i].sval);
    }
}

/* --- await: suspends, runs on the calling thread, hands back the Intent ---- */
static zend_class_entry *ce_intent, *ce_sem, *ce_wg, *ce_mx;

PHP_FUNCTION(await) {
    zend_fcall_info fci; zend_fcall_info_cache fcc;
    zval *args = NULL; uint32_t n = 0;
    ZEND_PARSE_PARAMETERS_START(1, -1)
        Z_PARAM_FUNC(fci, fcc)
        Z_PARAM_VARIADIC('*', args, n)
    ZEND_PARSE_PARAMETERS_END();
    zval r;
    ZVAL_UNDEF(&r);
    object_init_ex(return_value, ce_intent);
    zend_object *obj = Z_OBJ_P(return_value);
    fci.retval = &r; fci.params = args; fci.param_count = n;
    zend_call_function(&fci, &fcc);
    zend_update_property_bool(ce_intent, obj, "done", 4, 1);
    if (EG(exception)) {
        zend_update_property_bool(ce_intent, obj, "failed", 6, 1);
        zval e;
        ZVAL_OBJ(&e, EG(exception));
        EG(exception) = NULL;
        zend_update_property(ce_intent, obj, "exception", 9, &e);
        zval_ptr_dtor(&e);
        return;
    }
    zend_update_property_bool(ce_intent, obj, "failed", 6, 0);
    zend_update_property(ce_intent, obj, "data", 4, &r);
    zval_ptr_dtor(&r);
}

PHP_FUNCTION(peak)      { ZEND_PARSE_PARAMETERS_NONE(); RETURN_LONG(peak); }
PHP_FUNCTION(completed) { ZEND_PARSE_PARAMETERS_NONE(); RETURN_LONG(done_n); }
PHP_FUNCTION(errors)    { ZEND_PARSE_PARAMETERS_NONE(); RETURN_LONG(errn); }
PHP_FUNCTION(reset)     { ZEND_PARSE_PARAMETERS_NONE(); pthread_mutex_lock(&statm); live = 0; peak = 0; done_n = 0; errn = 0; pthread_mutex_unlock(&statm); }

/* --- the sync classes: the handle in a private property ------------------- */
static void *handle(zend_class_entry *ce, zval *self) {
    zval rv, *z = zend_read_property(ce, Z_OBJ_P(self), "__h", 3, 1, &rv);
    return (void *)(uintptr_t)Z_LVAL_P(z);
}
static void set_handle(zend_class_entry *ce, zval *self, void *p) {
    zend_update_property_long(ce, Z_OBJ_P(self), "__h", 3, (zend_long)(uintptr_t)p);
}

PHP_METHOD(Semaphore, __construct) {
    zend_long k = 1;
    ZEND_PARSE_PARAMETERS_START(0, 1)
        Z_PARAM_OPTIONAL
        Z_PARAM_LONG(k)
    ZEND_PARSE_PARAMETERS_END();
    sync_t *s = calloc(1, sizeof *s);
    sync_init(s, k);
    set_handle(ce_sem, ZEND_THIS, s);
}
PHP_METHOD(Semaphore, acquire) { ZEND_PARSE_PARAMETERS_NONE(); sem_acquire(handle(ce_sem, ZEND_THIS)); }
PHP_METHOD(Semaphore, release) { ZEND_PARSE_PARAMETERS_NONE(); sem_release(handle(ce_sem, ZEND_THIS)); }
PHP_METHOD(Semaphore, bind)    { ZEND_PARSE_PARAMETERS_NONE(); gsem = handle(ce_sem, ZEND_THIS); }
PHP_METHOD(Semaphore, unbind)  { ZEND_PARSE_PARAMETERS_NONE(); gsem = NULL; }

PHP_METHOD(WaitGroup, __construct) {
    ZEND_PARSE_PARAMETERS_NONE();
    sync_t *w = calloc(1, sizeof *w);
    sync_init(w, 0);
    set_handle(ce_wg, ZEND_THIS, w);
}
PHP_METHOD(WaitGroup, add) {
    zend_long k = 1;
    ZEND_PARSE_PARAMETERS_START(0, 1)
        Z_PARAM_OPTIONAL
        Z_PARAM_LONG(k)
    ZEND_PARSE_PARAMETERS_END();
    wg_add(handle(ce_wg, ZEND_THIS), k);
}
PHP_METHOD(WaitGroup, done) { ZEND_PARSE_PARAMETERS_NONE(); wg_done(handle(ce_wg, ZEND_THIS)); }
PHP_METHOD(WaitGroup, wait) { ZEND_PARSE_PARAMETERS_NONE(); wg_wait(handle(ce_wg, ZEND_THIS)); }

PHP_METHOD(Mutex, __construct) {
    ZEND_PARSE_PARAMETERS_NONE();
    pthread_mutex_t *m = calloc(1, sizeof *m);
    pthread_mutex_init(m, NULL);
    set_handle(ce_mx, ZEND_THIS, m);
}
PHP_METHOD(Mutex, lock)   { ZEND_PARSE_PARAMETERS_NONE(); pthread_mutex_lock(handle(ce_mx, ZEND_THIS)); }
PHP_METHOD(Mutex, unlock) { ZEND_PARSE_PARAMETERS_NONE(); pthread_mutex_unlock(handle(ce_mx, ZEND_THIS)); }

/* --- the tables ----------------------------------------------------------- */
ZEND_BEGIN_ARG_WITH_RETURN_OBJ_INFO_EX(ai_await, 0, 1, awaitable\\Intent, 0)
    ZEND_ARG_TYPE_INFO(0, fn, IS_CALLABLE, 0)
    ZEND_ARG_VARIADIC_TYPE_INFO(0, args, IS_MIXED, 0)
ZEND_END_ARG_INFO()
ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(ai_parallel, 0, 2, IS_ARRAY, 0)
    ZEND_ARG_TYPE_INFO(0, which, IS_STRING, 0)
    ZEND_ARG_VARIADIC_TYPE_INFO(0, args, IS_MIXED, 0)
ZEND_END_ARG_INFO()
ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(ai_http_get, 0, 1, IS_STRING, 0)
    ZEND_ARG_TYPE_INFO(0, url, IS_STRING, 0)
ZEND_END_ARG_INFO()
ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(ai_http_get_many, 0, 1, IS_ARRAY, 0)
    ZEND_ARG_VARIADIC_TYPE_INFO(0, urls, IS_STRING, 0)
ZEND_END_ARG_INFO()
ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(ai_int, 0, 0, IS_LONG, 0)
ZEND_END_ARG_INFO()
ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(ai_void, 0, 0, IS_VOID, 0)
ZEND_END_ARG_INFO()
ZEND_BEGIN_ARG_INFO_EX(ai_n, 0, 0, 0)
    ZEND_ARG_TYPE_INFO_WITH_DEFAULT_VALUE(0, n, IS_LONG, 0, "1")
ZEND_END_ARG_INFO()
ZEND_BEGIN_ARG_INFO_EX(ai_ctor, 0, 0, 0)
ZEND_END_ARG_INFO()

static const zend_function_entry awaitable_functions[] = {
    ZEND_NS_FE("awaitable", await, ai_await)
    ZEND_NS_FE("awaitable", parallel, ai_parallel)
    ZEND_NS_FE("awaitable", http_get, ai_http_get)
    ZEND_NS_FE("awaitable", http_get_many, ai_http_get_many)
    ZEND_NS_FE("awaitable", peak, ai_int)
    ZEND_NS_FE("awaitable", completed, ai_int)
    ZEND_NS_FE("awaitable", errors, ai_int)
    ZEND_NS_FE("awaitable", reset, ai_void)
    PHP_FE_END
};
static const zend_function_entry sem_methods[] = {
    PHP_ME(Semaphore, __construct, ai_n, ZEND_ACC_PUBLIC)
    PHP_ME(Semaphore, acquire, ai_void, ZEND_ACC_PUBLIC)
    PHP_ME(Semaphore, release, ai_void, ZEND_ACC_PUBLIC)
    PHP_ME(Semaphore, bind, ai_void, ZEND_ACC_PUBLIC)
    PHP_ME(Semaphore, unbind, ai_void, ZEND_ACC_PUBLIC)
    PHP_FE_END
};
static const zend_function_entry wg_methods[] = {
    PHP_ME(WaitGroup, __construct, ai_ctor, ZEND_ACC_PUBLIC)
    PHP_ME(WaitGroup, add, ai_n, ZEND_ACC_PUBLIC)
    PHP_ME(WaitGroup, done, ai_void, ZEND_ACC_PUBLIC)
    PHP_ME(WaitGroup, wait, ai_void, ZEND_ACC_PUBLIC)
    PHP_FE_END
};
static const zend_function_entry mx_methods[] = {
    PHP_ME(Mutex, __construct, ai_ctor, ZEND_ACC_PUBLIC)
    PHP_ME(Mutex, lock, ai_void, ZEND_ACC_PUBLIC)
    PHP_ME(Mutex, unlock, ai_void, ZEND_ACC_PUBLIC)
    PHP_FE_END
};

/* A sync object frees its native handle with itself, and cannot be cloned:
 * a clone would share the handle and free it twice. `__h` is the class's only
 * declared property, so it is property slot 0. */
static zend_object_handlers sync_handlers;
static zend_object *sync_new(zend_class_entry *ce) {
    zend_object *o = zend_objects_new(ce);
    object_properties_init(o, ce);
    o->handlers = &sync_handlers;
    return o;
}
static void sync_free(zend_object *o) {
    zval *z = OBJ_PROP_NUM(o, 0);
    void *p = Z_TYPE_P(z) == IS_LONG ? (void *)(uintptr_t)Z_LVAL_P(z) : NULL;
    if (p && o->ce == ce_mx) pthread_mutex_destroy(p);
    else if (p) {
        sync_t *s = p;
        if (s == gsem) gsem = NULL;
        pthread_cond_destroy(&s->c);
        pthread_mutex_destroy(&s->m);
    }
    free(p);
    zend_object_std_dtor(o);
}

static zend_class_entry *reg(const char *name, const zend_function_entry *m) {
    zend_class_entry ce;
    INIT_CLASS_ENTRY_EX(ce, name, strlen(name), m);
    zend_class_entry *c = zend_register_internal_class(&ce);
    c->ce_flags |= ZEND_ACC_FINAL;
    return c;
}

static PHP_MINIT_FUNCTION(awaitable) {
    memcpy(&sync_handlers, zend_get_std_object_handlers(), sizeof sync_handlers);
    sync_handlers.free_obj = sync_free;
    sync_handlers.clone_obj = NULL;
    ce_sem = reg("awaitable\\Semaphore", sem_methods);
    zend_declare_property_long(ce_sem, "__h", 3, 0, ZEND_ACC_PRIVATE);
    ce_sem->create_object = sync_new;
    ce_wg = reg("awaitable\\WaitGroup", wg_methods);
    zend_declare_property_long(ce_wg, "__h", 3, 0, ZEND_ACC_PRIVATE);
    ce_wg->create_object = sync_new;
    ce_mx = reg("awaitable\\Mutex", mx_methods);
    zend_declare_property_long(ce_mx, "__h", 3, 0, ZEND_ACC_PRIVATE);
    ce_mx->create_object = sync_new;
    ce_intent = reg("awaitable\\Intent", NULL);
    zend_declare_property_bool(ce_intent, "done", 4, 0, ZEND_ACC_PUBLIC);
    zend_declare_property_bool(ce_intent, "failed", 6, 0, ZEND_ACC_PUBLIC);
    zend_declare_property_null(ce_intent, "exception", 9, ZEND_ACC_PUBLIC);
    zend_declare_property_null(ce_intent, "data", 4, ZEND_ACC_PUBLIC);
    return SUCCESS;
}

zend_module_entry awaitable_module_entry = {
    STANDARD_MODULE_HEADER, "awaitable", awaitable_functions,
    PHP_MINIT(awaitable), NULL, NULL, NULL, NULL, "0.4.0", STANDARD_MODULE_PROPERTIES
};

ZEND_GET_MODULE(awaitable)

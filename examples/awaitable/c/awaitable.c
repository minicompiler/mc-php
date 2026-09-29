/* awaitable.c -- the C TWIN of awaitable.src.php: the same extension written
 * as an ordinary C extension, the way php-src's own are. It is the
 * SPECIFICATION the compiled module is measured against, and the algorithm is
 * awaitable.mc's (the hand-written oracle) function by function:
 *
 *   await($fn, ...$args)       zend_fcall_info over the callable, the answer
 *                              or the pending exception put in an Intent
 *   parallel($fn, ...$args)    one fork() per argument; the child calls $fn,
 *                              serialize()s the answer and writes it down a
 *                              pipe (a tag byte, a length, the bytes); the
 *                              parent reads each pipe in order, waitpid()s
 *                              and unserialize()s. A child that threw sends
 *                              the message, and the parent counts an error.
 *   http_get / http_get_many   one pthread per url, libcurl's easy interface,
 *                              the body grown with realloc by the write
 *                              callback; every thread passes through the bound
 *                              Semaphore, if any, and counts live/peak/done
 *   Semaphore / WaitGroup      a mutex and a condition variable each
 *   Mutex                      a mutex
 *
 * The native handle of each sync object lives in a PRIVATE property, as
 * awaitable.mc keeps it (the caller must not be able to hand pthread a pointer
 * of its choosing).
 *
 *     cc -O2 -bundle -undefined dynamic_lookup -o awaitable.so awaitable.c $(php-config --includes) -lcurl   # macOS
 *     cc -O2 -shared -fPIC -o awaitable.so awaitable.c $(php-config --includes) -lcurl -lpthread         # Linux
 *
 * POSIX: fork, pipe and pthreads. On Windows the twin is not built, and the
 * compiled module says what each function does there (README.md).
 */
#include "php.h"
#include "ext/standard/php_var.h"
#include "zend_exceptions.h"
#include "zend_interfaces.h"
#include <pthread.h>
#include <unistd.h>
#include <errno.h>
#include <sys/wait.h>
#include <curl/curl.h>

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

/* --- the counters, the bound semaphore, the wait group of every thread ---- */
static pthread_mutex_t statm = PTHREAD_MUTEX_INITIALIZER;
static zend_long live, peak, done_n, errn;
static sync_t *gsem;
static sync_t gwg;

/* --- one fetch on a thread: native only, it never touches a php value ----- */
typedef struct { pthread_t tid; char *url; char *buf; size_t len; long code; int err; int joined; } job_t;

static size_t sink(char *p, size_t size, size_t n, void *data) {
    job_t *job = data;
    size_t got = size * n;
    char *b = realloc(job->buf, job->len + got + 1);
    if (!b) return 0;
    memcpy(b + job->len, p, got);
    b[job->len + got] = 0;
    job->buf = b;
    job->len += got;
    return got;
}

static void http_do(job_t *job) {
    CURL *h = curl_easy_init();
    if (!h) { job->err = 2; return; }
    curl_easy_setopt(h, CURLOPT_URL, job->url);
    curl_easy_setopt(h, CURLOPT_WRITEFUNCTION, sink);
    curl_easy_setopt(h, CURLOPT_WRITEDATA, job);
    curl_easy_setopt(h, CURLOPT_FOLLOWLOCATION, 1L);
    curl_easy_setopt(h, CURLOPT_TIMEOUT, 30L);
    curl_easy_setopt(h, CURLOPT_NOSIGNAL, 1L);
    job->err = curl_easy_perform(h);
    long code = 0;
    curl_easy_getinfo(h, CURLINFO_RESPONSE_CODE, &code);
    job->code = code;
    curl_easy_cleanup(h);
}

static void *worker(void *arg) {
    job_t *job = arg;
    sync_t *s = gsem;
    if (s) sem_acquire(s);
    pthread_mutex_lock(&statm);
    live++;
    if (live > peak) peak = live;
    pthread_mutex_unlock(&statm);
    http_do(job);
    pthread_mutex_lock(&statm);
    live--; done_n++;
    pthread_mutex_unlock(&statm);
    if (s) sem_release(s);
    wg_done(&gwg);
    return NULL;
}

static job_t *run_job(zend_string *url) {
    job_t *job = calloc(1, sizeof *job);
    job->url = strndup(ZSTR_VAL(url), ZSTR_LEN(url));
    wg_add(&gwg, 1);
    if (pthread_create(&job->tid, NULL, worker, job) != 0) {
        wg_done(&gwg); job->err = 2; job->joined = 1;
    }
    return job;
}
static void join_job(job_t *job) { if (!job->joined) { pthread_join(job->tid, NULL); job->joined = 1; } }
static void free_job(job_t *job) { free(job->buf); free(job->url); free(job); }

PHP_FUNCTION(http_get) {
    zend_string *url;
    ZEND_PARSE_PARAMETERS_START(1, 1)
        Z_PARAM_STR(url)
    ZEND_PARSE_PARAMETERS_END();
    job_t *job = run_job(url);
    join_job(job);
    if (job->err) zend_throw_exception(zend_ce_exception, curl_easy_strerror(job->err), 0);
    else RETVAL_STRINGL(job->buf ? job->buf : "", job->len);
    free_job(job);
}

/* every url on its own thread, and it returns when the last one is in */
PHP_FUNCTION(http_get_many) {
    zval *urls; uint32_t n;
    ZEND_PARSE_PARAMETERS_START(1, -1)
        Z_PARAM_VARIADIC('+', urls, n)
    ZEND_PARSE_PARAMETERS_END();
    if (n > 64) { zend_type_error("awaitable\\http_get_many(): at most 64 urls"); RETURN_THROWS(); }
    /* every argument checked BEFORE any thread starts */
    for (uint32_t i = 0; i < n; i++)
        if (Z_TYPE(urls[i]) != IS_STRING) { zend_type_error("awaitable\\http_get_many(): every argument must be a string"); RETURN_THROWS(); }
    job_t *jobs[64];
    for (uint32_t i = 0; i < n; i++) jobs[i] = run_job(Z_STR(urls[i]));
    array_init_size(return_value, n);
    for (uint32_t i = 0; i < n; i++) {
        join_job(jobs[i]);
        if (jobs[i]->err) add_next_index_null(return_value);
        else add_next_index_stringl(return_value, jobs[i]->buf ? jobs[i]->buf : "", jobs[i]->len);
        free_job(jobs[i]);
    }
}

/* --- any php callable, one forked child per argument ---------------------- */
/* a signal handler installed without SA_RESTART makes a blocked read, write
   or waitpid return -1 with EINTR: asked again, every one (signals.php) */
static void write_all(int fd, const char *p, size_t n) {
    size_t off = 0;
    while (off < n) {
        ssize_t k = write(fd, p + off, n - off);
        if (k < 0 && errno == EINTR) continue;
        if (k <= 0) return;
        off += k;
    }
}
static size_t read_all(int fd, char *p, size_t n) {
    size_t off = 0;
    while (off < n) {
        ssize_t k = read(fd, p + off, n - off);
        if (k < 0 && errno == EINTR) continue;
        if (k <= 0) return off;
        off += k;
    }
    return off;
}

/* the child: call, serialize, write (tag 0, length, bytes) or the message of
   what it threw (tag 1), and exit without running php's shutdown */
static void child(int wfd, zend_fcall_info *fci, zend_fcall_info_cache *fcc, zval *arg) {
    zval out;
    char tag;
    ZVAL_UNDEF(&out);
    fci->retval = &out; fci->params = arg; fci->param_count = 1;
    zend_call_function(fci, fcc);
    if (!EG(exception)) {
        smart_str buf = {0};
        php_serialize_data_t vh;
        PHP_VAR_SERIALIZE_INIT(vh);
        php_var_serialize(&buf, &out, &vh);
        PHP_VAR_SERIALIZE_DESTROY(vh);
        tag = 0; write_all(wfd, &tag, 1);
        uint64_t len = buf.s ? ZSTR_LEN(buf.s) : 0;
        write_all(wfd, (char *)&len, 8);
        if (len) write_all(wfd, ZSTR_VAL(buf.s), len);
        _exit(0);
    }
    zend_object *e = EG(exception);
    zval rv, *m = zend_read_property(zend_get_exception_base(e), e, "message", 7, 1, &rv);
    tag = 1; write_all(wfd, &tag, 1);
    uint64_t len = Z_TYPE_P(m) == IS_STRING ? Z_STRLEN_P(m) : 0;
    write_all(wfd, (char *)&len, 8);
    if (len) write_all(wfd, Z_STRVAL_P(m), len);
    _exit(0);
}

PHP_FUNCTION(parallel) {
    zend_fcall_info fci; zend_fcall_info_cache fcc;
    zval *args; uint32_t n;
    ZEND_PARSE_PARAMETERS_START(2, -1)
        Z_PARAM_FUNC(fci, fcc)
        Z_PARAM_VARIADIC('+', args, n)
    ZEND_PARSE_PARAMETERS_END();
    if (n > 64) { zend_type_error("awaitable\\parallel(): at most 64 jobs"); RETURN_THROWS(); }
    pid_t pid[64]; int fd[64];
    for (uint32_t i = 0; i < n; i++) {
        /* a job that cannot start is -1 in ITS slot, answered as failed */
        pid[i] = -1;
        int p[2];
        if (pipe(p) != 0) continue;
        pid_t k = fork();
        if (k == 0) { close(p[0]); child(p[1], &fci, &fcc, &args[i]); }
        close(p[1]);
        if (k < 0) { close(p[0]); continue; }
        pid[i] = k; fd[i] = p[0];
    }
    array_init_size(return_value, n);
    for (uint32_t i = 0; i < n; i++) {
        char tag = 1; uint64_t len = 0; char *buf = NULL;
        if (pid[i] != -1) {
            if (read_all(fd[i], &tag, 1) == 1 && read_all(fd[i], (char *)&len, 8) != 8) len = 0;
            if (len) { buf = malloc(len + 1); if (read_all(fd[i], buf, len) != len) len = 0; }
            close(fd[i]);
            int st; while (waitpid(pid[i], &st, 0) < 0 && errno == EINTR) {}
        }
        zval z;
        ZVAL_NULL(&z);
        if (tag == 0 && len) {
            const unsigned char *p = (unsigned char *)buf;
            php_unserialize_data_t vh;
            PHP_VAR_UNSERIALIZE_INIT(vh);
            if (!php_var_unserialize(&z, &p, p + len, &vh)) { zval_ptr_dtor(&z); ZVAL_NULL(&z); }
            PHP_VAR_UNSERIALIZE_DESTROY(vh);
        }
        if (tag != 0) {
            errn++;
            if (len) ZVAL_STRINGL(&z, buf, len);
        }
        free(buf);
        add_next_index_zval(return_value, &z);
    }
}

/* --- await: suspends, runs, hands back the Intent ------------------------- */
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
PHP_FUNCTION(reset)     { ZEND_PARSE_PARAMETERS_NONE(); peak = 0; done_n = 0; errn = 0; }
PHP_FUNCTION(wait_all)  { ZEND_PARSE_PARAMETERS_NONE(); wg_wait(&gwg); }

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
    ZEND_ARG_TYPE_INFO(0, fn, IS_CALLABLE, 0)
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
    ZEND_NS_FE("awaitable", wait_all, ai_void)
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
    curl_global_init(CURL_GLOBAL_ALL);
    sync_init(&gwg, 0);
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
    PHP_MINIT(awaitable), NULL, NULL, NULL, NULL, "0.3.0", STANDARD_MODULE_PROPERTIES
};

ZEND_GET_MODULE(awaitable)

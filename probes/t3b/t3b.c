/* probes/t3b/t3b.c -- threads step 3b's (a)/(b) probe (docs/threads.md § 3b).
 *
 * A php callable run on a thread of our own, in a php context of its own
 * (ts_resource + php_request_startup, ext/parallel's sequence), three ways:
 *
 *   mode 0  (a) share as-is: the worker's function and class tables get the
 *           starting request's user functions and classes BY POINTER, and the
 *           closure is re-created in the worker from the starting closure's
 *           function (zend_create_closure);
 *   mode 1  (a') share, with per-worker shallow copies of each user function
 *           (the op_array struct copied: opcodes and literals shared, a
 *           run-time cache and static variables of the worker's own) -- what
 *           opcache's per-thread ZEND_MAP_PTR slots give an immutable op_array
 *           for free, done by hand for a php without opcache;
 *   mode 2  (b) the callable alone: nothing of the starting request is
 *           registered, the closure gets a private run-time cache;
 *   mode 3  (a) opcache-style: functions and classes shared BY POINTER (no
 *           copies), the worker's ZEND_MAP_PTR table extended to the starting
 *           thread's, and the closure given a private run-time cache -- the
 *           only state that is not per thread already when op_arrays are
 *           opcache's immutable ones.
 *
 * t3b_run(Closure $f, int $mode, int $n, int $parent_loops): array -- n workers
 * at once, each calling $f(i); the starting thread meanwhile calls $f itself
 * $parent_loops times (the concurrency the share modes must survive). Each
 * answer is the worker's result as a string, or "ERR <class>: <message>".
 * t3b_cost(Closure $f, int $mode, int $n): float -- microseconds per start,
 * n starts one after another.
 */
#define ZEND_ENABLE_STATIC_TSRMLS_CACHE 1
#include "php.h"
#include "SAPI.h"
#include "php_main.h"
#include "zend_closures.h"
#include "zend_exceptions.h"
#include "zend_interfaces.h"
#include "zend_smart_str.h"
#include <pthread.h>
#include <time.h>

ZEND_TSRMLS_CACHE_DEFINE()

typedef struct {
    zend_function *func;          /* the starting closure's function */
    zend_class_entry *scope;
    HashTable *pfn, *pcl;         /* the starting request's tables */
    int mode, idx;
    size_t map_last;              /* the starting thread's CG(map_ptr_last) */
    char *out;                    /* malloc'd answer */
} t3b_job;

static char *t3b_dup(const char *s, size_t n) { char *d = malloc(n + 1); memcpy(d, s, n); d[n] = 0; return d; }

/* the starting request's user functions and classes, into this thread's tables */
static void t3b_share(t3b_job *j, HashTable *ownfn)
{
    zend_string *key; zend_function *f; zend_class_entry *ce;
    ZEND_HASH_MAP_FOREACH_STR_KEY_PTR(j->pfn, key, f) {
        if (!key || f->type != ZEND_USER_FUNCTION) continue;
        if (j->mode == 1) {
            zend_op_array *c = emalloc(sizeof(zend_op_array));
            memcpy(c, &f->op_array, sizeof(zend_op_array));
            c->fn_flags &= ~ZEND_ACC_IMMUTABLE;
            c->refcount = NULL;                       /* never destroyed by us */
            void *rt = emalloc(c->cache_size); memset(rt, 0, c->cache_size);
            ZEND_MAP_PTR_INIT(c->run_time_cache, rt);
            ZEND_MAP_PTR_INIT(c->static_variables_ptr, c->static_variables ? zend_array_dup(c->static_variables) : NULL);
            f = (zend_function *) c;
        }
        zend_hash_add_ptr(EG(function_table), key, f);
        zend_hash_add_ptr(ownfn, key, f);
    } ZEND_HASH_FOREACH_END();
    ZEND_HASH_MAP_FOREACH_STR_KEY_PTR(j->pcl, key, ce) {
        if (!key || ce->type != ZEND_USER_CLASS) continue;
        zend_hash_add_ptr(EG(class_table), key, ce);
    } ZEND_HASH_FOREACH_END();
}

/* take them out again without their destructors: they are the starting request's */
static void t3b_unshare(t3b_job *j)
{
    zend_string *key; zend_function *f; zend_class_entry *ce;
    dtor_func_t fd = EG(function_table)->pDestructor, cd = EG(class_table)->pDestructor;
    EG(function_table)->pDestructor = NULL;
    EG(class_table)->pDestructor = NULL;
    ZEND_HASH_MAP_FOREACH_STR_KEY_PTR(j->pfn, key, f) {
        if (key && f->type == ZEND_USER_FUNCTION) zend_hash_del(EG(function_table), key);
    } ZEND_HASH_FOREACH_END();
    ZEND_HASH_MAP_FOREACH_STR_KEY_PTR(j->pcl, key, ce) {
        if (key && ce->type == ZEND_USER_CLASS) zend_hash_del(EG(class_table), key);
    } ZEND_HASH_FOREACH_END();
    EG(function_table)->pDestructor = fd;
    EG(class_table)->pDestructor = cd;
}

#define TR(x) do { if (getenv("T3B_TRACE")) { fprintf(stderr, "t3b %d: %s\n", j->idx, x); fflush(stderr); } } while (0)
static double t3b_ph[5];          /* T3B_TIME: microseconds summed per phase (t3b_cost runs one worker at a time) */
static double t3b_now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1e6 + t.tv_nsec / 1e3; }
static void *t3b_worker(void *arg)
{
    t3b_job *j = arg;
    double t0 = t3b_now();
    TR("start");
    (void) ts_resource(0);
    TSRMLS_CACHE_UPDATE();
    TR("ts_resource");
    double t1 = t3b_now();
    PG(expose_php) = 0;
    PG(auto_globals_jit) = 1;
    if (php_request_startup() == FAILURE) { j->out = t3b_dup("ERR startup", 11); ts_free_thread(); return NULL; }
    TR("request_startup");
    double t2 = t3b_now();
    PG(during_request_startup) = 0;
    SG(sapi_started) = 0;
    SG(headers_sent) = 1;
    SG(request_info).no_headers = 1;

    /* opcache's immutable op_arrays keep their run-time cache in a per-thread
     * ZEND_MAP_PTR slot; a slot the starting thread allocated after this
     * thread's table was sized is past its end until it is extended */
    if (!getenv("T3B_NOEXTEND")) zend_map_ptr_extend(j->map_last);
    HashTable own; zend_hash_init(&own, 8, NULL, NULL, 0);
    zend_try {
        if (j->mode != 2) t3b_share(j, &own);
        if (getenv("T3B_DIAG") && j->idx == 0) {
            zend_function *h = zend_hash_str_find_ptr(EG(function_table), "helper", 6);
            zend_class_entry *pc = zend_hash_str_find_ptr(EG(class_table), "pt", 2);
            zend_function *sm = pc ? zend_hash_str_find_ptr(&pc->function_table, "sum", 3) : NULL;
            fprintf(stderr, "diag2: parent map_last %zu; sum rtc now %p helper rtc now %p\n", j->map_last,
                sm ? ZEND_MAP_PTR_GET(sm->op_array.run_time_cache) : NULL, h ? ZEND_MAP_PTR_GET(h->op_array.run_time_cache) : NULL);
            fprintf(stderr, "diag: map_ptr_last %zu size %zu; helper flags %x rtc %p; Pt flags %x sum flags %x rtc %p; closure flags %x rtc %p\n",
                (size_t) CG(map_ptr_last), (size_t) CG(map_ptr_size),
                h ? h->common.fn_flags : 0, h ? (void *) ZEND_MAP_PTR(h->op_array.run_time_cache) : NULL,
                pc ? pc->ce_flags : 0, sm ? sm->common.fn_flags : 0, sm ? (void *) ZEND_MAP_PTR(sm->op_array.run_time_cache) : NULL,
                j->func->common.fn_flags, (void *) ZEND_MAP_PTR(j->func->op_array.run_time_cache));
        }
        zend_function fn = *j->func;
        if (j->mode != 0) fn.common.fn_flags |= ZEND_ACC_HEAP_RT_CACHE;  /* a private cache */
        zval clo, arg0, ret;
        TR("shared");
        zend_create_closure(&clo, &fn, j->scope, j->scope, NULL);
        TR("closure");
        ZVAL_LONG(&arg0, j->idx);
        ZVAL_UNDEF(&ret);
        /* an internal frame under the call: an uncaught throwable stays in
         * EG(exception) instead of being php's fatal error (no user frame) */
        zend_execute_data dummy; memset(&dummy, 0, sizeof dummy);
        zend_internal_function fake; memset(&fake, 0, sizeof fake);
        fake.type = ZEND_INTERNAL_FUNCTION;
        fake.function_name = zend_string_init("t3b_worker", 10, 0);
        dummy.func = (zend_function *) &fake;
        zend_execute_data *saved = EG(current_execute_data);
        EG(current_execute_data) = &dummy;
        call_user_function(NULL, NULL, &clo, &ret, 1, &arg0);
        EG(current_execute_data) = saved;
        zend_string_release(fake.function_name);
        TR("called");
        if (EG(exception)) {
            zend_object *ex = EG(exception);
            zval rv; zval *msg = zend_read_property_ex(ex->ce, ex, ZSTR_KNOWN(ZEND_STR_MESSAGE), 1, &rv);
            smart_str s = {0};
            smart_str_appends(&s, "ERR "); smart_str_append(&s, ex->ce->name);
            smart_str_appends(&s, ": "); if (Z_TYPE_P(msg) == IS_STRING) smart_str_append(&s, Z_STR_P(msg));
            smart_str_0(&s);
            j->out = t3b_dup(ZSTR_VAL(s.s), ZSTR_LEN(s.s));
            smart_str_free(&s);
            zend_clear_exception();
        } else {
            zend_string *r = zval_get_string(&ret);
            j->out = t3b_dup(ZSTR_VAL(r), ZSTR_LEN(r));
            zend_string_release(r);
        }
        zval_ptr_dtor(&ret);
        zval_ptr_dtor(&clo);
        if (j->mode != 2) t3b_unshare(j);
    } zend_catch {
        if (!j->out) j->out = t3b_dup("ERR bailout", 11);
    } zend_end_try();
    zend_hash_destroy(&own);
    double t3 = t3b_now();
    TR("before shutdown");
    php_request_shutdown(NULL);
    TR("request_shutdown");
    double t4 = t3b_now();
    ts_free_thread();
    TR("freed");
    double t5 = t3b_now();
    t3b_ph[0] += t1 - t0; t3b_ph[1] += t2 - t1; t3b_ph[2] += t3 - t2; t3b_ph[3] += t4 - t3; t3b_ph[4] += t5 - t4;
    return NULL;
}

static zend_function *t3b_func(zval *f, zend_class_entry **scope)
{
    zend_function *fn = (zend_function *) zend_get_closure_method_def(Z_OBJ_P(f));
    *scope = fn->common.scope;
    return fn;
}

PHP_FUNCTION(t3b_run)
{
    zval *f; zend_long mode, n, loops;
    ZEND_PARSE_PARAMETERS_START(4, 4)
        Z_PARAM_OBJECT_OF_CLASS(f, zend_ce_closure) Z_PARAM_LONG(mode) Z_PARAM_LONG(n) Z_PARAM_LONG(loops)
    ZEND_PARSE_PARAMETERS_END();
    zend_class_entry *scope; zend_function *fn = t3b_func(f, &scope);
    t3b_job *jobs = calloc(n, sizeof(t3b_job));
    pthread_t *th = calloc(n, sizeof(pthread_t));
    for (zend_long i = 0; i < n; i++) {
        jobs[i].func = fn; jobs[i].scope = scope; jobs[i].mode = (int) mode; jobs[i].idx = (int) i;
        jobs[i].pfn = EG(function_table); jobs[i].pcl = EG(class_table); jobs[i].map_last = CG(map_ptr_last);
        pthread_create(&th[i], NULL, t3b_worker, &jobs[i]);
    }
    /* the starting request keeps running the same code meanwhile */
    for (zend_long k = 0; k < loops; k++) {
        zval arg0, ret; ZVAL_LONG(&arg0, 1000 + k);
        call_user_function(NULL, NULL, f, &ret, 1, &arg0);
        zval_ptr_dtor(&ret);
        if (EG(exception)) break;
    }
    array_init(return_value);
    for (zend_long i = 0; i < n; i++) {
        pthread_join(th[i], NULL);
        add_next_index_string(return_value, jobs[i].out ? jobs[i].out : "ERR none");
        free(jobs[i].out);
    }
    free(jobs); free(th);
}

PHP_FUNCTION(t3b_cost)
{
    zval *f; zend_long mode, n;
    ZEND_PARSE_PARAMETERS_START(3, 3)
        Z_PARAM_OBJECT_OF_CLASS(f, zend_ce_closure) Z_PARAM_LONG(mode) Z_PARAM_LONG(n)
    ZEND_PARSE_PARAMETERS_END();
    zend_class_entry *scope; zend_function *fn = t3b_func(f, &scope);
    struct timespec a, b;
    clock_gettime(CLOCK_MONOTONIC, &a);
    for (zend_long i = 0; i < n; i++) {
        t3b_job j = {fn, scope, EG(function_table), EG(class_table), (int) mode, (int) i, CG(map_ptr_last), NULL};
        pthread_t t; pthread_create(&t, NULL, t3b_worker, &j); pthread_join(t, NULL);
        free(j.out);
    }
    clock_gettime(CLOCK_MONOTONIC, &b);
    if (getenv("T3B_TIME")) {
        fprintf(stderr, "  phases (us/start): ts_resource %.1f, request_startup %.1f, share+call %.1f, request_shutdown %.1f, ts_free_thread %.1f\n",
            t3b_ph[0] / n, t3b_ph[1] / n, t3b_ph[2] / n, t3b_ph[3] / n, t3b_ph[4] / n);
        memset(t3b_ph, 0, sizeof t3b_ph);
    }
    RETURN_DOUBLE(((b.tv_sec - a.tv_sec) * 1e6 + (b.tv_nsec - a.tv_nsec) / 1e3) / (double) n);
}

ZEND_BEGIN_ARG_INFO_EX(ai_run, 0, 0, 4)
    ZEND_ARG_INFO(0, f) ZEND_ARG_INFO(0, mode) ZEND_ARG_INFO(0, n) ZEND_ARG_INFO(0, loops)
ZEND_END_ARG_INFO()
ZEND_BEGIN_ARG_INFO_EX(ai_cost, 0, 0, 3)
    ZEND_ARG_INFO(0, f) ZEND_ARG_INFO(0, mode) ZEND_ARG_INFO(0, n)
ZEND_END_ARG_INFO()
static const zend_function_entry t3b_fns[] = {
    PHP_FE(t3b_run, ai_run) PHP_FE(t3b_cost, ai_cost) PHP_FE_END
};
/* a SIGSEGV report: the faulting pc, lr and frame chain, and /proc/self/maps,
 * for addr2line (gdb cannot read this VM's registers) */
#include <signal.h>
#include <ucontext.h>
#include <fcntl.h>
#include <unistd.h>
static void t3b_segv(int sig, siginfo_t *si, void *uc_)
{
    ucontext_t *uc = uc_;
    char b[256]; int n;
#if defined(__aarch64__)
    unsigned long pc = uc->uc_mcontext.pc, lr = uc->uc_mcontext.regs[30], fp = uc->uc_mcontext.regs[29];
#else
    unsigned long pc = uc->uc_mcontext.gregs[REG_RIP], lr = 0, fp = uc->uc_mcontext.gregs[REG_RBP];
#endif
    n = snprintf(b, sizeof b, "SEGV addr=%p pc=%lx lr=%lx\n", si->si_addr, pc, lr); write(2, b, n);
    for (int k = 0; k < 16 && fp; k++) {
        unsigned long *f = (unsigned long *) fp;
        n = snprintf(b, sizeof b, "  frame %lx\n", f[1]); write(2, b, n);
        fp = f[0];
    }
    int fd = open("/proc/self/maps", O_RDONLY);
    while ((n = read(fd, b, sizeof b)) > 0) write(2, b, n);
    _exit(139);
}
static PHP_MINIT_FUNCTION(t3b) {
    if (getenv("T3B_SEGV")) { struct sigaction sa = {0}; sa.sa_sigaction = t3b_segv; sa.sa_flags = SA_SIGINFO; sigaction(SIGSEGV, &sa, NULL); }
    return SUCCESS;
}
static PHP_RINIT_FUNCTION(t3b) { ZEND_TSRMLS_CACHE_UPDATE(); return SUCCESS; }
zend_module_entry t3b_module_entry = {
    STANDARD_MODULE_HEADER, "t3b", t3b_fns, PHP_MINIT(t3b), NULL, PHP_RINIT(t3b), NULL, NULL, "0.1", STANDARD_MODULE_PROPERTIES
};
ZEND_GET_MODULE(t3b)

// awaitable -- a php extension written only in mc.
//
//   $a = \awaitable\await($callable, ...$args);   // suspends, runs, returns
//   $a->failed / $a->exception / $a->data
//
// There is no async here, so await does what await does: it suspends and runs
// to completion. It ALWAYS hands back an Intent -- the envelope is the wide
// type, never narrowed to the callable's own value.
// The parallelism lives inside a native callable: http_get_many() fetches every
// url on its own OS thread and returns when all of them are in. That is exactly
// the shape a #[Thread]-marked php function will compile to.
// Sync: \awaitable\Semaphore (bind() caps concurrency), WaitGroup, Mutex.
#include <prelude>

extern uptr dlsym(i64 h, uptr name);
extern uptr malloc(i64 n);
extern uptr realloc(uptr p, i64 n);
extern void free(uptr p);
extern uptr memcpy(uptr d, uptr s, i64 n);

extern i32 pthread_create(uptr tid, uptr attr, uptr fn, uptr arg);
extern i32 pthread_join(uptr tid, uptr ret);
extern i32 pthread_mutex_init(uptr m, uptr attr);
extern i32 pthread_mutex_lock(uptr m);
extern i32 pthread_mutex_unlock(uptr m);
extern i32 pthread_cond_init(uptr c, uptr attr);
extern i32 pthread_cond_wait(uptr c, uptr m);
extern i32 pthread_cond_signal(uptr c);
extern i32 pthread_cond_broadcast(uptr c);

extern i32 curl_global_init(i64 f);
extern uptr curl_easy_init();
extern i32 curl_easy_setopt(uptr h, i64 o, i64 a, i64 b, i64 c, i64 d, i64 e, i64 f, uptr v);
extern i32 curl_easy_perform(uptr h);
extern i32 curl_easy_getinfo(uptr h, i64 i, i64 a, i64 b, i64 c, i64 d, i64 e, i64 f, uptr o);
extern void curl_easy_cleanup(uptr h);
extern uptr curl_easy_strerror(i64 code);

extern void zend_type_error(uptr fmt);
extern void zend_argument_count_error(uptr fmt);
extern void zend_throw_exception(uptr ce, uptr msg, i64 code);
extern uptr zend_register_internal_class(uptr ce);
extern void zend_declare_property_bool(uptr ce, uptr n, i64 l, i64 v, i64 fl);
extern void zend_declare_property_long(uptr ce, uptr n, i64 l, i64 v, i64 fl);
extern void zend_declare_property_null(uptr ce, uptr n, i64 l, i64 fl);
extern void zend_update_property_bool(uptr ce, uptr o, uptr n, i64 l, i64 v);
extern void zend_update_property_long(uptr ce, uptr o, uptr n, i64 l, i64 v);
extern void zend_update_property_stringl(uptr ce, uptr o, uptr n, i64 l, uptr s, i64 sl);
extern void zend_update_property(uptr ce, uptr o, uptr n, i64 l, uptr z);
extern uptr zend_read_property(uptr ce, uptr o, uptr n, i64 l, i64 s, uptr rv);
extern void object_init_ex(uptr z, uptr ce);
extern void zval_ptr_dtor(uptr z);
extern uptr _emalloc(i64 n);
extern uptr _zend_new_array(i64 size);
extern uptr zend_hash_next_index_insert(uptr ht, uptr zv);
extern i32 fork();
extern i32 pipe(uptr fds);
extern i64 read(i32 fd, uptr buf, i64 n);
extern i64 write(i32 fd, uptr buf, i64 n);
extern i32 close(i32 fd);
extern i32 waitpid(i32 pid, uptr st, i32 opt);
extern void _exit(i32 c);
extern i32 zend_fcall_info_init(uptr c, i64 fl, uptr fci, uptr fcc, uptr nm, uptr er);
extern i32 zend_call_function(uptr fci, uptr fcc);

#define RTLD_DEFAULT (0 - 2)
#define EG_EXCEPTION 960
#define CE_SIZE 520
#define OH_SIZE 208
#define IS_LONG 4
#define IS_STRING 6
#define IS_OBJECT 8
#define IS_OBJECT_EX 0x308
#define IS_ARRAY_EX 0x307
#define IS_STRING_EX 0x106
#define ZSTR_TYPE_INFO 0x16   // IS_STRING | GC_NOT_COLLECTABLE, measured
#define ACC_PUBLIC 1
#define OBJ_HANDLE 8

#define CURLOPT_URL 10002
#define CURLOPT_WRITEFUNCTION 20011
#define CURLOPT_WRITEDATA 10001
#define CURLOPT_FOLLOWLOCATION 52
#define CURLOPT_TIMEOUT 13
#define CURLOPT_NOSIGNAL 99
#define CURLINFO_RESPONSE_CODE 2097154

#define M_SIZE 64
#define SEM_M 0
#define SEM_C 64
#define SEM_N 112
#define SEM_SIZE 128

#define JOB_TID 0
#define JOB_URL 8
#define JOB_BUF 16
#define JOB_LEN 24
#define JOB_CODE 32
#define JOB_ERR 40
#define JOB_JOINED 48
#define JOB_SIZE 56
#define NSLOT 256

u64 mod[21]; u64 fns[60];   // 7 entries + the zeroed terminator, 48 B each
u64 ai_await[12]; u64 ai_one[8]; u64 ai_none[4];
u64 ce_intent; u64 ce_sem; u64 ce_wg; u64 ce_mx;
u64 ce_buf[65]; u64 msem[40]; u64 mwg[40]; u64 mmx[28];
u64 eg; u64 exc_ce; u64 sip; u64 hnd;
u64 live; u64 peak; u64 done_n; u64 errn; u64 statm[8];
u64 oh[26]; u64 std_rp; u64 std_gp; u64 std_hp; u64 std_free;
u64 gsem; u64 gwg[16];
u64 tbl_h[256]; u64 tbl_j[256]; u64 tblm[8];
u64 th_get;

void zero(uptr p, i64 n) { i64 i = 0; while (i < n) { st8(p + i, 0); i = i + 1; } }

// --- semaphore and wait group: mutex + condvar, one shape for every OS -----
void sync_init(uptr s) { pthread_mutex_init(s + SEM_M, 0); pthread_cond_init(s + SEM_C, 0); }
void sem_acquire(uptr s) {
    pthread_mutex_lock(s + SEM_M);
    while (ld64(s + SEM_N) <= 0) { pthread_cond_wait(s + SEM_C, s + SEM_M); }
    st64(s + SEM_N, ld64(s + SEM_N) - 1);
    pthread_mutex_unlock(s + SEM_M);
}
void sem_release(uptr s) {
    pthread_mutex_lock(s + SEM_M);
    st64(s + SEM_N, ld64(s + SEM_N) + 1);
    pthread_cond_signal(s + SEM_C); pthread_mutex_unlock(s + SEM_M);
}
void wg_add(uptr w, i64 n) {
    pthread_mutex_lock(w + SEM_M); st64(w + SEM_N, ld64(w + SEM_N) + n);
    pthread_mutex_unlock(w + SEM_M);
}
void wg_done(uptr w) {
    pthread_mutex_lock(w + SEM_M); st64(w + SEM_N, ld64(w + SEM_N) - 1);
    if (ld64(w + SEM_N) <= 0) { pthread_cond_broadcast(w + SEM_C); }
    pthread_mutex_unlock(w + SEM_M);
}
void wg_wait(uptr w) {
    pthread_mutex_lock(w + SEM_M);
    while (ld64(w + SEM_N) > 0) { pthread_cond_wait(w + SEM_C, w + SEM_M); }
    pthread_mutex_unlock(w + SEM_M);
}

// --- the worker: native only, it never touches a php structure -------------
i64 sink(uptr p, i64 size, i64 n, uptr job) {
    i64 got = size * n; i64 len = ld64(job + JOB_LEN);
    uptr b = realloc(ld64(job + JOB_BUF), len + got + 1);
    if (b == 0) { return 0; }
    memcpy(b + len, p, got); st8(b + len + got, 0);
    st64(job + JOB_BUF, b); st64(job + JOB_LEN, len + got);
    return got;
}
void http_do(uptr job) {
    uptr h = curl_easy_init();
    if (h == 0) { st64(job + JOB_ERR, 2); return; }
    curl_easy_setopt(h, CURLOPT_URL, 0,0,0,0,0,0, ld64(job + JOB_URL));
    curl_easy_setopt(h, CURLOPT_WRITEFUNCTION, 0,0,0,0,0,0, &sink);
    curl_easy_setopt(h, CURLOPT_WRITEDATA, 0,0,0,0,0,0, job);
    curl_easy_setopt(h, CURLOPT_FOLLOWLOCATION, 0,0,0,0,0,0, 1);
    curl_easy_setopt(h, CURLOPT_TIMEOUT, 0,0,0,0,0,0, 30);
    curl_easy_setopt(h, CURLOPT_NOSIGNAL, 0,0,0,0,0,0, 1);
    st64(job + JOB_ERR, curl_easy_perform(h));
    u8 c8[8]; uptr c = &c8; st64(c, 0);
    curl_easy_getinfo(h, CURLINFO_RESPONSE_CODE, 0,0,0,0,0,0, c);
    st64(job + JOB_CODE, ld64(c));
    curl_easy_cleanup(h);
}
uptr worker(uptr job) {
    uptr s = ld64(&gsem);
    if (s != 0) { sem_acquire(s); }
    pthread_mutex_lock(&statm);
    st64(&live, ld64(&live) + 1);
    if (ld64(&live) > ld64(&peak)) { st64(&peak, ld64(&live)); }
    pthread_mutex_unlock(&statm);
    http_do(job);
    pthread_mutex_lock(&statm);
    st64(&live, ld64(&live) - 1); st64(&done_n, ld64(&done_n) + 1);
    pthread_mutex_unlock(&statm);
    if (s != 0) { sem_release(s); }
    wg_done(&gwg);
    return 0;
}

// --- one job, start to finish, on a thread of its own --------------------
uptr run_job(uptr url) {
    uptr job = malloc(JOB_SIZE); zero(job, JOB_SIZE);
    st64(job + JOB_URL, url);
    wg_add(&gwg, 1);
    if (pthread_create(job + JOB_TID, 0, &worker, job) != 0) {
        wg_done(&gwg); st64(job + JOB_ERR, 2); st64(job + JOB_JOINED, 1);
    }
    return job;
}
void join_job(uptr job) {
    if (ld64(job + JOB_JOINED) == 0) { pthread_join(ld64(job + JOB_TID), 0); st64(job + JOB_JOINED, 1); }
}

void throw_msg(uptr msg) {
    // exc_ce holds the ADDRESS of zend_ce_exception, which is itself a pointer:
    // two loads, and the second one late, because the engine fills it at startup.
    zend_throw_exception(ld64(ld64(&exc_ce)), msg, 0);
}

void take_exception(uptr obj) {
    uptr e = ld64(ld64(&eg) + EG_EXCEPTION);
    if (e == 0) { return; }
    st64(ld64(&eg) + EG_EXCEPTION, 0);
    u8 z[16]; uptr p = &z; st64(p, e); st64(p + 8, IS_OBJECT_EX);
    zend_update_property(ld64(&ce_intent), obj, "exception", 9, p);
    zval_ptr_dtor(p);
}

// zend_string_alloc is inline and unexported, so the header is laid by hand.
uptr mkstr(uptr bytes, i64 l) {
    uptr zs = _emalloc(24 + l + 1);
    st32(zs + 0, 1); st32(zs + 4, ZSTR_TYPE_INFO); st64(zs + 8, 0); st64(zs + 16, l);
    if (l > 0) { memcpy(zs + 24, bytes, l); }
    st8(zs + 24 + l, 0);
    return zs;
}

// --- awaitable\http_get: the threadable callable --------------------------
uptr dup_zstr(uptr zv) {
    uptr zs = ld64(zv); i64 l = ld64(zs + 16);
    uptr p = malloc(l + 1); memcpy(p, zs + 24, l); st8(p + l, 0);
    return p;
}
void zif_http_get(uptr ex, uptr rv) {
    if (ld32(ex + 44) < 1) { zend_argument_count_error("awaitable\\http_get() expects exactly 1 argument, 0 given"); return; }
    if (ld8(ex + 88) != IS_STRING) { zend_type_error("awaitable\\http_get(): Argument #1 ($url) must be of type string"); return; }
    uptr job = run_job(dup_zstr(ex + 80));
    join_job(job);
    if (ld64(job + JOB_ERR) != 0) {
        throw_msg(curl_easy_strerror(ld64(job + JOB_ERR)));
    }
    if (ld64(job + JOB_ERR) == 0) {
        st64(rv, mkstr(ld64(job + JOB_BUF), ld64(job + JOB_LEN))); st32(rv + 8, IS_STRING_EX);
    }
    free(ld64(job + JOB_BUF)); free(ld64(job + JOB_URL)); free(job);
}

// http_get_many(string ...$urls): array -- every url on its own thread, and it
// returns when the last one is in. This is where the parallelism lives.
u64 jobs[64];
void zif_http_get_many(uptr ex, uptr rv) {
    i64 n = ld32(ex + 44);
    if (n < 1) { zend_argument_count_error("awaitable\\http_get_many() expects at least 1 argument, 0 given"); return; }
    if (n > 64) { zend_type_error("awaitable\\http_get_many(): at most 64 urls"); return; }
    i64 i = 0;
    while (i < n) {
        uptr z = ex + 80 + i * 16;
        if (ld8(z + 8) != IS_STRING) { zend_type_error("awaitable\\http_get_many(): every argument must be a string"); return; }
        st64(&jobs + i * 8, run_job(dup_zstr(z)));
        i = i + 1;
    }
    uptr ht = _zend_new_array(n);
    i = 0;
    while (i < n) {
        uptr job = ld64(&jobs + i * 8);
        join_job(job);
        u8 zb[16]; uptr z = &zb;
        if (ld64(job + JOB_ERR) == 0) {
            st64(z, mkstr(ld64(job + JOB_BUF), ld64(job + JOB_LEN))); st32(z + 8, IS_STRING_EX);
        }
        if (ld64(job + JOB_ERR) != 0) { st64(z, 0); st32(z + 8, 1); }   // IS_NULL for a url that failed
        zend_hash_next_index_insert(ht, z);
        free(ld64(job + JOB_BUF)); free(ld64(job + JOB_URL)); free(job);
        i = i + 1;
    }
    st64(rv, ht); st32(rv + 8, IS_ARRAY_EX);
}

// --- any php callable, off the main line, one process per job ------------
// The interpreter is not reentrant, so an INTERPRETED body cannot share a
// thread with the main one. A child process can: it is a full copy of the
// interpreter, so ANY callable works -- closure, method, named function -- and
// the body is never compiled. The value comes home through php's own
// serialize/unserialize over a pipe, which is also what bounds it: only what
// serialize accepts crosses back, and nothing the child mutates is shared.
i64 call_fn(uptr zfn, uptr zargs, i64 nargs, uptr out) {
    u8 fcib[64]; u8 fccb[40]; u8 errb[8];
    uptr f = &fcib; uptr c = &fccb; uptr e = &errb;
    zero(f, 64); zero(c, 40); zero(e, 8); zero(out, 16);
    if (zend_fcall_info_init(zfn, 0, f, c, 0, e) != 0) { return 2; }
    st64(f + 24, out); st64(f + 32, zargs); st32(f + 48, nargs);
    zend_call_function(f, c);
    if (ld64(ld64(&eg) + EG_EXCEPTION) != 0) { return 1; }
    return 0;
}
uptr call_named(uptr name, i64 nl, uptr zarg, uptr out) {
    u8 zf[16]; uptr z = &zf;
    st64(z, mkstr(name, nl)); st32(z + 8, IS_STRING_EX);
    if (call_fn(z, zarg, 1, out) != 0) { return 0; }
    return out;
}
void write_all(i32 fd, uptr p, i64 n) {
    i64 off = 0;
    while (off < n) { i64 k = write(fd, p + off, n - off); if (k <= 0) { off = n; } if (k > 0) { off = off + k; } }
}
i64 read_all(i32 fd, uptr p, i64 n) {
    i64 off = 0;
    while (off < n) { i64 k = read(fd, p + off, n - off); if (k <= 0) { return off; } off = off + k; }
    return off;
}

u64 kid_pid[64]; u64 kid_fd[64];

void zif_parallel(uptr ex, uptr rv) {
    i64 n = ld32(ex + 44);
    if (n < 2) { zend_argument_count_error("awaitable\\parallel() expects at least 2 arguments"); return; }
    i64 nj = n - 1;
    if (nj > 64) { zend_type_error("awaitable\\parallel(): at most 64 jobs"); return; }
    uptr zfn = ex + 80;
    u8 lenb[16]; uptr lp = &lenb;

    i64 i = 0;
    while (i < nj) {
        u8 fdb[8]; uptr fd = &fdb;
        if (pipe(fd) != 0) { st64(&kid_pid + i * 8, 0 - 1); i = i + 1; }
        if (ld64(&kid_pid + i * 8) != (0 - 1)) {
            i32 rfd = ld32(fd); i32 wfd = ld32(fd + 4);
            i32 pid = fork();
            if (pid == 0) {
                close(rfd);
                u8 outb[16]; uptr out = &outb;
                i64 st = call_fn(zfn, ex + 96 + i * 16, 1, out);
                u8 tagb[1]; uptr tg = &tagb;
                if (st == 0) {
                    uptr zs = 0;
                    u8 sb[16]; uptr sv = &sb;
                    if (call_named("serialize", 9, out, sv) != 0) { if (ld8(sv + 8) == IS_STRING) { zs = ld64(sv); } }
                    if (zs == 0) { st8(tg, 1); write_all(wfd, tg, 1); st64(lp, 0); write_all(wfd, lp, 8); _exit(0); }
                    st8(tg, 0); write_all(wfd, tg, 1);
                    st64(lp, ld64(zs + 16)); write_all(wfd, lp, 8);
                    write_all(wfd, zs + 24, ld64(zs + 16));
                    _exit(0);
                }
                // the callable threw: send the message back, not the object
                uptr e = ld64(ld64(&eg) + EG_EXCEPTION);
                st64(ld64(&eg) + EG_EXCEPTION, 0);
                st8(tg, 1); write_all(wfd, tg, 1);
                i64 ml = 0; uptr mp = 0;
                if (e != 0) {
                    u8 rvb[16]; uptr rr = &rvb;
                    uptr z = zend_read_property(ld64(ld64(&exc_ce)), e, "message", 7, 1, rr);
                    if (z != 0) { if (ld8(z + 8) == IS_STRING) { ml = ld64(ld64(z) + 16); mp = ld64(z) + 24; } }
                }
                st64(lp, ml); write_all(wfd, lp, 8);
                if (ml > 0) { write_all(wfd, mp, ml); }
                _exit(0);
            }
            close(wfd);
            st64(&kid_pid + i * 8, pid); st64(&kid_fd + i * 8, rfd);
        }
        i = i + 1;
    }

    uptr ht = _zend_new_array(nj);
    i = 0;
    while (i < nj) {
        i32 rfd = ld64(&kid_fd + i * 8);
        u8 tagb[1]; uptr tg = &tagb; st8(tg, 1);
        i64 len = 0;
        if (read_all(rfd, tg, 1) == 1) { if (read_all(rfd, lp, 8) == 8) { len = ld64(lp); } }
        uptr buf = 0;
        if (len > 0) { buf = malloc(len + 1); if (read_all(rfd, buf, len) != len) { len = 0; } }
        close(rfd);
        u8 stb[8]; waitpid(ld64(&kid_pid + i * 8), &stb, 0);

        u8 zb[16]; uptr z = &zb; st64(z, 0); st32(z + 8, 1);   // IS_NULL by default
        if (ld8(tg) == 0) {
            if (len > 0) {
                u8 sb[16]; uptr sv = &sb; st64(sv, mkstr(buf, len)); st32(sv + 8, IS_STRING_EX);
                u8 ob[16]; uptr ov = &ob;
                if (call_named("unserialize", 11, sv, ov) != 0) { memcpy(z, ov, 16); }
            }
        }
        if (ld8(tg) != 0) {
            st64(&errn, ld64(&errn) + 1);
            if (len > 0) { st64(z, mkstr(buf, len)); st32(z + 8, IS_STRING_EX); }
        }
        if (buf != 0) { free(buf); }
        zend_hash_next_index_insert(ht, z);
        i = i + 1;
    }
    st64(rv, ht); st32(rv + 8, IS_ARRAY_EX);
}

// --- await(callable, ...$args): suspends, runs, hands back the Intent -----
void zif_await(uptr ex, uptr rv) {
    i64 n = ld32(ex + 44);
    if (n < 1) { zend_argument_count_error("awaitable\\await() expects at least 1 argument, 0 given"); return; }
    u8 fcib[64]; u8 fccb[40]; u8 errb[8]; u8 rzb[16];
    uptr f = &fcib; uptr c = &fccb; uptr epp = &errb; uptr r = &rzb;
    zero(f, 64); zero(c, 40); zero(epp, 8); zero(r, 16);
    if (zend_fcall_info_init(ex + 80, 0, f, c, 0, epp) != 0) {
        zend_type_error("awaitable\\await(): Argument #1 ($fn) must be a valid callback");
        return;
    }
    object_init_ex(rv, ld64(&ce_intent));
    uptr obj = ld64(rv);

    st64(f + 24, r); st64(f + 32, ex + 96); st32(f + 48, n - 1);
    zend_call_function(f, c);

    zend_update_property_bool(ld64(&ce_intent), obj, "done", 4, 1);
    if (ld64(ld64(&eg) + EG_EXCEPTION) != 0) {
        zend_update_property_bool(ld64(&ce_intent), obj, "failed", 6, 1);
        take_exception(obj);
        return;
    }
    zend_update_property_bool(ld64(&ce_intent), obj, "failed", 6, 0);
    zend_update_property(ld64(&ce_intent), obj, "data", 4, r);
    zval_ptr_dtor(r);
}

uptr this_of(uptr ex) { return ld64(ex + 32); }
i64 handle_of(uptr ce, uptr o) {
    u8 rvb[16]; uptr rr = &rvb;
    uptr z = zend_read_property(ce, o, "__h", 3, 1, rr);
    if (z == 0) { return 0; }
    return ld64(z);
}
void m_sem_ctor(uptr ex, uptr rv) {
    i64 k = 1; if (ld32(ex + 44) >= 1) { k = ld64(ex + 80); }
    uptr s = malloc(SEM_SIZE); zero(s, SEM_SIZE); sync_init(s); st64(s + SEM_N, k);
    zend_update_property_long(ld64(&ce_sem), this_of(ex), "__h", 3, s);
}
void m_sem_acq(uptr ex, uptr rv) { sem_acquire(handle_of(ld64(&ce_sem), this_of(ex))); }
void m_sem_rel(uptr ex, uptr rv) { sem_release(handle_of(ld64(&ce_sem), this_of(ex))); }
void m_sem_bind(uptr ex, uptr rv)   { st64(&gsem, handle_of(ld64(&ce_sem), this_of(ex))); }
void m_sem_unbind(uptr ex, uptr rv) { st64(&gsem, 0); }

void m_wg_ctor(uptr ex, uptr rv) {
    uptr w = malloc(SEM_SIZE); zero(w, SEM_SIZE); sync_init(w);
    zend_update_property_long(ld64(&ce_wg), this_of(ex), "__h", 3, w);
}
void m_wg_add(uptr ex, uptr rv) {
    i64 k = 1; if (ld32(ex + 44) >= 1) { k = ld64(ex + 80); }
    wg_add(handle_of(ld64(&ce_wg), this_of(ex)), k);
}
void m_wg_done(uptr ex, uptr rv) { wg_done(handle_of(ld64(&ce_wg), this_of(ex))); }
void m_wg_wait(uptr ex, uptr rv) { wg_wait(handle_of(ld64(&ce_wg), this_of(ex))); }

void m_mx_ctor(uptr ex, uptr rv) {
    uptr m = malloc(M_SIZE); zero(m, M_SIZE); pthread_mutex_init(m, 0);
    zend_update_property_long(ld64(&ce_mx), this_of(ex), "__h", 3, m);
}
void m_mx_lock(uptr ex, uptr rv)   { pthread_mutex_lock(handle_of(ld64(&ce_mx), this_of(ex))); }
void m_mx_unlock(uptr ex, uptr rv) { pthread_mutex_unlock(handle_of(ld64(&ce_mx), this_of(ex))); }

void zif_peak(uptr ex, uptr rv)  { st64(rv, ld64(&peak));   st32(rv + 8, IS_LONG); }
void zif_cmpl(uptr ex, uptr rv)  { st64(rv, ld64(&done_n)); st32(rv + 8, IS_LONG); }
void zif_reset(uptr ex, uptr rv) { st64(&peak, 0); st64(&done_n, 0); st64(&errn, 0); }
void zif_errs(uptr ex, uptr rv) { st64(rv, ld64(&errn)); st32(rv + 8, IS_LONG); }
void zif_waitall(uptr ex, uptr rv) { wg_wait(&gwg); }

uptr mkclass(uptr name, i64 nl, uptr methods) {
    uptr ce = &ce_buf; zero(ce, CE_SIZE);
    st64(ce + 8, callp(ld64(ld64(&sip)), name, nl, 1));
    st64(ce + 360, ld64(&hnd));
    st64(ce + 504, methods);
    return zend_register_internal_class(ce);
}
void ent(uptr fe, i64 i, uptr name, uptr h, uptr ai, i64 na, i64 fl) {
    uptr e = fe + i * 48;
    st64(e + 0, name); st64(e + 8, h); st64(e + 16, ai);
    st32(e + 24, na); st32(e + 28, fl);
}

i64 minit(i64 ty, i64 num) {
    st64(&eg, dlsym(RTLD_DEFAULT, "executor_globals"));
    st64(&sip, dlsym(RTLD_DEFAULT, "zend_string_init_interned"));
    st64(&hnd, dlsym(RTLD_DEFAULT, "std_object_handlers"));
    st64(&exc_ce, dlsym(RTLD_DEFAULT, "zend_ce_exception"));
    curl_global_init(3);
    pthread_mutex_init(&statm, 0); sync_init(&gwg);

    uptr m = &msem;
    ent(m, 0, "__construct", &m_sem_ctor, &ai_one,  1, ACC_PUBLIC);
    ent(m, 1, "acquire", &m_sem_acq,  &ai_none, 0, ACC_PUBLIC);
    ent(m, 2, "release", &m_sem_rel,  &ai_none, 0, ACC_PUBLIC);
    ent(m, 3, "bind",    &m_sem_bind, &ai_none, 0, ACC_PUBLIC);
    ent(m, 4, "unbind",  &m_sem_unbind, &ai_none, 0, ACC_PUBLIC);
    st64(&ce_sem, mkclass("awaitable\\Semaphore", 19, m));
    zend_declare_property_long(ld64(&ce_sem), "__h", 3, 0, ACC_PUBLIC);

    uptr w = &mwg;
    ent(w, 0, "__construct", &m_wg_ctor, &ai_none, 0, ACC_PUBLIC);
    ent(w, 1, "add",  &m_wg_add,  &ai_one,  1, ACC_PUBLIC);
    ent(w, 2, "done", &m_wg_done, &ai_none, 0, ACC_PUBLIC);
    ent(w, 3, "wait", &m_wg_wait, &ai_none, 0, ACC_PUBLIC);
    st64(&ce_wg, mkclass("awaitable\\WaitGroup", 19, w));
    zend_declare_property_long(ld64(&ce_wg), "__h", 3, 0, ACC_PUBLIC);

    uptr x = &mmx;
    ent(x, 0, "__construct", &m_mx_ctor, &ai_none, 0, ACC_PUBLIC);
    ent(x, 1, "lock",   &m_mx_lock,   &ai_none, 0, ACC_PUBLIC);
    ent(x, 2, "unlock", &m_mx_unlock, &ai_none, 0, ACC_PUBLIC);
    st64(&ce_mx, mkclass("awaitable\\Mutex", 15, x));
    zend_declare_property_long(ld64(&ce_mx), "__h", 3, 0, ACC_PUBLIC);

    st64(&ce_intent, mkclass("awaitable\\Intent", 16, 0));
    uptr ci = ld64(&ce_intent);
    zend_declare_property_bool(ci, "done", 4, 0, ACC_PUBLIC);
    zend_declare_property_bool(ci, "failed", 6, 0, ACC_PUBLIC);
    zend_declare_property_null(ci, "exception", 9, ACC_PUBLIC);
    zend_declare_property_null(ci, "data", 4, ACC_PUBLIC);

    return 0;
}

uptr get_module() {
    uptr a = &ai_await; st64(a + 0, 1); st64(a + 32, "fn");
    st64(a + 64, "args"); st32(a + 64 + 16, 0x08000000);
    uptr c = &ai_one;  st64(c + 0, 1); st64(c + 32, "n");
    uptr d = &ai_none; st64(d + 0, 0);
    uptr g = &ai_one;  // http_get(string $url) reuses the one-arg shape

    uptr fe = &fns;
    ent(fe, 0, "awaitable\\await", &zif_await, a, 2, 0);
    ent(fe, 1, "awaitable\\http_get", &zif_http_get, g, 1, 0);
    ent(fe, 2, "awaitable\\http_get_many", &zif_http_get_many, a, 2, 0);
    ent(fe, 3, "awaitable\\peak", &zif_peak, d, 0, 0);
    ent(fe, 4, "awaitable\\completed", &zif_cmpl, d, 0, 0);
    ent(fe, 5, "awaitable\\reset", &zif_reset, d, 0, 0);
    ent(fe, 6, "awaitable\\wait_all", &zif_waitall, d, 0, 0);
    ent(fe, 7, "awaitable\\parallel", &zif_parallel, a, 2, 0);
    ent(fe, 8, "awaitable\\errors", &zif_errs, d, 0, 0);

    uptr m = &mod;
    st16(m + 0, 168); st32(m + 4, @API@);
    st8(m + 8, @DEBUG@); st8(m + 9, @ZTS@);
    st64(m + 32, "awaitable"); st64(m + 40, fe);
    st64(m + 48, &minit);
    st64(m + 88, "0.3.0"); st64(m + 160, "@BUILDID@");
    return m;
}

// php_zts.mc -- what an extension for a thread-safe php adds (src/program.mc
// pushes it only when the output is ZTS: [php].thread_safety = "zts", or the
// ZTS half of "both"). Nothing in the NTS output changes: the NTS module is
// byte for byte what it was before this file existed (measured with cmp over
// every NTS module this repository builds, macOS and Linux aarch64/x86_64:
// docs/php-extension.md § Thread safety).
//
// A thread-safe php runs requests on several threads at once, each with its
// own engine. The module keeps up (docs/threads.md § ZTS):
//
//   * each php thread has its own runtime block (lib/php_tls.mc), the
//     module's TSRM globals: php allocates one per thread (ts_allocate_id,
//     through zend_module_entry's globals_size/globals_id_ptr/globals_ctor/
//     globals_dtor), the module sets it up at the thread's first request and
//     releases it when php ends the thread (phx_ts_gdtor);
//   * the engine's globals are the calling thread's: tsrm_get_ls_cache() +
//     executor_globals_offset, taken on that thread;
//   * what a request may write and a C extension would keep per request --
//     the global variables, the constants, the class registry, a function's
//     statics, a class's static properties, a call site's cache -- is this
//     thread's, and each request starts from a COPY of what MINIT left
//     (phz_privatize), so no request ever writes what another thread reads.
//     MINIT's own memory is read by every thread and written by none.
//
// The runtime's other sources are the NTS ones with the swaps src/program.mc
// lists; the words above are lowered into the block by src/tls.mc.

#define E_CORE_ERROR 16
#define MEX_GLOBALS_SIZE    96
#define MEX_GLOBALS_ID_PTR  104
#define MEX_GLOBALS_CTOR    112
#define MEX_GLOBALS_DTOR    120

uptr phx_ts_get;                    // tsrm_get_ls_cache
uptr phx_ts_ls0;                    // the TSRM block of the thread that loaded the module
i64  phx_ts_ego;                    // executor_globals_offset's value
u8   phx_ts_id[8];                  // the module's TSRM resource id (an int php writes)
uptr phx_ts_minit0;                 // the module's own MINIT (mc_php_minit)
uptr phz_snap_area;                 // the statics as MINIT left them
// EG(exception)'s offset a thread starts from, until it measures its own:
// the headers' value, or -- MCPHP_ZTS_EGX_WRONG=1, a test's switch -- 456,
// EG(function_table) on php 8.5 Linux (aarch64 and x86_64, read off the ZTS
// headers with offsetof): never NULL in a request, so a thread that reads
// "an exception is pending" there without having measured is caught
// (tests/frankenphp.sh)
i64  phz_egx0;

// the runtime block of the php thread whose TSRM block is ls: the loading
// thread's is the one MINIT ran on, every other one is the module's TSRM
// storage, TSRMG_BULK(id) = (*(void ***) ls)[id - 1]
uptr phz_block_of(uptr ls) {
    if (ls == phx_ts_ls0) return ph_tmain;
    return ld64(ld64(ls) + (ld32(phx_ts_id) - 1) * 8);
}

// TSRM's constructor, on every thread's storage: empty, and set up at the
// thread's first request (phz_thread)
void phx_ts_gctor(uptr g) {
    i64 i = 0;
    loop { if (i >= PHT_SIZE) break; st64(g + i, 0); i = i + 8; }
}

// and its destructor, when php ends a thread (or unloads the module): the
// thread's arena and its words go; what a request allocated went with it
void phx_ts_gdtor(uptr g) {
    if (!ld64(g + PHT_phz_init)) return;
    ph_os_unmap(ld64(g + PHT_ph_hbase), ld64(g + PHT_ph_hlim));
    if (phz_area_size()) ph_os_unmap(ld64(g + PHT_phz_mod), phz_area_size());
    st64(g + PHT_phz_init, 0);
}

// The calling php thread's block, made the thread's slot. The first time a
// thread is seen: an arena of its own, its copy of the module's words, its
// engine's globals, the rows of the file table MINIT opened (the standard
// streams) and MINIT's roots.
uptr phz_thread() {
    uptr ls = callp(phx_ts_get);
    uptr b = phz_block_of(ls);
    ph_tset(b);
    if (b == ph_tmain || ld64(b + PHT_phz_init)) return b;
    uptr a = ph_os_map(ph_os_arena());
    if (!a) php_die("mc-php: cannot map a php thread's memory\n", 41);
    st64(b + PHT_ph_hbase, a);
    st64(b + PHT_ph_hlim, ph_os_arena());
    uptr m = 0;
    if (phz_area_size()) {
        m = ph_os_map(phz_area_size());
        if (!m) php_die("mc-php: cannot map a php thread's memory\n", 41);
        phz_area_init(m);
    }
    st64(b + PHT_phz_mod, m);
    st64(b + PHT_phx_eg, ls + phx_ts_ego);
    st64(b + PHT_phx_egx, phz_egx0);               // until this thread measures its own
    // php's output layer, as phx_module wired it on the main block: without
    // these two a module's echo on this thread would bypass every ob level
    st64(b + PHT_ph_osink, ld64(ph_tmain + PHT_ph_osink));
    st64(b + PHT_ph_obx, ld64(ph_tmain + PHT_ph_obx));
    i64 i = 0;
    loop {
        if (i >= ld64(ph_tmain + PHT_ph_nfh)) break;
        st64(b + PHT_ph_fh_fd + i * 8, ld64(ph_tmain + PHT_ph_fh_fd + i * 8));
        st64(b + PHT_ph_fh_eof + i * 8, ld64(ph_tmain + PHT_ph_fh_eof + i * 8));
        st64(b + PHT_ph_fh_own + i * 8, ld64(ph_tmain + PHT_ph_fh_own + i * 8));
        st64(b + PHT_ph_fh_name + i * 8, ld64(ph_tmain + PHT_ph_fh_name + i * 8));
        i = i + 1;
    }
    st64(b + PHT_phz_init, 1);
    php_roots(0);
    return b;
}

// mcphp_thread() (src/builtin.mc): this php thread's block, as a number
i64 phz_tid() { uptr phT = ph_tcur; if (!phT) phT = ph_tslow(); return phT; }

// ---- a copy of MINIT's module state, one per request ---------------------
// Arrays and objects are copied, strings are shared: a string MINIT built is
// module memory (ZS_MODULE, interned), never counted and never written. One
// identity map per copy, so a value two roots share is still one value in
// the copy, and a cycle ends. An engine object's proxy stays the proxy: the
// engine object is php's, and php owns its threading.
uptr phz_idmap(uptr from) {
    uptr phT = ph_tcur; if (!phT) phT = ph_tslow();
    uptr m = ld64(phT + PHT_phz_idm);
    i64 i = 0;
    loop {
        if (i >= ld64(phT + PHT_phz_idn)) break;
        if (ld64(m + i * 16) == from) return ld64(m + i * 16 + 8);
        i = i + 1;
    }
    return 0;
}
void phz_idadd(uptr from, uptr to) {
    uptr phT = ph_tcur; if (!phT) phT = ph_tslow();
    i64 n = ld64(phT + PHT_phz_idn);
    if (n == ld64(phT + PHT_phz_idc)) {
        i64 c = n * 2 + 32;
        uptr nm = php_alloc(c * 16);
        i64 i = 0;
        loop { if (i >= n * 2) break; st64(nm + i * 8, ld64(ld64(phT + PHT_phz_idm) + i * 8)); i = i + 1; }
        st64(phT + PHT_phz_idm, nm);
        st64(phT + PHT_phz_idc, c);
    }
    uptr m = ld64(phT + PHT_phz_idm);
    st64(m + n * 16, from);
    st64(m + n * 16 + 8, to);
    st64(phT + PHT_phz_idn, n + 1);
}

uptr phz_tcopy(uptr t);
uptr phz_ocopy(uptr o) {
    if (php_obj_ce(o) == phx_pce) return o;
    uptr c = phz_idmap(o);
    if (c) return c;
    c = php_alloc(OBJ_HDR);
    i64 i = 0;
    loop { if (i >= OBJ_HDR) break; st64(c + i, ld64(o + i)); i = i + 8; }
    phz_idadd(o, c);
    st64(c + 24, phz_tcopy(ld64(o + 24)));
    if (ld64(o + 32)) st64(c + 32, php_arr_copy(ld64(o + 32)));
    return c;
}
void phz_zcopy(uptr d, uptr s) {
    php_zv_cp(d, s);
    i64 t = php_zv_type(s);
    if (t == IS_ARRAY) st64(d, phz_tcopy(ld64(s)));
    if (t == IS_OBJECT) st64(d, phz_ocopy(ld64(s)));
}
uptr phz_tcopy(uptr src) {
    uptr a = php_arr_new(ld32(src + 32));
    i64 used = php_ht_used(src);
    i64 i = 0;
    loop {
        if (i >= used) break;
        uptr b = php_ht_bkt(src, i);
        if (ld8(b + 8) != IS_UNDEF) {
            uptr k = ld64(b + 24);
            uptr t = 0;
            if (k) t = php_ht_slotfor(a, php_str_hash(k), k);
            if (!k) t = php_arr_islot(a, ld64(b + 16));
            phz_zcopy(t, b);
        }
        i = i + 1;
    }
    st64(a + 40, ld64(src + 40));
    return a;
}
// a zval a pointer names (a global, a static): one copy per pointer
uptr phz_zref(uptr p) {
    if (!p) return 0;
    uptr c = phz_idmap(p);
    if (c) return c;
    c = php_zv_alloc();
    phz_idadd(p, c);
    phz_zcopy(c, p);
    return c;
}
// the global variable table: a name to a pointer to its zval
uptr phz_gcopy(uptr src) {
    uptr a = php_arr_new(ld32(src + 32));
    i64 used = php_ht_used(src);
    i64 i = 0;
    loop {
        if (i >= used) break;
        uptr b = php_ht_bkt(src, i);
        if (ld8(b + 8) != IS_UNDEF) {
            uptr k = ld64(b + 24);
            uptr t = php_ht_slotfor(a, php_str_hash(k), k);
            php_zv_cp(t, php_zlong(phz_zref(ld64(b))));
        }
        i = i + 1;
    }
    return a;
}

// a class's static properties in THIS request: its private table, made the
// first time the request needs one the copy did not already make
uptr phz_stab(uptr ce, i64 make) {
    uptr phT = ph_tcur; if (!phT) phT = ph_tslow();
    uptr m = ld64(phT + PHT_phz_sp);
    i64 n = ld64(phT + PHT_phz_spn);
    i64 i = 0;
    loop {
        if (i >= n) break;
        if (ld64(m + i * 16) == ce) return ld64(m + i * 16 + 8);
        i = i + 1;
    }
    if (!make) return ld64(ce + 32);
    php_pin();
    uptr nm = php_alloc((n + 1) * 16);
    i = 0;
    loop { if (i >= n * 2) break; st64(nm + i * 8, ld64(m + i * 8)); i = i + 1; }
    uptr t = phz_tcopy(ld64(ce + 32));
    st64(nm + n * 16, ce);
    st64(nm + n * 16 + 8, t);
    st64(phT + PHT_phz_sp, nm);
    st64(phT + PHT_phz_spn, n + 1);
    return t;
}

// lib/php_rt.mc's php_ce_sslot_s (renamed _nts in a ZTS build) with the
// class entry's table replaced by this request's copy of it
uptr php_ce_sslot_s(uptr ce, uptr name, uptr scope) {
    php_pin();                                // a static property is this request's state
    uptr c = ce;
    loop {
        if (!c) break;
        uptr b = php_ht_find(phz_stab(c, 0), php_str_hash(name), name);
        if (b) {
            if (!php_vis_ok(c, name, scope)) {
                php_vis_die(c, name, php_str_new("property", 8));
                return php_zv_alloc();
            }
            if (phz_stab(c, 0) == ld64(c + 32)) b = php_ht_find(phz_stab(c, 1), php_str_hash(name), name);
            return b;
        }
        c = ld64(c + 8);
    }
    return php_arr_sslot(phz_stab(ce, 1), name);
}

// The request's copy, at its start, in the request's own memory (a pinned
// call's: php frees it at the end of the request). The roots are what MINIT
// left: the last request put them back at its end (php_request_reset).
void phz_privatize() {
    uptr phT = ph_tcur; if (!phT) phT = ph_tslow();
    st64(phT + PHT_phz_idm, 0);
    st64(phT + PHT_phz_idn, 0);
    st64(phT + PHT_phz_idc, 0);
    st64(phT + PHT_phz_sp, 0);
    st64(phT + PHT_phz_spn, 0);
    if (ph_classes) ph_classes = php_arr_copy(ph_classes);
    if (ph_consts) ph_consts = phz_tcopy(ph_consts);
    if (ph_globals) ph_globals = phz_gcopy(ph_globals);
    if (phz_area_size()) phz_statics(ld64(phT + PHT_phz_mod), phz_snap_area);
    // every class with static properties gets its table now, so what the
    // request writes is never MINIT's
    if (!ph_classes) return;
    i64 used = php_ht_used(ph_classes);
    i64 i = 0;
    loop {
        if (i >= used) break;
        uptr b = php_ht_bkt(ph_classes, i);
        if (ld8(b + 8) != IS_UNDEF) {
            uptr ce = ld64(b);
            if (ld64(ce + 32)) { if (php_ht_used(ld64(ce + 32))) phz_stab(ce, 1); }
        }
        i = i + 1;
    }
}

// ---- the request's start and end, on its php thread ----------------------
// The copy is made inside a pinned call's context (phx_enter/phx_leave), whose
// memory php frees at the end of the request. A call's first entry measures
// EG(exception)'s offset by throwing one (phx_egx_find), which php cannot
// take outside a running script, so that waits for the first real call.
// Offset and flag are this thread's words (src/tls.mc): RINIT holds the
// measurement off by setting the flag in ITS block, and no other thread can
// read that value or write it back.
// the fast entry waits for EG(exception)'s offset to be measured (the swap
// src/program.mc makes in phx_enter): a call, not the global, because
// php_ext.mc names it before it declares it
i64 phx_egx_ok() { return phx_egx_done; }

i64 phx_ts_rinit(i64 mtype, i64 mnum) {
    uptr b = phz_thread();
    i64 egx = ld64(b + PHT_phx_egx_done);
    st64(b + PHT_phx_egx_done, 1);
    phx_enter();
    php_pin();
    phz_privatize();
    phx_leave();
    st64(b + PHT_phx_egx_done, egx);
    return 0;
}
i64 phx_ts_rshutdown(i64 mtype, i64 mnum) {
    phz_thread();
    return phx_rshutdown(mtype, mnum);
}

// MINIT's arena made read-only (MCPHP_ZTS_READONLY=1, a test's switch): any
// write this file missed faults on the spot instead of racing. Whole pages
// inside the arena's used part only; mprotect is looked up, so a php without
// it (Windows) just does not get the check.
void phz_readonly(uptr p, i64 n) {
    uptr mp = php_dlsym("mprotect");
    if (!mp) return;
    uptr lo = (p + 65535) / 65536 * 65536;
    uptr hi = (p + n) / 65536 * 65536;
    if (hi > lo) callp(mp, lo, hi - lo, 1);
}

// The module's MINIT, then what a ZTS module needs of it before a second
// thread can exist: the Closure class (made on first use in an NTS module,
// which here would write the shared registry from a request), MINIT's roots
// saved again with it, and the statics as MINIT left them.
i64 phx_ts_minit(i64 mtype, i64 mnum) {
    uptr phT = ph_tcur; if (!phT) phT = ph_tslow();
    i64 r = callp(phx_ts_minit0, mtype, mnum);
    if (!ph_ce_closure) ph_ce_closure = php_ce_new(php_str_new("Closure", 7));
    php_roots(1);
    i64 n = phz_area_size();
    if (n) {
        phz_snap_area = php_alloc(n);
        uptr a = ld64(phT + PHT_phz_mod);
        i64 i = 0;
        loop { if (i >= n) break; st64(phz_snap_area + i, ld64(a + i)); i = i + 8; }
    }
    uptr v = getenv("MCPHP_ZTS_READONLY");
    if (v) { if (ld8(v) == 49) phz_readonly(ph_heap, ld64(phT + PHT_ph_top)); }
    return r;
}

// get_module's last step (src/ext.mc). A php that does not export the two
// TSRM names is not a thread-safe php this module can serve: it is refused
// here, by name, from get_module (E_CORE_ERROR), never left to fault at its
// first request.
uptr phx_ts_module(uptr me) {
    phx_ts_get = php_dlsym("tsrm_get_ls_cache");
    uptr off = php_dlsym("executor_globals_offset");
    uptr miss = 0;
    if (!off) miss = "executor_globals_offset";
    if (!phx_ts_get) miss = "tsrm_get_ls_cache";
    if (miss) {
        uptr m = php_str_concat(php_str_new("mc-php: this ZTS extension needs php's ", 39),
                                php_str_new(miss, php_cstrlen(miss)));
        m = php_str_concat(m, php_str_new(", which this php does not export", 32));
        uptr ze = php_dlsym("zend_error");
        if (ze) callp(ze, E_CORE_ERROR, m + ZS_HDR);
        php_die("mc-php: this ZTS extension cannot run in this php\n", 50);
    }
    phx_ts_ego = ld64(off);
    phx_ts_ls0 = callp(phx_ts_get);
    // from here on several threads run the module: every function asks the
    // thread's slot, and the loading thread's slot is its block
    if (!ph_tkeyed) { ph_tinit(); ph_tkeyed = 1; }
    ph_tset(ph_tmain);
    ph_mt = 1;
    ph_tcur = 0;
    uptr phT = ph_tmain;
    phx_eg = phx_ts_ls0 + phx_ts_ego;
    phz_egx0 = EGX_EXCEPTION;
    uptr wv = getenv("MCPHP_ZTS_EGX_WRONG");
    if (wv) { if (ld8(wv) == 49) phz_egx0 = 456; }
    phx_egx = phz_egx0;
    if (phz_area_size()) {
        uptr a = php_alloc(phz_area_size());
        phz_area_init(a);
        st64(phT + PHT_phz_mod, a);
    }
    phx_ts_minit0 = ld64(me + MEX_MODULE_STARTUP);
    st64(me + MEX_MODULE_STARTUP, &phx_ts_minit);
    st64(me + MEX_REQUEST_STARTUP, &phx_ts_rinit);
    st64(me + MEX_REQUEST_SHUTDOWN, &phx_ts_rshutdown);
    st64(me + MEX_GLOBALS_SIZE, PHT_SIZE);
    st64(me + MEX_GLOBALS_ID_PTR, phx_ts_id);
    st64(me + MEX_GLOBALS_CTOR, &phx_ts_gctor);
    st64(me + MEX_GLOBALS_DTOR, &phx_ts_gdtor);
    return me;
}

// a thread the MODULE starts (lib/php_rt.mc's php_thr_block, renamed _nts in
// a ZTS build): the starter's block plus the words a ZTS build keeps there,
// which the thread shares: the request's module state is every thread's
// (threads step 3), and php's engine refuses another thread
uptr php_thr_block(uptr from, i64 idx) {
    uptr b = php_thr_block_nts(from, idx);
    st64(b + PHT_ph_globals, ld64(from + PHT_ph_globals));
    st64(b + PHT_ph_consts, ld64(from + PHT_ph_consts));
    st64(b + PHT_ph_classes, ld64(from + PHT_ph_classes));
    st64(b + PHT_ph_ce_closure, ld64(from + PHT_ph_ce_closure));
    st64(b + PHT_phz_mod, ld64(from + PHT_phz_mod));
    st64(b + PHT_phz_sp, ld64(from + PHT_phz_sp));
    st64(b + PHT_phz_spn, ld64(from + PHT_phz_spn));
    return b;
}

// ---- a php callable on a thread of its own (threads step 3b) ---------------
// mcphp_thread_start with a php callable -- a php closure, a function's name,
// an array callable, an invokable object -- in a ZTS module (docs/threads.md
// § 3b). The worker becomes a php thread: ts_resource_ex gives it TSRM
// storage, php_request_startup a request of its own (its own EG, CG, PG, SG,
// Zend heap, output layer, and this module's RINIT, so a FRESH copy of what
// MINIT left: phz_privatize). php_request_shutdown and ts_free_thread end
// both. What crosses between the two requests is copied through memory
// neither heap owns:
//
//   * the CODE is shared, by pointer: the starting request's user functions
//     and classes as they were at the start, added to the worker's tables.
//     That is safe only for opcache's immutable op_arrays, whose run-time
//     cache and statics live in per-thread ZEND_MAP_PTR slots (probes/t3b,
//     mode 3): the start refuses code opcache does not cache, by name;
//   * the closure gets a private run-time cache (ZEND_ACC_HEAP_RT_CACHE on
//     the worker's copy of its function);
//   * everything else is a VALUE copied: the arguments, the closure's
//     captured variables and bound $this, the result and a thrown
//     exception's class, message and code -- serialized out of one heap
//     (phz_sx_*) and rebuilt in the other (phz_dx_*). Only plain values
//     cross: see phz_uncopyable;
//   * the worker's output goes to a buffer of its own and is written into
//     the request's output at the join, in join order; a thread nobody joins
//     has it written when the request waits for it (php_thr_endall).
//
// The call runs as the worker request's one shutdown function: that is
// php's own call site with a bailout point (zend_try) an extension can reach
// without setjmp (docs/plan.md D7), so a fatal error in the worker ends the
// call and not the process. A trampoline -- an internal function whose
// handler is phz_tramp -- is what php calls there, so the callable itself
// runs under an internal frame and an uncaught exception stays in
// EG(exception) for the trampoline to copy.
//
// The code is not taken out of the worker's tables before its request
// ends: shutdown leaves an immutable function and class alone
// (destroy_op_array returns on a NULL refcount, destroy_zend_class on
// ZEND_ACC_IMMUTABLE) and frees the worker's own per-thread statics of
// them, which a removal would have leaked.

// php's names this road needs, looked up once: all of them exist only in a
// running php, several only in a thread-safe one
#define PHZ_TSRES      0
#define PHZ_TSFREE     1
#define PHZ_RSTART     2
#define PHZ_RSTOP      3
#define PHZ_PGO        4
#define PHZ_SGO        5
#define PHZ_CGO        6
#define PHZ_MAPEXT     7
#define PHZ_CECL       8
#define PHZ_MKCL       9
#define PHZ_PROPS      10
#define PHZ_HFIND      11
#define PHZ_HADD       12
#define PHZ_HEND       13
#define PHZ_HBACK      14
#define PHZ_OSTART     15
#define PHZ_OGET       16
#define PHZ_ODISC      17
#define PHZ_OEND       18
#define PHZ_OLEVEL     19
#define PHZ_SDADD      20
#define PHZ_SDCALL     21
#define PHZ_SDFREE     22
#define PHZ_UNWIND     23
#define PHZ_ZSHASH     24
#define PHZ_STDCLASS   25
#define PHZ_COUNT      26
u8   phz_s[200];
i64  phz_syms;                      // 0 not looked up, 1 every name found, 2 one missing
uptr phz_missing;

uptr phz_f(i64 i) { return ld64(phz_s + i * 8); }
void phz_sym(i64 i, uptr name) {
    uptr p = php_dlsym(name);
    st64(phz_s + i * 8, p);
    if (!p && !phz_missing) phz_missing = name;
}
// a ZEND_FASTCALL name: MSVC builds of php make it __vectorcall, whose
// export carries its argument bytes (src/win/php8ts.def says the same of the
// names php_ext.mc imports); anywhere else the plain name is found first
void phz_symv(i64 i, uptr name, uptr vname) {
    uptr p = php_dlsym(name);
    if (!p) p = php_dlsym(vname);
    st64(phz_s + i * 8, p);
    if (!p && !phz_missing) phz_missing = name;
}
i64 phz_eng_syms() {
    ph_lock();
    if (!phz_syms) {
        phz_sym(PHZ_TSRES, "ts_resource_ex");
        phz_sym(PHZ_TSFREE, "ts_free_thread");
        phz_sym(PHZ_RSTART, "php_request_startup");
        phz_sym(PHZ_RSTOP, "php_request_shutdown");
        phz_sym(PHZ_PGO, "core_globals_offset");
        phz_sym(PHZ_SGO, "sapi_globals_offset");
        phz_sym(PHZ_CGO, "compiler_globals_offset");
        phz_sym(PHZ_MAPEXT, "zend_map_ptr_extend");
        phz_sym(PHZ_CECL, "zend_ce_closure");
        phz_sym(PHZ_MKCL, "zend_create_closure");
        phz_sym(PHZ_PROPS, "zend_std_get_properties");
        phz_symv(PHZ_HFIND, "zend_hash_find", "zend_hash_find@@16");
        phz_symv(PHZ_HADD, "zend_hash_add", "zend_hash_add@@24");
        phz_symv(PHZ_HEND, "zend_hash_internal_pointer_end_ex", "zend_hash_internal_pointer_end_ex@@16");
        phz_symv(PHZ_HBACK, "zend_hash_move_backwards_ex", "zend_hash_move_backwards_ex@@16");
        phz_sym(PHZ_OSTART, "php_output_start_default");
        phz_sym(PHZ_OGET, "php_output_get_contents");
        phz_sym(PHZ_ODISC, "php_output_discard");
        phz_sym(PHZ_OEND, "php_output_end");
        phz_sym(PHZ_OLEVEL, "php_output_get_level");
        phz_sym(PHZ_SDADD, "append_user_shutdown_function");
        phz_sym(PHZ_SDCALL, "php_call_shutdown_functions");
        phz_sym(PHZ_SDFREE, "php_free_shutdown_functions");
        phz_sym(PHZ_UNWIND, "zend_is_unwind_exit");
        phz_symv(PHZ_ZSHASH, "zend_string_hash_func", "zend_string_hash_func@@8");
        phz_sym(PHZ_STDCLASS, "zend_standard_class_def");
        phz_syms = 1;
        if (phz_missing) phz_syms = 2;
    }
    i64 r = phz_syms;
    ph_unlock();
    return r == 1;
}

// A job: what a php thread and the thread that starts and joins it share,
// in pages neither Zend heap nor runtime arena owns. The buffers are
// (pointer, length, capacity) triples.
#define JB_FUNC     0               // 256: the closure's function, the worker's copy
#define JB_FAKE     256             // 160: the trampoline, an internal function
#define JB_NAME     416             // 40: its name, a string php never frees
#define JB_ENTRY    456             // 56: the worker's shutdown-function entry
#define JB_TAB      512             // buffer: the code the worker shares (which, pointer, name)
#define JB_IN       536             // buffer: the callable's copy and the arguments
#define JB_OUT      560             // buffer: the result, or what ended the call
#define JB_TXT      584             // buffer: the worker's output
#define JB_KIND     608             // 1 a Closure, 2 any other callable (a value)
#define JB_SCOPE    616
#define JB_CALLED   624
#define JB_MAPLAST  632             // the starting thread's CG(map_ptr_last)
#define JB_NARGS    640
#define JB_EXC      648             // 0 a result, 1 a throwable, 2 a fatal error, 3 no request
#define JB_DONE     656             // 1 once the call returned (0 after a bailout)
#define JB_LVL      664             // php's output level under the worker's buffer
#define JB_REC      672             // the thread's record (lib/php_rt.mc § the thread API)
#define JB_TRACE    680
#define JB_MAP      4096

void phz_bput(uptr bf, uptr p, i64 n) {
    i64 len = ld64(bf + 8);
    i64 cap = ld64(bf + 16);
    if (len + n > cap) {
        i64 nc = cap * 2;
        if (nc < 4096) nc = 4096;
        if (nc < len + n) nc = (len + n + 4095) / 4096 * 4096;
        uptr nb = ph_os_map(nc);
        if (!nb) php_die("mc-php: cannot map a php thread's memory\n", 41);
        if (len) php_memcpy(nb, ld64(bf), len);
        if (cap) ph_os_unmap(ld64(bf), cap);
        st64(bf, nb);
        st64(bf + 16, nc);
    }
    if (n) php_memcpy(ld64(bf) + len, p, n);
    st64(bf + 8, len + n);
}
void phz_bw(uptr bf, i64 v) { u8 w[8]; st64(w, v); phz_bput(bf, w, 8); }
// bytes, as their length and then the bytes padded to a word
void phz_bstr(uptr bf, uptr p, i64 n) {
    phz_bw(bf, n);
    phz_bput(bf, p, n);
    u8 z[8];
    st64(z, 0);
    if (n % 8) phz_bput(bf, z, 8 - n % 8);
}
void phz_bzs(uptr bf, uptr zs) { phz_bstr(bf, zs + ZSX_VAL, ld64(zs + ZSX_LEN)); }
void phz_bfree(uptr bf) {
    if (ld64(bf + 16)) ph_os_unmap(ld64(bf), ld64(bf + 16));
    st64(bf, 0);
    st64(bf + 8, 0);
    st64(bf + 16, 0);
}
void phz_job_free(uptr job) {
    phz_bfree(job + JB_TAB);
    phz_bfree(job + JB_IN);
    phz_bfree(job + JB_OUT);
    phz_bfree(job + JB_TXT);
    ph_os_unmap(job, JB_MAP);
}

// a zend_string of these bytes, in the calling thread's Zend heap
uptr phz_zs(uptr p, i64 n) {
    uptr z = phx_em(ZSX_HDR + n + 1);
    st32(z, 1);
    st32(z + 4, ZSX_GC_STRING);
    st64(z + 8, 0);
    st64(z + ZSX_LEN, n);
    php_memcpy(z + ZSX_VAL, p, n);
    st8(z + ZSX_VAL + n, 0);
    return z;
}
void phz_zs_rel(uptr z) {
    i64 r = ld32(z) - 1;
    st32(z, r);
    if (!r) phx_ef(z);
}
uptr phz_mstr(uptr zs) { return php_str_new(zs + ZSX_VAL, ld64(zs + ZSX_LEN)); }

// ---- the copy: out of one heap ---------------------------------------------
// A value as words: its type (php's IS_* numbers), then the payload. An
// object is its class's name and its properties; the second time the same
// object is met it is a reference to the first, so an object two places
// share is one object in the copy and a cycle ends.
#define PZ_OREF     9
#define SX_BUF      0
#define SX_OBJS     8               // object -> its index (the runtime's own array)
#define SX_NOBJ     16
#define SX_ERR      24              // the first refusal
#define SX_DEPTH    32
#define SX_SIZE     40
#define PZ_MAXDEPTH 256

uptr phz_sx_new(uptr bf) {
    uptr cx = php_alloc(SX_SIZE);
    st64(cx + SX_BUF, bf);
    st64(cx + SX_OBJS, php_arr_new(8));
    st64(cx + SX_NOBJ, 0);
    st64(cx + SX_ERR, 0);
    st64(cx + SX_DEPTH, 0);
    return cx;
}
void phz_sx_err(uptr cx, uptr why) {
    if (ld64(cx + SX_ERR)) return;
    st64(cx + SX_ERR, php_str_concat(php_str_new("mc-php: cannot copy into or out of a php thread: ", 49), why));
}
i64 phz_sx_deep(uptr cx) {
    st64(cx + SX_DEPTH, ld64(cx + SX_DEPTH) + 1);
    if (ld64(cx + SX_DEPTH) <= PZ_MAXDEPTH) return 1;
    phz_sx_err(cx, php_str_new("a value nested more than 256 levels deep (a recursive array?)", 61));
    return 0;
}

// Why an object of this class cannot be copied, or 0. Only a plain object is:
// one of the script's own classes, or a stdClass. php's other classes (a
// Closure, a DateTime, an exception, a generator) keep state outside their
// properties, and a class that extends one inherits that state; an enum case
// is one object per request by definition.
uptr phz_uncopyable(uptr ce) {
    if (ce == ld64(phz_f(PHZ_STDCLASS))) return 0;
    uptr nm = phz_mstr(ld64(ce + ZCX_NAME));
    if (ld32(ce + CEX_FLAGS) & ACC_ENUM)
        return php_str_concat(php_str_new("an enum case of ", 16), nm);
    uptr c = ce;
    loop {
        if (!c) break;
        if (ld8(c + CEX_TYPE) != ZCE_USER) {
            uptr m = php_str_concat(php_str_new("an object of class ", 19), nm);
            if (c == ce) return php_str_concat(m, php_str_new(", which is php's own", 20));
            m = php_str_concat(m, php_str_new(", which extends php's own ", 26));
            return php_str_concat(m, phz_mstr(ld64(c + ZCX_NAME)));
        }
        c = ld64(c + ZCX_PARENT);
    }
    return 0;
}

void phz_sx_val(uptr cx, uptr ez);
// the entries of an array or of an object's properties: a key (0 and the
// number, or 1 and the name), then the value
i64 phz_sx_ht(uptr cx, uptr ht) {
    uptr bf = ld64(cx + SX_BUF);
    i64 n = 0;
    u8 pos[8];
    st64(pos, 0);
    zend_hash_internal_pointer_reset_ex(ht, pos);
    loop {
        uptr v = zend_hash_get_current_data_ex(ht, pos);
        if (!v) break;
        uptr w = v;
        if (phx_type(w) == IZ_INDIRECT) w = ld64(w);
        if (phx_type(w) != IZ_UNDEF) {
            u8 sk[8];
            u8 nk[8];
            st64(sk, 0);
            st64(nk, 0);
            if (zend_hash_get_current_key_ex(ht, sk, nk, pos) == HASH_KEY_IS_STRING) {
                phz_bw(bf, 1);
                phz_bzs(bf, ld64(sk));
            } else {
                phz_bw(bf, 0);
                phz_bw(bf, ld64(nk));
            }
            phz_sx_val(cx, w);
            n = n + 1;
        }
        zend_hash_move_forward_ex(ht, pos);
    }
    return n;
}

void phz_sx_obj(uptr cx, uptr zo) {
    uptr bf = ld64(cx + SX_BUF);
    uptr seen = php_ht_find(ld64(cx + SX_OBJS), zo, 0);
    if (seen) {
        phz_bw(bf, PZ_OREF);
        phz_bw(bf, ld64(seen));
        return;
    }
    uptr ce = ld64(zo + ZOX_CE);
    uptr why = phz_uncopyable(ce);
    if (why) { phz_sx_err(cx, why); return; }
    if (!phz_sx_deep(cx)) return;
    php_zv_cp(php_arr_islot(ld64(cx + SX_OBJS), zo), php_zlong(ld64(cx + SX_NOBJ)));
    st64(cx + SX_NOBJ, ld64(cx + SX_NOBJ) + 1);
    phz_bw(bf, IZ_OBJECT);
    phz_bzs(bf, ld64(ce + ZCX_NAME));
    i64 at = ld64(bf + 8);
    phz_bw(bf, 0);
    i64 n = phz_sx_ht(cx, callp(phz_f(PHZ_PROPS), zo));
    st64(ld64(bf) + at, n);
    st64(cx + SX_DEPTH, ld64(cx + SX_DEPTH) - 1);
}

void phz_sx_val(uptr cx, uptr ez) {
    if (ld64(cx + SX_ERR)) return;
    uptr bf = ld64(cx + SX_BUF);
    i64 t = phx_type(ez);
    if (t == IZ_INDIRECT) { ez = ld64(ez); t = phx_type(ez); }
    if (t == IZ_REFERENCE) { ez = ld64(ez) + ZRX_VAL; t = phx_type(ez); }
    if (t == IZ_UNDEF) t = IZ_NULL;
    if (t <= IZ_TRUE) { phz_bw(bf, t); return; }
    if (t == IZ_LONG || t == IZ_DOUBLE) { phz_bw(bf, t); phz_bw(bf, ld64(ez)); return; }
    if (t == IZ_STRING) { phz_bw(bf, t); phz_bzs(bf, ld64(ez)); return; }
    if (t == IZ_ARRAY) {
        if (!phz_sx_deep(cx)) return;
        phz_bw(bf, t);
        i64 at = ld64(bf + 8);
        phz_bw(bf, 0);
        i64 n = phz_sx_ht(cx, ld64(ez));
        st64(ld64(bf) + at, n);
        st64(cx + SX_DEPTH, ld64(cx + SX_DEPTH) - 1);
        return;
    }
    if (t == IZ_OBJECT) { phz_sx_obj(cx, ld64(ez)); return; }
    if (t == IZ_RESOURCE) { phz_sx_err(cx, php_str_new("a resource", 10)); return; }
    phz_sx_err(cx, php_str_concat(php_str_new("a value of php's internal type ", 31), php_itos(t)));
}

// ---- the copy: into the other heap -----------------------------------------
// Always a valid zval, so the caller's one zval_ptr_dtor frees whatever was
// built; a part that cannot be rebuilt is null and the reason is kept.
#define DX_BASE     0
#define DX_POS      8
#define DX_OBJS     16              // index -> object
#define DX_NOBJ     24
#define DX_ERR      32
#define DX_SIZE     40

uptr phz_dx_new(uptr bf) {
    uptr cx = php_alloc(DX_SIZE);
    st64(cx + DX_BASE, ld64(bf));
    st64(cx + DX_POS, 0);
    st64(cx + DX_OBJS, php_arr_new(8));
    st64(cx + DX_NOBJ, 0);
    st64(cx + DX_ERR, 0);
    return cx;
}
i64 phz_rw(uptr cx) {
    i64 v = ld64(ld64(cx + DX_BASE) + ld64(cx + DX_POS));
    st64(cx + DX_POS, ld64(cx + DX_POS) + 8);
    return v;
}
uptr phz_rp(uptr cx, i64 n) {
    uptr p = ld64(cx + DX_BASE) + ld64(cx + DX_POS);
    st64(cx + DX_POS, ld64(cx + DX_POS) + (n + 7) / 8 * 8);
    return p;
}
uptr phz_rzs(uptr cx) {
    i64 n = phz_rw(cx);
    return phz_zs(phz_rp(cx, n), n);
}
void phz_dx_err(uptr cx, uptr why) {
    if (ld64(cx + DX_ERR)) return;
    st64(cx + DX_ERR, php_str_concat(php_str_new("mc-php: cannot copy into or out of a php thread: ", 49), why));
}
void phz_znull(uptr ez) { st64(ez, 0); st32(ez + ZVX_TYPE_INFO, IZ_NULL); }

void phz_dx_val(uptr cx, uptr ez);
// n entries, into ht; obj: an object's property table, where a declared
// property is a slot (IS_INDIRECT) the object already holds
void phz_dx_ht(uptr cx, uptr ht, i64 n, i64 obj) {
    i64 i = 0;
    loop {
        if (i >= n) break;
        i64 kt = phz_rw(cx);
        uptr k = 0;
        i64 h = 0;
        if (kt) k = phz_rzs(cx);
        else h = phz_rw(cx);
        u8 v[16];
        phz_dx_val(cx, v);
        if (!ht) zval_ptr_dtor(v);
        if (ht && !k) zend_hash_index_update(ht, h, v);
        if (ht && k) {
            uptr slot = 0;
            if (obj) slot = callp(phz_f(PHZ_HFIND), ht, k);
            if (slot && phx_type(slot) == IZ_INDIRECT) {
                uptr d = ld64(slot);
                zval_ptr_dtor(d);
                st64(d, ld64(v));
                st32(d + ZVX_TYPE_INFO, ld32(v + ZVX_TYPE_INFO));
                st32(d + 12, 0);
            } else zend_hash_update(ht, k, v);
        }
        if (k) phz_zs_rel(k);
        i = i + 1;
    }
}

void phz_dx_obj(uptr cx, uptr ez) {
    uptr nz = phz_rzs(cx);
    i64 n = phz_rw(cx);
    i64 idx = ld64(cx + DX_NOBJ);
    st64(cx + DX_NOBJ, idx + 1);
    phz_znull(ez);
    uptr ce = zend_lookup_class_ex(nz, 0, FETCH_NO_AUTOLOAD);
    if (ce) {
        object_init_ex(ez, ce);
        if (phx_zexc()) zend_clear_exception();
    }
    if (phx_type(ez) != IZ_OBJECT) {
        phz_dx_err(cx, php_str_concat(php_str_new("no class ", 9),
                       php_str_concat(phz_mstr(nz), php_str_new(" on this side", 13))));
        phz_znull(ez);
    }
    uptr o = 0;
    if (phx_type(ez) == IZ_OBJECT) o = ld64(ez);
    php_zv_cp(php_arr_islot(ld64(cx + DX_OBJS), idx), php_zlong(o));
    phz_zs_rel(nz);
    uptr ht = 0;
    if (o) ht = callp(phz_f(PHZ_PROPS), o);
    phz_dx_ht(cx, ht, n, 1);
}

void phz_dx_val(uptr cx, uptr ez) {
    phz_znull(ez);
    i64 t = phz_rw(cx);
    if (t <= IZ_TRUE) { st32(ez + ZVX_TYPE_INFO, t); return; }
    if (t == IZ_LONG || t == IZ_DOUBLE) { st64(ez, phz_rw(cx)); st32(ez + ZVX_TYPE_INFO, t); return; }
    if (t == IZ_STRING) { st64(ez, phz_rzs(cx)); st32(ez + ZVX_TYPE_INFO, IZ_STRING_EX); return; }
    if (t == IZ_ARRAY) {
        i64 n = phz_rw(cx);
        uptr ht = _zend_new_array(n);
        phz_dx_ht(cx, ht, n, 0);
        st64(ez, ht);
        st32(ez + ZVX_TYPE_INFO, IZ_ARRAY_EX);
        return;
    }
    if (t == IZ_OBJECT) { phz_dx_obj(cx, ez); return; }
    if (t == PZ_OREF) {
        uptr b = php_ht_find(ld64(cx + DX_OBJS), phz_rw(cx), 0);
        uptr o = 0;
        if (b) o = ld64(b);
        if (o) {
            st32(o, ld32(o) + 1);
            st64(ez, o);
            st32(ez + ZVX_TYPE_INFO, IZ_OBJECT_EX);
        }
    }
}

// ---- the start --------------------------------------------------------------
// the code the starting request can reach, as it is now, for the worker's
// tables: each user function and class, with its key. Answers 0, or the
// name of the first one opcache does not cache (the refusal names it).
uptr phz_snap(uptr job, uptr kind) {
    uptr tab = job + JB_TAB;
    i64 w = 0;
    loop {
        if (w > 1) break;
        uptr ht = ld64(phx_eg + EGX_FUNCTION_TABLE);
        if (w) ht = ld64(phx_eg + EGX_CLASS_TABLE);
        u8 pos[8];
        st64(pos, 0);
        callp(phz_f(PHZ_HEND), ht, pos);
        loop {
            uptr v = zend_hash_get_current_data_ex(ht, pos);
            if (!v) break;
            uptr p = ld64(v);
            i64 user = 0;
            i64 imm = 0;
            uptr name = 0;
            if (!w) {
                // php's own functions are the table's first entries: a user
                // function is never before one
                if (ld8(p + ZFX_TYPE) != ZFN_USER) break;
                user = 1;
                imm = ld32(p + ZFX_FN_FLAGS) & ACC_IMMUTABLE;
                name = ld64(p + ZFX_NAME);
            } else {
                // a class_alias of one of php's own classes can come after
                // the script's: the class table is walked whole
                user = ld8(p + CEX_TYPE) == ZCE_USER;
                imm = ld32(p + CEX_FLAGS) & ACC_IMMUTABLE;
                name = ld64(p + ZCX_NAME);
            }
            if (user) {
                if (!imm) {
                    st64(kind, "function ");
                    if (w) st64(kind, "class ");
                    return name;
                }
                u8 sk[8];
                u8 nk[8];
                st64(sk, 0);
                st64(nk, 0);
                zend_hash_get_current_key_ex(ht, sk, nk, pos);
                if (ld64(sk)) {
                    phz_bw(tab, w);
                    phz_bw(tab, p);
                    phz_bzs(tab, ld64(sk));
                }
            }
            callp(phz_f(PHZ_HBACK), ht, pos);
        }
        w = w + 1;
    }
    return 0;
}

void phz_notcached(uptr kind, uptr zsname) {
    uptr m = php_str_new("mc-php: a php callable runs on another thread only when opcache caches the code it can reach: enable opcache (opcache.enable=1, and opcache.enable_cli=1 on the command line); not cached: ", 187);
    m = php_str_concat(m, php_str_new(kind, php_cstrlen(kind)));
    php_throw_cls(php_str_new("Error", 5), php_str_concat(m, phz_mstr(zsname)));
}

// a handle of the thread table (lib/php_rt.mc's php_thr_start reserves one
// the same way): the record is published once the thread exists
i64 phz_thandle() {
    ph_lock();
    ph_tnext = ph_tnext + 1;
    i64 id = ph_tnext;
    if (id >= ph_tcap) {
        i64 c = ph_tcap * 2 + 64;
        uptr t = ph_os_map(c * 8);
        if (!t) { ph_unlock(); php_die("mc-php: cannot map the thread table\n", 36); }
        i64 i = 0;
        loop { if (i >= ph_tcap) break; st64(t + i * 8, ld64(ph_ttab + i * 8)); i = i + 1; }
        if (ph_ttab) ph_os_unmap(ph_ttab, ph_tcap * 8);
        ph_ttab = t;
        ph_tcap = c;
    }
    ph_unlock();
    return id;
}

uptr phz_eng_body(uptr job);
void phz_tr(uptr job, uptr m) { if (ld64(job + JB_TRACE)) write(2, m, php_cstrlen(m)); }

// an argument, into the copy; 0 when the runtime threw converting it
i64 phz_sx_arg(uptr cx, uptr a) {
    u8 ez[16];
    phx_r2e(a, ez);
    if (php_thrown()) { zval_ptr_dtor(ez); return 0; }
    phz_sx_val(cx, ez);
    zval_ptr_dtor(ez);
    return 1;
}

i64 php_thr_eng_start(uptr fn, i64 n, uptr a1, uptr a2, uptr a3, uptr a4, uptr a5) { uptr phT = ph_tcur; if (!phT) phT = ph_tslow();
    if (phx_offthread(phT)) return 0;
    if (!phz_eng_syms()) {
        uptr m = php_str_new("mc-php: a php callable on another thread needs php's ", 53);
        m = php_str_concat(m, php_str_new(phz_missing, php_cstrlen(phz_missing)));
        php_throw_cls(php_str_new("Error", 5), php_str_concat(m, php_str_new(", which this php does not export", 32)));
        return 0;
    }
    u8 fz[16];
    phx_r2e(fn, fz);
    if (php_thrown()) { zval_ptr_dtor(fz); return 0; }
    if (!(zend_is_callable_ex(fz, 0, 0, 0, 0, 0) & 255)) {
        zval_ptr_dtor(fz);
        uptr m = "mc-php: mcphp_thread_start() runs a callable";
        php_throw_cls(php_str_new("Error", 5), php_str_new(m, php_cstrlen(m)));
        return 0;
    }
    uptr job = ph_os_map(JB_MAP);
    if (!job) php_die("mc-php: cannot map a php thread's memory\n", 41);
    uptr zo = 0;
    if (phx_type(fz) == IZ_OBJECT) {
        zo = ld64(fz);
        if (ld64(zo + ZOX_CE) != ld64(phz_f(PHZ_CECL))) zo = 0;
    }
    st64(job + JB_KIND, 2);
    // a Closure: its function, the worker's copy -- and code opcache does
    // not cache (a closure from eval(), from a script opcache skipped) is
    // refused like any other
    if (zo) {
        uptr f = zo + ZCLX_FUNC;
        uptr cf = job + JB_FUNC;
        if (ld8(f + ZFX_TYPE) == ZFN_USER && ld64(f + OPX_REFCOUNT)) {
            zval_ptr_dtor(fz);
            ph_os_unmap(job, JB_MAP);
            phz_notcached("the callable ", ld64(f + ZFX_NAME));
            return 0;
        }
        php_memcpy(cf, f, ZFX_SIZE);
        if (ld8(f + ZFX_TYPE) == ZFN_USER) {
            // a cache of its own; not a first-class callable's any more: its
            // statics are the copy's, not the function's
            st32(cf + ZFX_FN_FLAGS, (ld32(cf + ZFX_FN_FLAGS) | ACC_HEAP_RT_CACHE) & ~ACC_FAKE_CLOSURE);
            st64(cf + OPX_REFCOUNT, 0);
        } else st64(cf + IFX_HANDLER, ld64(zo + ZCLX_ORIG));
        st64(job + JB_KIND, 1);
        st64(job + JB_SCOPE, ld64(f + ZFX_SCOPE));
        st64(job + JB_CALLED, ld64(zo + ZCLX_CALLED));
    }
    u8 kind[8];
    uptr nc = phz_snap(job, kind);
    if (nc) {
        zval_ptr_dtor(fz);
        phz_job_free(job);
        phz_notcached(ld64(kind), nc);
        return 0;
    }
    uptr cx = phz_sx_new(job + JB_IN);
    if (zo) {
        uptr tz = zo + ZCLX_THIS;
        uptr bf = job + JB_IN;
        if (phx_type(tz) == IZ_OBJECT) { phz_bw(bf, 1); phz_sx_val(cx, tz); }
        else phz_bw(bf, 0);
        uptr sv = 0;
        if (ld8(zo + ZCLX_FUNC + ZFX_TYPE) == ZFN_USER) sv = ld64(zo + ZCLX_FUNC + OPX_STATIC_VARS_PTR);
        // a closure's statics are a plain pointer (never a map_ptr offset,
        // whose low bit is set)
        if (sv && !(sv & 1)) {
            u8 az[16];
            st64(az, sv);
            st32(az + ZVX_TYPE_INFO, IZ_ARRAY);
            phz_bw(bf, 1);
            phz_sx_val(cx, az);
        } else phz_bw(bf, 0);
    } else phz_sx_val(cx, fz);
    zval_ptr_dtor(fz);
    st64(job + JB_NARGS, n);
    i64 ok = 1;
    if (ok && n > 0) ok = phz_sx_arg(cx, a1);
    if (ok && n > 1) ok = phz_sx_arg(cx, a2);
    if (ok && n > 2) ok = phz_sx_arg(cx, a3);
    if (ok && n > 3) ok = phz_sx_arg(cx, a4);
    if (ok && n > 4) ok = phz_sx_arg(cx, a5);
    if (!ok || ld64(cx + SX_ERR)) {
        phz_job_free(job);
        if (ok) php_throw_cls(php_str_new("Error", 5), ld64(cx + SX_ERR));
        return 0;
    }
    uptr ls = callp(phx_ts_get);
    st64(job + JB_MAPLAST, ld64(ls + ld64(phz_f(PHZ_CGO)) + CGX_MAP_PTR_LAST));
    ph_tapi = 1;
    php_pin();
    uptr rec = php_alloc(PHA_SIZE);
    i64 i = 0;
    loop { if (i >= PHA_SIZE) break; st64(rec + i, 0); i = i + 8; }
    i64 id = phz_thandle();
    uptr root = ld64(phT + PHT_ph_troot);
    if (!root) root = phT;
    st64(rec + PHA_ID, id);
    st64(rec + PHA_ROOT, root);
    st64(rec + PHA_N, 0 - 1);
    st64(rec + PHA_ARG, job);
    st64(job + JB_REC, rec);
    if (getenv("MCPHP_T3B_TRACE")) st64(job + JB_TRACE, 1);
    if (ph_thr_create(&phz_eng_body, job, rec + PHA_H) != 0) php_die("mc-php: cannot start a thread\n", 30);
    ph_lock();
    st64(ph_ttab + id * 8, rec);
    ph_unlock();
    return id;
}

// ---- the worker ---------------------------------------------------------------
// what php's output layer holds above JB_LVL, into the job's buffer: a level
// the callable opened and left open is ended into the worker's own first
void phz_out_take(uptr job) {
    i64 base = ld64(job + JB_LVL);
    loop {
        if ((callp(phz_f(PHZ_OLEVEL)) & 0xffffffff) <= base + 1) break;
        callp(phz_f(PHZ_OEND));
    }
    if ((callp(phz_f(PHZ_OLEVEL)) & 0xffffffff) != base + 1) return;
    u8 z[16];
    phz_znull(z);
    callp(phz_f(PHZ_OGET), z);
    if (phx_type(z) == IZ_STRING) {
        uptr s = ld64(z);
        phz_bput(job + JB_TXT, s + ZSX_VAL, ld64(s + ZSX_LEN));
    }
    zval_ptr_dtor(z);
    callp(phz_f(PHZ_ODISC));
}

// what ended the call instead of a result: a throwable's class, message and
// code (an Error of the runtime's own when a copy was refused)
void phz_set_exc(uptr job, i64 kind, uptr cls, uptr msg, i64 code) {
    uptr out = job + JB_OUT;
    st64(out + 8, 0);
    st64(job + JB_EXC, kind);
    phz_bstr(out, cls + ZS_HDR, php_strlen(cls));
    phz_bstr(out, msg + ZS_HDR, php_strlen(msg));
    phz_bw(out, code);
}

// the throwable EG(exception) holds, taken off it
void phz_take_exc(uptr job) {
    uptr zo = ld64(phx_eg + phx_egx);
    // exit() inside the callable ends the call with no result
    if (callp(phz_f(PHZ_UNWIND), zo) & 255) {
        zend_clear_exception();
        phz_bw(job + JB_OUT, IZ_NULL);
        return;
    }
    u8 r1[16];
    u8 r2[16];
    uptr mz = phx_zprop(zo, "message", r1);
    uptr cz = phx_zprop(zo, "code", r2);
    uptr msg = php_str_new("", 0);
    if (phx_type(mz) == IZ_STRING) msg = phz_mstr(ld64(mz));
    i64 code = 0;
    if (phx_type(cz) == IZ_LONG) code = ld64(cz);
    phz_set_exc(job, 1, phz_mstr(ld64(ld64(zo + ZOX_CE) + ZCX_NAME)), msg, code);
    zend_clear_exception();
}

// the worker's Closure: the starting one's function, its bound $this and its
// captured variables copied, and a run-time cache of its own
void phz_mkclosure(uptr job, uptr dx, uptr fz) {
    uptr fn = job + JB_FUNC;
    u8 tz[16];
    u8 sz[16];
    phz_znull(tz);
    phz_znull(sz);
    if (phz_rw(dx)) phz_dx_val(dx, tz);
    if (phz_rw(dx)) phz_dx_val(dx, sz);
    if (ld8(fn + ZFX_TYPE) == ZFN_USER) {
        st64(fn + OPX_STATIC_VARS_PTR, 0);
        if (phx_type(sz) == IZ_ARRAY) st64(fn + OPX_STATIC_VARS_PTR, ld64(sz));
    }
    uptr tp = 0;
    if (phx_type(tz) == IZ_OBJECT) tp = tz;
    callp(phz_f(PHZ_MKCL), fz, fn, ld64(job + JB_SCOPE), ld64(job + JB_CALLED), tp);
    zval_ptr_dtor(tz);
    zval_ptr_dtor(sz);
}

void phz_call(uptr job) {
    uptr dx = phz_dx_new(job + JB_IN);
    u8 fz[16];
    phz_znull(fz);
    phz_tr(job, "T dx\n");
    if (ld64(job + JB_KIND) == 1) phz_mkclosure(job, dx, fz);
    phz_tr(job, "T mkcl\n");
    else phz_dx_val(dx, fz);
    i64 n = ld64(job + JB_NARGS);
    u8 av[80];
    i64 i = 0;
    loop { if (i >= n) break; phz_dx_val(dx, av + i * 16); i = i + 1; }
    u8 rv[16];
    st64(rv, 0);
    st32(rv + ZVX_TYPE_INFO, IZ_UNDEF);
    if (ld64(dx + DX_ERR)) phz_set_exc(job, 1, php_str_new("Error", 5), ld64(dx + DX_ERR), 0);
    else {
        i64 lz = phx_lz;
        phx_lz = 0;
        phz_tr(job, "T callfn\n");
        _call_user_function_impl(0, fz, rv, n, av, 0);
        phz_tr(job, "T callret\n");
        phx_lz = lz;
    }
    i = 0;
    loop { if (i >= n) break; zval_ptr_dtor(av + i * 16); i = i + 1; }
    zval_ptr_dtor(fz);
    if (phx_zexc()) phz_take_exc(job);
    else if (!ld64(job + JB_EXC)) {
        uptr cx = phz_sx_new(job + JB_OUT);
        phz_sx_val(cx, rv);
        if (ld64(cx + SX_ERR)) phz_set_exc(job, 1, php_str_new("Error", 5), ld64(cx + SX_ERR), 0);
    }
    zval_ptr_dtor(rv);
}

// the trampoline's handler: php calls it as the worker request's shutdown
// function, under an internal frame of its own
void phz_tramp(uptr ed, uptr rv) { uptr phT = ph_tcur; if (!phT) phT = ph_tslow();
    uptr job = ld64(phT + PHT_phz_job);
    phz_tr(job, "T tramp\n");
    st64(job + JB_LVL, callp(phz_f(PHZ_OLEVEL)) & 0xffffffff);
    callp(phz_f(PHZ_OSTART));
    phz_tr(job, "T ostart\n");
    phx_enter();
    phz_call(job);
    phz_tr(job, "T called\n");
    php_flush();
    phx_leave();
    phz_out_take(job);
    st64(job + JB_DONE, 1);
}

// the starting request's code, in this worker's tables (phz_snap wrote it)
void phz_share(uptr job) {
    uptr tab = job + JB_TAB;
    uptr dx = phz_dx_new(tab);
    uptr ft = ld64(phx_eg + EGX_FUNCTION_TABLE);
    uptr ct = ld64(phx_eg + EGX_CLASS_TABLE);
    loop {
        if (ld64(dx + DX_POS) >= ld64(tab + 8)) break;
        i64 w = phz_rw(dx);
        uptr p = phz_rw(dx);
        uptr k = phz_rzs(dx);
        u8 z[16];
        st64(z, p);
        st32(z + ZVX_TYPE_INFO, IZ_PTR);
        uptr t = ft;
        if (w) t = ct;
        callp(phz_f(PHZ_HADD), t, k, z);
        phz_zs_rel(k);
    }
}

// the worker's request, once RINIT gave this thread its block: the code
// shared, the call made as the request's shutdown function, what a fatal
// error left if the call did not return
void phz_eng_run(uptr job) { uptr phT = ph_tcur; if (!phT) phT = ph_tslow();
    uptr ls = callp(phx_ts_get);
    uptr pg = ls + ld64(phz_f(PHZ_PGO));
    uptr sg = ls + ld64(phz_f(PHZ_SGO));
    st8(pg + PGX_DURING_STARTUP, 0);
    st8(sg + SGX_HEADERS_SENT, 1);
    st8(sg + SGX_NO_HEADERS, 1);
    phz_tr(job, "T sg\n");
    callp(phz_f(PHZ_MAPEXT), ld64(job + JB_MAPLAST));
    phz_tr(job, "T mapext\n");
    phz_share(job);
    phz_tr(job, "T share\n");
    uptr nm = job + JB_NAME;
    st32(nm, 1);
    st32(nm + 4, ZSX_GC_STRING | ZSX_INTERNED | ZSX_PERSIST);
    st64(nm + ZSX_LEN, 12);
    php_memcpy(nm + ZSX_VAL, "mcphp_thread", 12);
    callp(phz_f(PHZ_ZSHASH), nm);
    uptr fk = job + JB_FAKE;
    st8(fk + ZFX_TYPE, ZFN_INTERNAL);
    st64(fk + ZFX_NAME, nm);
    st64(fk + IFX_HANDLER, &phz_tramp);
    st64(job + JB_ENTRY, fk);
    st64(phT + PHT_phz_job, job);
    callp(phz_f(PHZ_SDADD), job + JB_ENTRY);
    phz_tr(job, "T sdadd\n");
    callp(phz_f(PHZ_SDCALL));
    phz_tr(job, "T sdcall\n");
    callp(phz_f(PHZ_SDFREE));
    phz_tr(job, "T sdfree\n");
    st64(phT + PHT_phz_job, 0);
    if (ld64(job + JB_DONE)) return;
    // a bailout: php's own fatal error ended the call, and printed itself
    // into the worker's output
    phz_out_take(job);
    uptr m = ld64(pg + PGX_LAST_ERROR_MESSAGE);
    uptr msg = php_str_new("", 0);
    if (m) msg = phz_mstr(m);
    phz_set_exc(job, 2, php_str_new("", 0), msg, 0);
}

// the thread's entry. Nothing here may read the thread's block before
// php_request_startup ran this module's RINIT, which makes the block
// (phz_thread): this function names only process-wide words
uptr phz_eng_body(uptr job) {
    phz_tr(job, "T body\n");
    callp(phz_f(PHZ_TSRES), 0, 0);
    phz_tr(job, "T tsres\n");
    uptr ls = callp(phx_ts_get);
    uptr pg = ls + ld64(phz_f(PHZ_PGO));
    st8(pg + PGX_EXPOSE_PHP, 0);
    st8(pg + PGX_AUTO_GLOBALS_JIT, 1);
    phz_tr(job, "T pg\n");
    i64 okr = (callp(phz_f(PHZ_RSTART)) & 0xffffffff) == 0;
    phz_tr(job, "T rstart\n");
    if (okr) phz_eng_run(job);
    else st64(job + JB_EXC, 3);
    callp(phz_f(PHZ_RSTOP), 0);
    phz_tr(job, "T rstop\n");
    ph_lock();
    st64(ld64(job + JB_REC) + PHA_STATE, 1);
    ph_unlock();
    callp(phz_f(PHZ_TSFREE));
    phz_tr(job, "T tsfree\n");
    return 0;
}

// ---- the join ----------------------------------------------------------------
void phz_out_emit(uptr job) {
    uptr t = job + JB_TXT;
    if (ld64(t + 8)) php_write(ld64(t), ld64(t + 8));
}

// what ended the call, as the runtime's message; 0 for a result
uptr phz_endmsg(uptr job, uptr cls) {
    i64 e = ld64(job + JB_EXC);
    if (e == 3) return php_str_new("mc-php: a php thread could not start its php request", 52);
    if (!e) return 0;
    uptr dx = phz_dx_new(job + JB_OUT);
    i64 n = phz_rw(dx);
    st64(cls, php_str_new(phz_rp(dx, n), n));
    n = phz_rw(dx);
    return php_str_new(phz_rp(dx, n), n);
}

uptr phz_eng_join(uptr rec) { uptr phT = ph_tcur; if (!phT) phT = ph_tslow();
    ph_thr_join(rec + PHA_H);
    uptr job = ld64(rec + PHA_ARG);
    phz_out_emit(job);
    uptr r = php_znull();
    i64 e = ld64(job + JB_EXC);
    u8 cls[8];
    st64(cls, 0);
    uptr msg = phz_endmsg(job, cls);
    if (phx_offthread(phT)) e = 0 - 1;
    if (e == 0) {
        uptr dx = phz_dx_new(job + JB_OUT);
        u8 ez[16];
        phz_dx_val(dx, ez);
        if (ld64(dx + DX_ERR)) php_throw_cls(php_str_new("Error", 5), ld64(dx + DX_ERR));
        else r = phx_e2r(ez);
        zval_ptr_dtor(ez);
    }
    if (e == 1) {
        // the same class, message and code, thrown here; a class this
        // request does not have is the runtime's Error naming it
        uptr dx = phz_dx_new(job + JB_OUT);
        phz_rp(dx, phz_rw(dx));
        phz_rp(dx, phz_rw(dx));
        i64 code = phz_rw(dx);
        uptr cz = phx_zstr(ld64(cls));
        uptr ce = zend_lookup_class_ex(cz, 0, FETCH_NO_AUTOLOAD);
        phz_zs_rel(cz);
        if (ce) {
            uptr mz = phx_zstr(msg);
            zend_throw_exception(ce, mz + ZSX_VAL, code);
            phz_zs_rel(mz);
            phx_zcatch();
        } else {
            uptr m = php_str_concat(php_str_new("mc-php: a php thread ended on an uncaught ", 42), ld64(cls));
            php_throw_cls(php_str_new("Error", 5), php_str_concat(php_str_concat(m, php_str_new(": ", 2)), msg));
        }
    }
    if (e == 2) php_throw_cls(php_str_new("Error", 5), php_str_concat(php_str_new("mc-php: a php thread ended on a fatal error: ", 45), msg));
    if (e == 3) php_throw_cls(php_str_new("Error", 5), msg);
    phz_job_free(job);
    return r;
}

// the end of the request (php_thr_endall): a php thread nobody joined is
// waited for and its output written; report: its uncaught throwable or fatal
// error as the warning a compiled thread's gets. 1 when it reported.
i64 phz_eng_end(uptr rec, i64 report) {
    ph_thr_join(rec + PHA_H);
    uptr job = ld64(rec + PHA_ARG);
    phz_out_emit(job);
    i64 e = ld64(job + JB_EXC);
    u8 cls[8];
    st64(cls, 0);
    uptr msg = phz_endmsg(job, cls);
    phz_job_free(job);
    if (!report || !e) return 0;
    uptr s = php_str_new("mc-php: a thread neither joined nor detached ", 45);
    if (e == 1) {
        s = php_str_concat(php_str_concat(s, php_str_new("ended on an uncaught ", 21)), ld64(cls));
        if (php_strlen(msg)) s = php_str_concat(php_str_concat(s, php_str_new(": ", 2)), msg);
    }
    if (e == 2) s = php_str_concat(php_str_concat(s, php_str_new("ended on a fatal error: ", 24)), msg);
    if (e == 3) s = msg;
    php_mreset();
    php_ms(s);
    php_raise_m(PHE_WARNING);
    return 1;
}

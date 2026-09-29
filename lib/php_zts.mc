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
i64 phx_ts_rinit(i64 mtype, i64 mnum) {
    phz_thread();
    i64 egx = phx_egx_done;
    phx_egx_done = 1;
    phx_enter();
    php_pin();
    phz_privatize();
    phx_leave();
    phx_egx_done = egx;
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
// which the thread only reads -- module state refuses another thread
// (ph_shared_off), and so does php's engine
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

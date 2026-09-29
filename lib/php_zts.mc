// php_zts.mc -- what an extension for a thread-safe php adds (src/program.mc
// pushes it only when the output is ZTS: [php].thread_safety = "zts", or the
// ZTS half of "both"). Nothing in the NTS output changes: the NTS module is
// byte for byte what it was before this file existed (tests/zts.sh).
//
// A ZTS php keeps every engine global in a block per thread, reached through
// TSRM: EG(x) is `tsrm_get_ls_cache() + executor_globals_offset`, and php
// exports both names. There is no `executor_globals` symbol at all, so the
// NTS road's php_dlsym("executor_globals") answers 0 here. The offset of
// EG(exception) inside the block is the same number on both builds (measured:
// tests/ext/abi.c prints 960 under the php:8.5-alpine and php:8.5-zts-alpine
// headers alike) and is still measured at the first call (phx_egx_find).
//
// The module serves ONE php thread: the one that loaded it. That is every
// request of the CLI and of any single-threaded SAPI; a threaded SAPI running
// requests on other threads is refused at the request's start by name
// (phx_ts_rinit), because the runtime's own state is the loading thread's
// (docs/threads.md § ZTS). Lifting that is the thread plan's step 3.

#define E_CORE_ERROR 16

uptr phx_ts_get;                    // tsrm_get_ls_cache
uptr phx_ts_ls0;                    // the loading thread's TSRM block

i64 phx_ts_mine() { return callp(phx_ts_get) == phx_ts_ls0; }

// a request on another php thread: refused before any handler runs
i64 phx_ts_rinit(i64 mtype, i64 mnum) {
    if (phx_ts_mine()) return 0;
    callp(php_dlsym("zend_error"), E_CORE_ERROR,
          "mc-php: this extension runs on the php thread that loaded it (a threaded SAPI's other threads are the thread plan's step 3)");
    return 0 - 1;
}
i64 phx_ts_rshutdown(i64 mtype, i64 mnum) {
    if (!phx_ts_mine()) return 0;
    return phx_rshutdown(mtype, mnum);
}

// get_module's last step (src/ext.mc): the engine's globals through TSRM, and
// the two request hooks that keep the module on its thread. In a php that is
// not ZTS the two names are missing and the header is returned as it is: php
// then refuses the module itself, by name, for its zts field.
uptr phx_ts_module(uptr me) {
    phx_ts_get = php_dlsym("tsrm_get_ls_cache");
    uptr off = php_dlsym("executor_globals_offset");
    if (!phx_ts_get || !off) return me;
    phx_ts_ls0 = callp(phx_ts_get);
    phx_eg = phx_ts_ls0 + ld64(off);
    st64(me + MEX_REQUEST_STARTUP, &phx_ts_rinit);
    st64(me + MEX_REQUEST_SHUTDOWN, &phx_ts_rshutdown);
    return me;
}

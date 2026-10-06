// php_tls.mc -- the thread block's layout (lib/php_rt.mc § the thread block):
// every word the runtime changes while code runs, one block per thread.
// Scalars first, so each is within a load's immediate offset of phT; the
// buffers after them. A new per-thread word goes here and nowhere else, and
// src/tls.mc lists the few the compiled code names.

#define PHT_ph_hbase               0   // uptr, 8 bytes  the arena this thread bumps (ph_heap on the thread that booted)
#define PHT_ph_hlim                8   // i64, 8 bytes  and its size
#define PHT_ph_tidx               16   // i64, 8 bytes  0 on the thread that booted, 1.. on the others
#define PHT_ph_top                24   // i64, 8 bytes
#define PHT_ph_zalloc             32   // uptr, 8 bytes  the slow path; set = inside an extension call
#define PHT_ph_zcur               40   // uptr, 8 bytes  the Zend chunk the call is bumping through
#define PHT_ph_zpos               48   // i64, 8 bytes
#define PHT_ph_zlim               56   // i64, 8 bytes
#define PHT_ph_pin                64   // i64, 8 bytes
#define PHT_ph_pool               72   // uptr, 8 bytes  the temporaries: one reference each
#define PHT_ph_pn                 80   // i64, 8 bytes
#define PHT_ph_pcap               88   // i64, 8 bytes
#define PHT_ph_esc                96   // uptr, 8 bytes  the escaped strings: one reference each
#define PHT_ph_en                104   // i64, 8 bytes
#define PHT_ph_ecap              112   // i64, 8 bytes
#define PHT_ph_rc_inplace        120   // i64, 8 bytes  `.=` and `$s[$i] =` that wrote into the string itself,
#define PHT_ph_rc_copied         128   // i64, 8 bytes  and the ones that had to copy it (MCPHP_STATS)
#define PHT_ph_rc_built          136   // i64, 8 bytes  every string a call built (MCPHP_STATS, extension road)
#define PHT_ph_outn              144   // i64, 8 bytes
#define PHT_ph_osink             152   // uptr, 8 bytes
#define PHT_ph_nob               160   // i64, 8 bytes
#define PHT_ph_obx               168   // uptr, 8 bytes
#define PHT_ph_dfile             176   // uptr, 8 bytes
#define PHT_ph_dline             184   // i64, 8 bytes
#define PHT_ph_erep              192   // i64, 8 bytes  error_reporting(); E_ALL is 30719 on 8.5
#define PHT_ph_disp              200   // i64, 8 bytes  display_errors
#define PHT_ph_log               208   // i64, 8 bytes  log_errors
#define PHT_ph_quiet             216   // i64, 8 bytes  the @ operator's depth, and ob-internal use
#define PHT_ph_ehz               224   // uptr, 8 bytes  the current handler, 0 = none
#define PHT_ph_ehprev            232   // uptr, 8 bytes
#define PHT_ph_ehmask            240   // i64, 8 bytes
#define PHT_ph_ehin              248   // i64, 8 bytes  1 while it is running
#define PHT_ph_msgn              256   // i64, 8 bytes
#define PHT_ph_dt_ran            264   // i64, 8 bytes
#define PHT_ph_objid             272   // i64, 8 bytes
#define PHT_ph_dt_head           280   // uptr, 8 bytes
#define PHT_ph_seed              288   // u64, 8 bytes
#define PHT_ph_lsb               296   // uptr, 8 bytes
#define PHT_ph_exc               304   // uptr, 8 bytes  the pending throwable, 0 = none
#define PHT_ph_sdfn              312   // uptr, 8 bytes
#define PHT_ph_nsdfn             320   // i64, 8 bytes
#define PHT_ph_tok_s             328   // uptr, 8 bytes
#define PHT_ph_tok_i             336   // i64, 8 bytes
#define PHT_ph_nfh               344   // i64, 8 bytes
#define PHT_ph_mode_rw           352   // i64, 8 bytes  O_RDONLY / O_WRONLY / O_RDWR
#define PHT_ph_mode_app          360   // i64, 8 bytes
#define PHT_ph_mode_trunc        368   // i64, 8 bytes
#define PHT_ph_mode_create       376   // i64, 8 bytes
#define PHT_ph_mode_excl         384   // i64, 8 bytes
#define PHT_ph_xhz               392   // uptr, 8 bytes
#define PHT_ph_xhprev            400   // uptr, 8 bytes
#define PHT_ph_sc_p              408   // i64, 8 bytes
#define PHT_ph_sc_s              416   // uptr, 8 bytes
#define PHT_ph_sc_n              424   // i64, 8 bytes
#define PHT_ph_tmpseq            432   // i64, 8 bytes
#define PHT_ph_uniqseq           440   // i64, 8 bytes
#define PHT_ph_pk                448   // uptr, 8 bytes  the output, grown by php_pk_need
#define PHT_ph_pkn               456   // i64, 8 bytes
#define PHT_ph_pkc               464   // i64, 8 bytes
#define PHT_ph_pk_star           472   // i64, 8 bytes
#define PHT_ph_js_bad            480   // i64, 8 bytes  1 when the input was not UTF-8
#define PHT_ph_jd_p              488   // i64, 8 bytes
#define PHT_ph_jd_s              496   // uptr, 8 bytes
#define PHT_ph_jd_n              504   // i64, 8 bytes
#define PHT_ph_jd_bad            512   // i64, 8 bytes
#define PHT_ph_jd_assoc          520   // i64, 8 bytes
#define PHT_ph_us_p              528   // i64, 8 bytes
#define PHT_ph_us_s              536   // uptr, 8 bytes
#define PHT_ph_us_n              544   // i64, 8 bytes
#define PHT_ph_us_bad            552   // i64, 8 bytes
#define PHT_phx_cl               560   // uptr, 8 bytes
#define PHT_phx_cn               568   // i64, 8 bytes
#define PHT_phx_cc               576   // i64, 8 bytes
#define PHT_phx_keep             584   // i64, 8 bytes
#define PHT_phx_depth            592   // i64, 8 bytes
#define PHT_phx_home             600   // uptr, 8 bytes  the request's reusable chunk
#define PHT_phx_floor            608   // i64, 8 bytes  below it: what pinned calls kept
#define PHT_phx_efloor           616   // i64, 8 bytes  the escaped strings pinned calls kept
#define PHT_phx_dirty            624   // i64, 8 bytes  a call of this request pinned
#define PHT_phx_gen              632   // i64, 8 bytes
#define PHT_phx_zmirror          640   // uptr, 8 bytes  and the runtime object that stands for it
#define PHT_phx_lz               648   // i64, 8 bytes
#define PHT_ph_out               656   // u8[], 4096 bytes
#define PHT_ph_obb              4752   // uptr[], 128 bytes
#define PHT_ph_obn              4880   // i64[], 128 bytes
#define PHT_ph_obc              5008   // i64[], 128 bytes
#define PHT_ph_msg              5136   // u8[], 1024 bytes
#define PHT_ph_fh_fd            6160   // i64[], 512 bytes
#define PHT_ph_fh_eof           6672   // i64[], 512 bytes
#define PHT_ph_fh_own           7184   // i64[], 512 bytes  0 for the three std streams: never closed
#define PHT_ph_fh_name          7696   // uptr[], 512 bytes
#define PHT_ph_rdbuf            8208   // u8[], 4096 bytes
#define PHT_phx_zexcz          12304   // u8[], 16 bytes  the engine exception a call took off it
#define PHT_ph_shared          12320   // i64, 8 bytes  1 from this program's or request's first mcphp_thread_start: counts may race, so nothing is freed or written in place
#define PHT_ph_troot           12328   // uptr, 8 bytes  the program's or request's own block (0 on that block itself)
#define PHT_ph_tret            12336   // uptr, 8 bytes  the joined threads whose memory is kept (a list of their records)
#define PHT_ph_loop           12344   // uptr, 8 bytes  this thread's event loop (docs/threads.md § Step 5); 0 until its first await/spawn -- a program that never awaits allocates none
#define PHT_SIZE 12352

// A ZTS module's words (lib/php_zts.mc, docs/threads.md § ZTS), after the NTS
// block. src/program.mc makes PHT_SIZE cover them for a ZTS output only, so
// an NTS module's block and every byte of it are what they were; a #define
// emits nothing.
#define PHT_phx_eg             12352   // uptr  this php thread's executor globals
#define PHT_ph_globals         12360   // uptr  the global variable table, this request's
#define PHT_ph_consts          12368   // uptr  the constants, this request's
#define PHT_ph_classes         12376   // uptr  the class registry, this request's
#define PHT_ph_ce_closure      12384   // uptr
#define PHT_ph_rsl             12392   // uptr  the statics to reset at the end of the request
#define PHT_phz_init           12400   // i64   1 once a php thread's block is set up
#define PHT_phz_mod            12408   // uptr  this thread's copy of the module's own words (statics, call caches)
#define PHT_phz_sp             12416   // uptr  this request's static-property tables: (class entry, table) pairs
#define PHT_phz_spn            12424   // i64
#define PHT_phz_idm            12432   // uptr  the identity map of a copy: (from, to) pairs
#define PHT_phz_idn            12440   // i64
#define PHT_phz_idc            12448   // i64   its capacity
#define PHT_phx_egx            12456   // i64   EG(exception)'s offset, as this thread measured it
#define PHT_phx_egx_done       12464   // i64   1 once it did (or while RINIT must not)
#define PHT_phz_job            12472   // uptr  a php thread's job, while its call runs (lib/php_zts.mc § 3b)
#define PHT_SIZE_ZTS           12480

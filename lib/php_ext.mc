// php_ext.mc -- the extension runtime: what a PHP extension needs from Zend
// that a standalone program does not.
//
// Pushed into the unit only on the EXTENSION road (src/ext.mc's user_init
// half), never into a program: everything below names a symbol that exists
// inside a running php and nowhere else, and an mc --exe binary with an
// undefined symbol loads and then dies in dyld (mc's M11 note).
//
// Every offset and every constant here is MEASURED. tests/ext/abi.c prints
// the same list from the installed php headers with offsetof/sizeof and
// tests/ext.sh diffs the two, exactly as probes/t3 does for the zval. The
// headers are the ORACLE; the compiler never opens one. docs/php-abi.md is
// the record, with the php the numbers were read off.
//
// What it does NOT do, and why it is not an omission: it registers no
// constant and no INI entry, and it declares no module globals. The scope of
// this back end is plain functions -- any signature but a reference, with
// php's arrays and objects crossing (§ engine values) -- and plain classes
// (§ published classes, at the end); everything else is a NAMED refusal in
// src/ext.mc and src/class.mc rather than a silent wrong answer.

// ---- zend_module_entry: Zend/zend_modules.h --------------------------------
#define MEX_SIZE            168
#define MEX_SIZE_FIELD      0       // u16
#define MEX_ZEND_API        4       // u32
#define MEX_ZEND_DEBUG      8       // u8
#define MEX_ZTS             9       // u8
#define MEX_INI_ENTRY       16
#define MEX_DEPS            24
#define MEX_NAME            32
#define MEX_FUNCTIONS       40
#define MEX_MODULE_STARTUP  48
#define MEX_MODULE_SHUTDOWN 56
#define MEX_REQUEST_STARTUP 64
#define MEX_REQUEST_SHUTDOWN 72
#define MEX_VERSION         88
#define MEX_BUILD_ID        160

// ---- zend_function_entry: Zend/zend_API.h ----------------------------------
#define FEX_SIZE            48
#define FEX_FNAME           0
#define FEX_HANDLER         8
#define FEX_ARG_INFO        16
#define FEX_NUM_ARGS        24      // u32
#define FEX_FLAGS           28      // u32

// ---- zend_internal_arg_info: Zend/zend_compile.h ---------------------------
// Entry 0 is not a parameter: its `name` carries the REQUIRED argument count
// and its type_mask the RETURN type. Entry i is parameter i.
#define AIX_SIZE            32
#define AIX_NAME            0
#define AIX_TYPE_PTR        8       // zend_type.ptr, 0 for a simple type
#define AIX_TYPE_MASK       16      // zend_type.type_mask, u32
#define AIX_DEFAULT_VALUE   24

// ---- zval / zend_string / zend_execute_data (probes/t3's, re-measured) -----
#define ZVX_SIZE            16
#define ZVX_VALUE           0
#define ZVX_TYPE_INFO       8       // u32: type | type_flags << 8
#define EXX_NUM_ARGS        44      // u32
#define EXX_ARG1            80      // ZEND_CALL_FRAME_SLOT * sizeof(zval)
#define ZSX_HDR             24      // refcount u32 | type_info u32 | h u64 | len u64 | val[]
#define ZSX_LEN             16
#define ZSX_VAL             24
#define ZSX_GC_STRING       22      // GC_STRING: refcounted, not interned
#define ZSX_INTERNED        64      // IS_STR_INTERNED (GC_IMMUTABLE) in type_info
#define ZSX_PERSIST         128     // IS_STR_PERSISTENT (GC_PERSISTENT): pefree, i.e. free(3)

// Zend/zend_types.h: the type tags, and the two flags a zval carries
#define IZ_UNDEF            0
#define IZ_NULL             1
#define IZ_FALSE            2
#define IZ_TRUE             3
#define IZ_LONG             4
#define IZ_DOUBLE           5
#define IZ_STRING           6
#define IZ_ARRAY            7
#define IZ_OBJECT           8
#define IZ_RESOURCE         9
#define IZ_REFERENCE        10
#define IZ_STRING_EX        262     // IS_STRING | IS_TYPE_REFCOUNTED << 8

// a type_mask for one simple type is 1 << that tag (MAY_BE_LONG is 1 << 4)
#define MAYBE_NULL          2
#define MAYBE_FALSE         4
#define MAYBE_TRUE          8
#define MAYBE_BOOL          12
#define MAYBE_LONG          16
#define MAYBE_DOUBLE        32
#define MAYBE_STRING        64
#define MAYBE_VOID          16384

// zend_object.ce, zend_class_entry.name -- for the class NAME php puts in a
// TypeError ("must be of type int, stdClass given")
#define ZOX_CE              16
#define ZCX_NAME            8

// ---- what an extension reaches out to --------------------------------------
// All four are exported from the php binary; T2 proved a bundle resolves an
// mc binary's symbols and these go the other way, which is the ordinary one.
// zend_type_error and zend_argument_count_error are variadic; a call with NO
// varargs and a format carrying no `%` is safe on every ABI here, because the
// named argument travels in a register. The messages below are built whole by
// the runtime and every part of one is an identifier or a decimal, so a `%`
// cannot appear in one.
// Zend/zend_alloc.h: in a php built with --enable-debug each of the three
// takes the caller's file and line twice more (ZEND_FILE_LINE_DC and
// ZEND_FILE_LINE_ORIG_DC), and the debug allocator keeps them in the block to
// name a leak at request end. So the module always passes them: a release
// php's function takes only the first argument(s) and never reads the rest,
// which travel in registers the callee does not look at, and a debug php gets
// "mc-php" where a C extension's would say its source file.
extern uptr _emalloc(i64 n, uptr f, i64 l, uptr of, i64 ol);
extern uptr _erealloc(uptr p, i64 n, uptr f, i64 l, uptr of, i64 ol);
extern void _efree(uptr p, uptr f, i64 l, uptr of, i64 ol);
extern void free(uptr p);
extern void zend_type_error(uptr fmt);
extern void zend_argument_count_error(uptr fmt);
extern uptr zend_throw_exception(uptr ce, uptr msg, i64 code);
extern uptr zend_lookup_class(uptr name);
extern i64 php_output_write(uptr str, i64 len);
// php's output layer, for the ob_* functions a module calls (phx_ob). Each
// answers a zend_result, an int: 0 is SUCCESS.
extern i32 php_output_start_default();
extern i32 php_output_get_contents(uptr zv);
extern i32 php_output_get_length(uptr zv);
extern i32 php_output_get_level();
extern i32 php_output_discard();
extern i32 php_output_end();
extern i32 php_output_flush();

// defined further down; mc reads a unit once
i64  phx_rshutdown(i64 mtype, i64 mnum);

// Zend's allocator, as the runtime calls it (php_rt.mc § who owns a string, and
// the call's chunk below). lib/php_prog.mc defines the same four names on the
// program road, where nothing reaches them.
uptr phx_em(i64 n) { return _emalloc(n, "mc-php", 0, 0, 0); }

// Every string the runtime builds inside a call: php's zend_string_alloc laid
// by hand over _emalloc -- refcount 1 and GC_STRING in one store, hash 0, the
// length, the NUL -- and pushed on the pool as a temporary. The n bytes are
// the caller's to write. Outside a call (MINIT) it is module memory, the
// arena's, as on the program road.
uptr php_str_alloc(i64 n) { uptr phT = ph_tcur; if (!phT) phT = ph_tslow();
    if (!((uptr) ld64(phT + PHT_ph_zalloc))) return php_str_mk(n, 1);
    // a size that wrapped negative is a huge size_t to _emalloc, which php's
    // memory limit refuses by name
    uptr s = _emalloc(ZSX_HDR + n + 1, "mc-php", 0, 0, 0);
    st64(phT + PHT_ph_rc_built, ld64(phT + PHT_ph_rc_built) + 1);
    st64(s, 94489280513);                       // refcount 1 | GC_STRING (22) << 32
    st64(s + 8, 0);
    st64(s + ZSX_LEN, n);
    st8(s + ZSX_VAL + n, 0);
    i64 k = ld64(phT + PHT_ph_pn);
    if (k < ld64(phT + PHT_ph_pcap)) { st64(((uptr) ld64(phT + PHT_ph_pool)) + (k << 3), s); st64(phT + PHT_ph_pn, k + 1); return s; }
    php_pool_push(s);
    return s;
}

// php's pefree for a string whose count reached zero
void php_str_free(uptr s) { uptr phT = ph_tcur; if (!phT) phT = ph_tslow();
    // shared mode (docs/threads.md § Step 3): once a thread has started,
    // counts may have raced, so a string is not freed now but at RSHUTDOWN
    if (ld64(phT + PHT_ph_shared)) { php_str_defer(phT, s); return; }
    if (ld32(s + 4) & ZSX_PERSIST) { free(s); return; }
    _efree(s, "mc-php", 0, 0, 0);
}

// The temporaries above mark m die (php_rt.mc § who owns a string): every
// return and every loop iteration of the compiled code comes here, so the
// free is in the loop itself. A pool entry is never 0 and never interned.
void php_rc_drain(i64 m) { uptr phT = ph_tcur; if (!phT) phT = ph_tslow();
    i64 i = ld64(phT + PHT_ph_pn);
    uptr p = ((uptr) ld64(phT + PHT_ph_pool));
    loop {
        if (i <= m) break;
        i = i - 1;
        uptr s = ld64(p + (i << 3));
        i64 rc = ld32(s);
        if (rc > 1) { st32(s, rc - 1); continue; }
        if (ld64(phT + PHT_ph_shared)) { php_str_defer(phT, s); continue; }
        if (ld32(s + 4) & ZSX_PERSIST) { free(s); continue; }
        _efree(s, "mc-php", 0, 0, 0);
    }
    if (ld64(phT + PHT_ph_pn) > m) st64(phT + PHT_ph_pn, m);
}
void phx_ef(uptr p) { _efree(p, "mc-php", 0, 0, 0); }

// Shared mode's deferred frees: a string whose count reached zero while
// counts could race waits here, tagged with its request, and is freed once
// by that request's own thread at RSHUTDOWN, after every thread of it has
// ended (php_str_undefer). A race may have counted it to zero twice, so the
// list may hold it twice; the free takes each once. Process memory, under
// the runtime's lock: any thread of the request may add to it.
uptr ph_dfr;                        // (root, string) pairs
i64  ph_dfrn;
i64  ph_dfrc;
void php_str_defer(uptr phT, uptr s) {
    uptr root = ld64(phT + PHT_ph_troot);
    if (!root) root = phT;
    ph_lock();
    if (ph_dfrn == ph_dfrc) {
        i64 c = ph_dfrc * 2 + 1024;
        uptr t = ph_os_map(c * 16);
        if (!t) { ph_unlock(); php_die("mc-php: cannot map the deferred frees\n", 38); }
        i64 i = 0;
        loop { if (i >= ph_dfrn * 2) break; st64(t + i * 8, ld64(ph_dfr + i * 8)); i = i + 1; }
        if (ph_dfr) ph_os_unmap(ph_dfr, ph_dfrc * 16);
        ph_dfr = t;
        ph_dfrc = c;
    }
    st64(ph_dfr + ph_dfrn * 16, root);
    st64(ph_dfr + ph_dfrn * 16 + 8, s);
    ph_dfrn = ph_dfrn + 1;
    ph_unlock();
}
void php_str_undefer(uptr root) {
    ph_lock();
    // this request's entries to the front, the others after them
    i64 m = 0;
    i64 i = 0;
    loop {
        if (i >= ph_dfrn) break;
        if (ld64(ph_dfr + i * 16) == root) {
            uptr r = ld64(ph_dfr + m * 16);
            uptr v = ld64(ph_dfr + m * 16 + 8);
            st64(ph_dfr + m * 16, ld64(ph_dfr + i * 16));
            st64(ph_dfr + m * 16 + 8, ld64(ph_dfr + i * 16 + 8));
            st64(ph_dfr + i * 16, r);
            st64(ph_dfr + i * 16 + 8, v);
            m = m + 1;
        }
        i = i + 1;
    }
    // sorted by address (shell sort, in place: no allocation here), so a
    // string listed twice is freed once
    i64 gap = m / 2;
    loop {
        if (gap < 1) break;
        i = gap;
        loop {
            if (i >= m) break;
            uptr v = ld64(ph_dfr + i * 16 + 8);
            i64 j = i;
            loop {
                if (j < gap) break;
                uptr w = ld64(ph_dfr + (j - gap) * 16 + 8);
                if (w <= v) break;
                st64(ph_dfr + j * 16 + 8, w);
                j = j - gap;
            }
            st64(ph_dfr + j * 16 + 8, v);
            i = i + 1;
        }
        gap = gap / 2;
    }
    uptr last = 0;
    i = 0;
    loop {
        if (i >= m) break;
        uptr s = ld64(ph_dfr + i * 16 + 8);
        if (s != last) {
            if (ld32(s + 4) & ZSX_PERSIST) free(s);
            if (!(ld32(s + 4) & ZSX_PERSIST)) _efree(s, "mc-php", 0, 0, 0);
            last = s;
        }
        i = i + 1;
    }
    // the other requests' entries move down
    i = m;
    loop {
        if (i >= ph_dfrn) break;
        st64(ph_dfr + (i - m) * 16, ld64(ph_dfr + i * 16));
        st64(ph_dfr + (i - m) * 16 + 8, ld64(ph_dfr + i * 16 + 8));
        i = i + 1;
    }
    ph_dfrn = ph_dfrn - m;
    ph_unlock();
}
uptr phx_er(uptr p, i64 n) { return _erealloc(p, n, "mc-php", 0, 0, 0); }
void phx_pf(uptr p) { free(p); }

// ---- the tables the module entry points at ---------------------------------
// Filled by get_module() at CALL time rather than laid out as initialised
// data: mc has no relocation inside a global initialiser for `&function`, and
// the engine copies the module entry the moment it takes it, so a table built
// one instruction before it is read is enough. What must survive is the
// arrays, and those are globals.
#define PHX_MAXFN   256
#define PHX_MAXAI   3328            // (1 + 12) * 256

u8  phx_me[168];
u8  phx_fe[12336];                  // (PHX_MAXFN + 1) * FEX_SIZE, the last row zero
u8  phx_ai[106496];                 // PHX_MAXAI * AIX_SIZE
i64 phx_nfn;
i64 phx_nai;

void phx_owrite(uptr b, i64 n) { php_output_write(b, n); }

// The ob_* family on this road: php's own stack (php_rt.mc's ph_obx). What
// the runtime has buffered goes to php first, so a level starts and stops
// exactly where the source says. The failures answer what the program road's
// answer (false, no notice).
i64 phx_ob(i64 op) {
    php_flush();
    if (op == PHOB_START) return php_output_start_default() == 0;
    i64 lv = php_output_get_level();
    if (op == PHOB_LEVEL) return lv;
    if (!lv) {
        if (op == PHOB_GET_CLEAN || op == PHOB_CONTENTS || op == PHOB_LENGTH || op == PHOB_GET_FLUSH)
            return php_zbool(0);
        return 0;
    }
    if (op == PHOB_END_CLEAN) return php_output_discard() == 0;
    if (op == PHOB_END_FLUSH) return php_output_end() == 0;
    if (op == PHOB_FLUSH) return php_output_flush() == 0;
    u8 z[16];
    if (op == PHOB_LENGTH) {
        if (php_output_get_length(z) != 0) return php_zbool(0);
        return php_zlong(ld64(z));
    }
    // a copy of the buffer (IS_STRING, refcount 1): ours, then released
    if (php_output_get_contents(z) != 0) return php_zbool(0);
    uptr zs = ld64(z);
    uptr r = php_str_new(zs + ZSX_VAL, ld64(zs + ZSX_LEN));
    if (!(ld32(zs + 4) & ZSX_INTERNED)) {
        st32(zs, ld32(zs) - 1);
        if (!ld32(zs)) phx_ef(zs);
    }
    if (op == PHOB_GET_CLEAN) php_output_discard();
    if (op == PHOB_GET_FLUSH) php_output_end();
    return php_zstr(r);
}

// ---- building the tables ---------------------------------------------------
// The compiler names a php TYPE by docs/plan.md D10's code (PT_INT is 0, the
// same vocabulary php_rt.mc's var_dump already takes as literals), never a
// Zend type_mask: one place knows what a mask is, and it is this one.
i64 phx_mask(i64 pt) {
    if (pt == 0) return MAYBE_LONG;             // int
    if (pt == 1) return MAYBE_DOUBLE;           // float
    if (pt == 2) return MAYBE_STRING;           // string
    if (pt == 3) return MAYBE_BOOL;             // bool
    if (pt == 4) return MAYBE_VOID;             // void
    return 0;
}

void phx_fn(uptr name, uptr handler, i64 nreq, i64 retpt) {
    if (phx_nfn >= PHX_MAXFN) php_die("mc-php: too many exported functions\n", 36);
    if (phx_nai >= PHX_MAXAI) php_die("mc-php: too many argument records\n", 34);
    uptr e = phx_fe + phx_nfn * FEX_SIZE;
    uptr a = phx_ai + phx_nai * AIX_SIZE;
    st64(e + FEX_FNAME, name);
    st64(e + FEX_HANDLER, handler);
    st64(e + FEX_ARG_INFO, a);
    st32(e + FEX_NUM_ARGS, 0);
    st32(e + FEX_FLAGS, 0);
    st64(a + AIX_NAME, nreq);       // not a pointer: the required-argument count
    st64(a + AIX_TYPE_PTR, 0);
    st32(a + AIX_TYPE_MASK, phx_mask(retpt));
    st64(a + AIX_DEFAULT_VALUE, 0);
    phx_nai = phx_nai + 1;
    phx_nfn = phx_nfn + 1;
}

void phx_arg(uptr name, i64 pt) {
    if (!phx_nfn) php_die("mc-php: an argument record with no function\n", 44);
    if (phx_nai >= PHX_MAXAI) php_die("mc-php: too many argument records\n", 34);
    uptr e = phx_fe + (phx_nfn - 1) * FEX_SIZE;
    uptr a = phx_ai + phx_nai * AIX_SIZE;
    st32(e + FEX_NUM_ARGS, ld32(e + FEX_NUM_ARGS) + 1);
    st64(a + AIX_NAME, name);
    st64(a + AIX_TYPE_PTR, 0);
    st32(a + AIX_TYPE_MASK, phx_mask(pt));
    st64(a + AIX_DEFAULT_VALUE, 0);
    phx_nai = phx_nai + 1;
}

// The whole module header. php's dl.c compares zend_api, zend_debug, zts and
// build_id against its own and refuses the bundle by name when one differs,
// which is why all four come from the target php and never from this file.
uptr phx_module(uptr name, uptr version, i64 api, uptr build_id,
                i64 zts, i64 dbg, uptr minit, uptr mshutdown) { uptr phT = ph_tcur; if (!phT) phT = ph_tslow();
    // Output goes through php's own output layer from here on: what the
    // module echoes passes every ob_start() level the script opened, as an
    // internal function's php_printf does (before a request is active, php
    // writes it straight through). Set here, before MINIT runs, and never on
    // the program road.
    //
    // Through a local function and not &php_output_write: mc materialises
    // the address of an extern with adrp/add, which Apple's ld refuses for a
    // symbol the bundle resolves at load time (docs/plan.md § 5).
    st64(phT + PHT_ph_osink, &phx_owrite);
    phx_eng_init();
    st64(phT + PHT_ph_obx, &phx_ob);
    st16(phx_me + MEX_SIZE_FIELD, MEX_SIZE);
    st32(phx_me + MEX_ZEND_API, api);
    st8(phx_me + MEX_ZEND_DEBUG, dbg);
    st8(phx_me + MEX_ZTS, zts);
    st64(phx_me + MEX_INI_ENTRY, 0);
    st64(phx_me + MEX_DEPS, 0);
    st64(phx_me + MEX_NAME, name);
    st64(phx_me + MEX_FUNCTIONS, phx_fe);
    st64(phx_me + MEX_MODULE_STARTUP, minit);
    st64(phx_me + MEX_MODULE_SHUTDOWN, mshutdown);
    st64(phx_me + MEX_REQUEST_STARTUP, 0);
    st64(phx_me + MEX_REQUEST_SHUTDOWN, &phx_rshutdown);
    st64(phx_me + MEX_VERSION, version);
    st64(phx_me + MEX_BUILD_ID, build_id);
    return phx_me;
}

// ---- reading one argument --------------------------------------------------
uptr phx_argz(uptr ex, i64 k) { return ex + EXX_ARG1 + k * ZVX_SIZE; }
i64  phx_nargs(uptr ex) { return ld32(ex + EXX_NUM_ARGS); }

// The TYPE of a zval is its type_info's LOW BYTE: a string carries 0x106 and
// an object 0x308, so a whole-word comparison answers no for both.
i64 phx_type(uptr z) { return ld32(z + ZVX_TYPE_INFO) % 256; }

// php's own word for the value's type in a TypeError, measured against php
// 8.5.10 (an object gives its CLASS name, and a bool gives `true`/`false`
// rather than `bool`).
uptr phx_tname(uptr z) {
    i64 t = phx_type(z);
    if (t == IZ_UNDEF)    return php_str_new("null", 4);
    if (t == IZ_NULL)     return php_str_new("null", 4);
    if (t == IZ_FALSE)    return php_str_new("false", 5);
    if (t == IZ_TRUE)     return php_str_new("true", 4);
    if (t == IZ_LONG)     return php_str_new("int", 3);
    if (t == IZ_DOUBLE)   return php_str_new("float", 5);
    if (t == IZ_STRING)   return php_str_new("string", 6);
    if (t == IZ_ARRAY)    return php_str_new("array", 5);
    if (t == IZ_RESOURCE) return php_str_new("resource", 8);
    if (t == IZ_REFERENCE) return php_str_new("reference", 9);
    if (t == IZ_OBJECT) {
        uptr ce = ld64(ld64(z + ZVX_VALUE) + ZOX_CE);
        uptr n = ld64(ce + ZCX_NAME);
        return php_str_new(n + ZSX_VAL, ld64(n + ZSX_LEN));
    }
    return php_str_new("mixed", 5);
}

// ---- the two refusals, in php's own words ----------------------------------
// Measured against a reference extension built the ordinary C way
// (tests/ext/refx.c): an INTERNAL function's messages are not a userland
// function's, and they carry no "called in FILE on line N" tail.
void phx_too_many(uptr fname, i64 want, i64 got) {
    uptr s = php_str_new(fname, php_cstrlen(fname));
    s = php_str_concat(s, php_str_new("() expects exactly ", 19));
    s = php_str_concat(s, php_itos(want));
    if (want == 1) s = php_str_concat(s, php_str_new(" argument, ", 11));
    if (want != 1) s = php_str_concat(s, php_str_new(" arguments, ", 12));
    s = php_str_concat(s, php_itos(got));
    s = php_str_concat(s, php_str_new(" given", 6));
    zend_argument_count_error(s + ZSX_VAL);
}

void phx_bad_type(uptr fname, i64 k, uptr pname, uptr want, uptr z) {
    uptr s = php_str_new(fname, php_cstrlen(fname));
    s = php_str_concat(s, php_str_new("(): Argument #", 14));
    s = php_str_concat(s, php_itos(k + 1));
    // a variadic parameter's arguments are named by number alone, as php's
    // own parameter parsing names them
    if (ld8(pname)) {
        s = php_str_concat(s, php_str_new(" ($", 3));
        s = php_str_concat(s, php_str_new(pname, php_cstrlen(pname)));
        s = php_str_concat(s, php_str_new(")", 1));
    }
    s = php_str_concat(s, php_str_new(" must be of type ", 17));
    s = php_str_concat(s, php_str_new(want, php_cstrlen(want)));
    s = php_str_concat(s, php_str_new(", ", 2));
    s = php_str_concat(s, phx_tname(z));
    s = php_str_concat(s, php_str_new(" given", 6));
    zend_type_error(s + ZSX_VAL);
}

// ---- the handler's prologue ------------------------------------------------
// Arity first, then one check per parameter, in php's own order: a call with
// the wrong count is an ArgumentCountError whatever the arguments look like.
i64 phx_arity(uptr ex, i64 want, uptr fname) {
    i64 got = phx_nargs(ex);
    if (got == want) return 1;
    phx_too_many(fname, want, got);
    return 0;
}

// The declared types this back end accepts, and nothing else. The rule is
// php's STRICT one (docs/php-extension.md § What strict_types means here):
// an exact tag, plus int where a float is declared, which is the one
// widening php allows in strict mode.
i64 phx_chk(uptr ex, i64 k, i64 pt, uptr fname, uptr pname) {
    uptr z = phx_argz(ex, k);
    i64 t = phx_type(z);
    if (pt == 0) { if (t == IZ_LONG) return 1; phx_bad_type(fname, k, pname, "int", z); return 0; }
    if (pt == 1) {
        if (t == IZ_DOUBLE) return 1;
        if (t == IZ_LONG) return 1;
        phx_bad_type(fname, k, pname, "float", z);
        return 0;
    }
    if (pt == 2) { if (t == IZ_STRING) return 1; phx_bad_type(fname, k, pname, "string", z); return 0; }
    if (pt == 3) {
        if (t == IZ_TRUE) return 1;
        if (t == IZ_FALSE) return 1;
        phx_bad_type(fname, k, pname, "bool", z);
        return 0;
    }
    return 1;
}

// ---- one argument, converted -----------------------------------------------
i64 phx_i(uptr ex, i64 k) { return ld64(phx_argz(ex, k) + ZVX_VALUE); }
u8  phx_b(uptr ex, i64 k) { if (phx_type(phx_argz(ex, k)) == IZ_TRUE) return 1; return 0; }

f64 phx_f(uptr ex, i64 k) {
    uptr z = phx_argz(ex, k);
    // the one widening: an int where a float is declared
    if (phx_type(z) == IZ_LONG) return (f64) ld64(z + ZVX_VALUE);
    return ldf64(z + ZVX_VALUE);
}

// BORROWED, not copied: the runtime's string IS a zend_string (probes/t3
// measured the layout, docs/php-abi.md records it), and the engine keeps the
// argument alive until the call returns. A php function whose body never
// assigns the parameter reads the engine's string where it stands; one that
// assigns it takes a reference at entry and drops it on the way out
// (src/rc.mc), and anything that stores it where it outlives a statement
// takes its own (php_str_esc) -- so nothing here needs to remember which
// strings were borrowed. The runtime may write the hash into it -- the same
// DJBX33A, top bit set, that zend_string_hash_val stores, and never into an
// interned string, whose hash is already there.
uptr phx_s(uptr ex, i64 k) { return ld64(phx_argz(ex, k) + ZVX_VALUE); }

// ---- the return value ------------------------------------------------------
// return_value arrives IS_NULL, so a void function writes nothing.
void phx_ret_int(uptr rv, i64 v) {
    st64(rv + ZVX_VALUE, v);
    st32(rv + ZVX_TYPE_INFO, IZ_LONG);
}

void phx_ret_bool(uptr rv, u8 v) {
    st64(rv + ZVX_VALUE, 0);
    if (v) st32(rv + ZVX_TYPE_INFO, IZ_TRUE);
    if (!v) st32(rv + ZVX_TYPE_INFO, IZ_FALSE);
}

void phx_ret_float(uptr rv, f64 v) {
    stf64(rv + ZVX_VALUE, v);
    st32(rv + ZVX_TYPE_INFO, IZ_DOUBLE);
}

// A zend_string the ENGINE owns, copied from one of ours: only for the class
// name phx_throw looks up (the lookup may keep the key).
uptr phx_zstr(uptr s) {
    i64 n = ld64(s + ZSX_LEN);
    uptr z = phx_em(ZSX_HDR + n + 1);
    st32(z, 1);
    st32(z + 4, ZSX_GC_STRING);
    st64(z + 8, 0);
    st64(z + ZSX_LEN, n);
    php_memcpy(z + ZSX_VAL, s + ZSX_VAL, n);
    st8(z + ZSX_VAL + n, 0);
    return z;
}

// The answer is the SAME zend_string, never a copy: every string a call
// builds is already a Zend block laid as php's, so return_value takes a
// reference to it -- the one the answer carried as the call's temporary when
// it is that (the common case: the php function's return pushed it), else a
// new one (an argument handed straight back, a string a zval holds). A
// string of the module's -- a literal, a one-byte string, anything MINIT
// built -- is IS_STR_INTERNED, and goes out the way php hands out an
// interned string: tagged IS_STRING, with no reference taken.
void phx_ret_str(uptr rv, uptr s) {
    st64(rv + ZVX_VALUE, s);
    if (ld32(s + 4) & ZSX_INTERNED) { st32(rv + ZVX_TYPE_INFO, IZ_STRING); return; }
    php_rc_take(s);
    st32(rv + ZVX_TYPE_INFO, IZ_STRING_EX);
}

// ---- the call's memory -----------------------------------------------------
// STRINGS are not here: each one is a zend_string of its own with php's
// refcount (php_rt.mc § who owns a string), and a call returns with none of
// its temporaries left (the pool drained to zero) and its escaped ones
// released. What IS here is everything else a call builds -- the zvals, the
// arrays, the objects, the class entries -- which have no count in this
// runtime (docs/php-extension.md § The memory says why), so they live in a
// Zend chunk the call bumps through (php_rt.mc's php_alloc seam); this file
// is the slow path and the bookkeeping. The request has one HOME chunk the
// calls reuse: when a call returns, every other block the call took -- a
// second chunk, a block too big for one -- is freed, and the next call bumps
// through the home chunk again from where the request's pinned calls left it.
// Nothing is zeroed: every allocation site writes what it reads. A PINNED
// call's part stays: the next call starts above it (phx_floor), and its
// escaped strings stay with it. The list is [phx_keep, phx_cn) for the call
// and [0, phx_keep) for what the request's PINNED calls kept; RSHUTDOWN frees
// all of it.
#define PHX_CK   32768

i64  phx_mark;                      // the arena's top when MINIT ended
uptr phx_snap;                      // and a copy of the arena below it

void phx_grow() { uptr phT = ph_tcur; if (!phT) phT = ph_tslow();
    i64 nc = ld64(phT + PHT_phx_cc) * 2 + 256;
    uptr nl = phx_em(nc * 8);
    i64 i = 0;
    loop { if (i >= ld64(phT + PHT_phx_cn)) break; st64(nl + i * 8, ld64(((uptr) ld64(phT + PHT_phx_cl)) + i * 8)); i = i + 1; }
    if (((uptr) ld64(phT + PHT_phx_cl))) phx_ef(((uptr) ld64(phT + PHT_phx_cl)));
    st64(phT + PHT_phx_cl, nl);
    st64(phT + PHT_phx_cc, nc);
}

void phx_track(uptr p) { uptr phT = ph_tcur; if (!phT) phT = ph_tslow();
    if (ld64(phT + PHT_phx_cn) == ld64(phT + PHT_phx_cc)) phx_grow();
    st64(((uptr) ld64(phT + PHT_phx_cl)) + ld64(phT + PHT_phx_cn) * 8, p);
    st64(phT + PHT_phx_cn, ld64(phT + PHT_phx_cn) + 1);
}

// the slow path: a block too big for a chunk gets its own, and a full chunk
// gets a successor
uptr phx_zalloc(i64 n) { uptr phT = ph_tcur; if (!phT) phT = ph_tslow();
    // a size that wrapped negative (PHP_INT_MAX bytes and a header) is a
    // huge one: Zend's allocator refuses it with php's own memory fatal
    if (n > PH_ZBIG || n < 0) {
        uptr b = phx_em(n);
        phx_track(b);
        return b;
    }
    uptr c = phx_em(PHX_CK);
    phx_track(c);
    st64(phT + PHT_ph_zcur, c);
    st64(phT + PHT_ph_zlim, PHX_CK);
    st64(phT + PHT_ph_zpos, n);
    return c;
}

// a block this call made: taken OUT of the list
i64 phx_take(uptr p) { uptr phT = ph_tcur; if (!phT) phT = ph_tslow();
    i64 i = ld64(phT + PHT_phx_cn);
    loop {
        if (i <= ld64(phT + PHT_phx_keep)) break;
        i = i - 1;
        if (ld64(((uptr) ld64(phT + PHT_phx_cl)) + i * 8) == p) { st64(((uptr) ld64(phT + PHT_phx_cl)) + i * 8, 0); return 1; }
    }
    return 0;
}

// free every block of the list from `from` up
void phx_free_from(i64 from) { uptr phT = ph_tcur; if (!phT) phT = ph_tslow();
    i64 i = from;
    loop {
        if (i >= ld64(phT + PHT_phx_cn)) break;
        uptr b = ld64(((uptr) ld64(phT + PHT_phx_cl)) + i * 8);
        if (b) phx_ef(b);
        i = i + 1;
    }
    st64(phT + PHT_phx_cn, from);
}

// the escaped strings from `from` up lose the reference the chunk held
void phx_esc_from(i64 from) { uptr phT = ph_tcur; if (!phT) phT = ph_tslow();
    i64 i = ld64(phT + PHT_ph_en);
    loop {
        if (i <= from) break;
        i = i - 1;
        uptr e = ld64(((uptr) ld64(phT + PHT_ph_esc)) + i * 8);
        // bit 0: an engine array or object (§ engine values), not a string
        if (e & 1) phx_unhold(e - 1);
        else php_str_release(e);
    }
    if (ld64(phT + PHT_ph_en) > from) st64(phT + PHT_ph_en, from);
}

// What a call held, released with the call still OPEN (phx_leave_slow): the
// last reference to an engine object runs its __destruct, and when that is a
// method of this module it is a call nested in this release -- on this
// call's allocator, which must not be torn down yet (it was, and a destructor
// that allocated corrupted php's heap). What those destructors hold in turn
// lands above the list's top: it is released next round, unless one of them
// pinned the call (a global it wrote), and then it is kept with the call.
void phx_esc_open() { uptr phT = ph_tcur; if (!phT) phT = ph_tslow();
    st64(phT + PHT_phx_depth, 1);
    loop {
        i64 top = ld64(phT + PHT_ph_en);
        if (top <= ld64(phT + PHT_phx_efloor)) break;
        i64 i = top;
        loop {
            if (i <= ld64(phT + PHT_phx_efloor)) break;
            i = i - 1;
            uptr e = ld64(((uptr) ld64(phT + PHT_ph_esc)) + i * 8);
            st64(((uptr) ld64(phT + PHT_ph_esc)) + i * 8, 0);
            if (e & 1) phx_unhold(e - 1);
            else if (e) php_str_release(e);
        }
        i64 k = 0;
        loop { if (top + k >= ld64(phT + PHT_ph_en)) break; st64(((uptr) ld64(phT + PHT_ph_esc)) + (ld64(phT + PHT_phx_efloor) + k) * 8, ld64(((uptr) ld64(phT + PHT_ph_esc)) + (top + k) * 8)); k = k + 1; }
        st64(phT + PHT_ph_en, ld64(phT + PHT_phx_efloor) + k);
        if (ld64(phT + PHT_ph_pin) || ld64(phT + PHT_ph_nob)) break;
    }
    st64(phT + PHT_phx_depth, 0);
}

// the arena and its copy are 8-aligned, and the copy has 8 bytes to spare
void phx_copy(uptr d, uptr s, i64 n) {
    i64 i = 0;
    loop { if (i >= n) break; st64(d + i, ld64(s + i)); i = i + 8; }
}

// MINIT ends here: what it built is module state, and a copy of it is what
// every request that changed it is put back to
void phx_snapshot() { uptr phT = ph_tcur; if (!phT) phT = ph_tslow();
    // the one class every proxy has, module memory like the rest of MINIT's
    phx_pce = php_ce_alloc(php_str_new("mc-php engine object", 20));
    php_ce_flag(phx_pce, 32);
    phx_mark = ld64(phT + PHT_ph_top);
    phx_snap = php_alloc(phx_mark + 8);
    phx_copy(phx_snap, ph_heap, phx_mark);
    php_roots(1);
}

// MCPHP_STATS=1 in php's environment: at the end of each request, what the
// string discipline did -- how many writes were in place and how many copied,
// and how many strings the request built at all (every _emalloc of one, a
// copy included). tests/ext.sh's in-place gate and tests/examples.sh's count
// of decimal's strings read it. Written
// from a byte buffer: RSHUTDOWN runs outside a call, where a string would be
// the module's arena and stay for good.
i64 phx_stats = 0 - 1;
i64 phx_put_n(uptr b, i64 w, i64 v) {
    u8 t[24];
    i64 k = 0;
    loop { st8(t + k, 48 + v % 10); v = v / 10; k = k + 1; if (!v) break; }
    loop { if (!k) break; k = k - 1; st8(b + w, ld8(t + k)); w = w + 1; }
    return w;
}
void phx_put_s(uptr b, uptr w, uptr s) {
    i64 i = 0;
    loop { i64 c = ld8(s + i); if (!c) break; st8(b + ld64(w), c); st64(w, ld64(w) + 1); i = i + 1; }
}
void phx_stat_line() { uptr phT = ph_tcur; if (!phT) phT = ph_tslow();
    if (phx_stats < 0) {
        phx_stats = 0;
        uptr v = getenv("MCPHP_STATS");
        if (v) { if (ld8(v) == '1') phx_stats = 1; }
    }
    if (!phx_stats) return;
    u8 b[128];
    u8 w[8];
    st64(w, 0);
    phx_put_s(b, w, "mc-php stats: in place ");
    st64(w, phx_put_n(b, ld64(w), ld64(phT + PHT_ph_rc_inplace)));
    phx_put_s(b, w, ", copied ");
    st64(w, phx_put_n(b, ld64(w), ld64(phT + PHT_ph_rc_copied)));
    phx_put_s(b, w, ", strings built ");
    st64(w, phx_put_n(b, ld64(w), ld64(phT + PHT_ph_rc_built)));
    phx_put_s(b, w, "\n");
    write(2, b, ld64(w));
}

// RSHUTDOWN: the request's state goes back to what MINIT left, and what the
// request's pinned calls kept is freed -- Zend would free it anyway at the
// end of the request; freeing it here keeps a debug php's leak report quiet.
// the request a call through php's function table cached its function in,
// and the engine exception one of them holds (both below)
void phx_zexc_drop();

i64 phx_rshutdown(i64 mtype, i64 mnum) { uptr phT = ph_tcur; if (!phT) phT = ph_tslow();
    // every thread this request started ends with it (docs/threads.md §
    // Step 3): waited for, joined or detached; one neither joined nor
    // detached that ended on a throwable is reported, as a warning -- the
    // request is over, there is nothing left to catch it
    uptr te = php_thr_endall(phT, 0, 0);
    if (te) php_thr_report(te);
    php_flush();
    php_request_reset();
    // a userland function a call site cached is gone with the request
    st64(phT + PHT_phx_gen, ld64(phT + PHT_phx_gen) + 1);
    phx_zexc_drop();
    if (ld64(phT + PHT_phx_dirty)) {
        phx_copy(ph_heap, phx_snap, phx_mark);
        st64(phT + PHT_phx_dirty, 0);
    }
    phx_stat_line();
    st64(phT + PHT_ph_rc_inplace, 0);
    st64(phT + PHT_ph_rc_copied, 0);
    st64(phT + PHT_ph_rc_built, 0);
    // the kept strings go while their holders are still readable, then the
    // blocks that held them
    phx_esc_from(0);
    st64(phT + PHT_phx_efloor, 0);
    if (((uptr) ld64(phT + PHT_ph_esc))) phx_ef(((uptr) ld64(phT + PHT_ph_esc)));
    st64(phT + PHT_ph_esc, 0);
    st64(phT + PHT_ph_ecap, 0);
    if (((uptr) ld64(phT + PHT_ph_pool))) phx_ef(((uptr) ld64(phT + PHT_ph_pool)));
    st64(phT + PHT_ph_pool, 0);
    st64(phT + PHT_ph_pcap, 0);
    st64(phT + PHT_ph_pn, 0);
    phx_free_from(0);
    if (((uptr) ld64(phT + PHT_phx_home))) phx_ef(((uptr) ld64(phT + PHT_phx_home)));
    st64(phT + PHT_phx_home, 0);
    st64(phT + PHT_phx_floor, 0);
    if (((uptr) ld64(phT + PHT_phx_cl))) phx_ef(((uptr) ld64(phT + PHT_phx_cl)));
    st64(phT + PHT_phx_cl, 0);
    st64(phT + PHT_phx_cc, 0);
    st64(phT + PHT_phx_keep, 0);
    // last: the strings shared mode kept, the memory the request's threads
    // kept, and shared mode off
    if (ld64(phT + PHT_ph_shared)) php_str_undefer(phT);
    php_thr_endall(phT, 1, 0);
    return 0;
}

// ---- around every handler --------------------------------------------------
// The common call: the runtime is up, no call is open and the home chunk
// exists -- a handful of stores, written in place by src/opt.mc (the first
// call and a nested one take phx_enter_slow)
uptr phx_zalloc_fn;
void phx_enter_slow();
void phx_enter() { uptr phT = ph_tcur; if (!phT) phT = ph_tslow();
    if (ph_boot_done && !ld64(phT + PHT_phx_depth) && ((uptr) ld64(phT + PHT_phx_home))) {
        st64(phT + PHT_ph_pin, 0);
        st64(phT + PHT_ph_zcur, ((uptr) ld64(phT + PHT_phx_home)));
        st64(phT + PHT_ph_zpos, ld64(phT + PHT_phx_floor));
        st64(phT + PHT_ph_zlim, PHX_CK);
        st64(phT + PHT_phx_depth, 1);
        st64(phT + PHT_ph_zalloc, phx_zalloc_fn);
    } else phx_enter_slow();
}
void phx_enter_slow() { uptr phT = ph_tcur; if (!phT) phT = ph_tslow();
    php_bootstrap();
    // a request's first call (MINIT has ended): nothing is pending
    if (!phx_egx_done && phx_mark && phx_eg) phx_egx_find();
    phx_zalloc_fn = &phx_zalloc;
    if (!ld64(phT + PHT_phx_depth)) {
        st64(phT + PHT_ph_pin, 0);
        if (!((uptr) ld64(phT + PHT_phx_home))) st64(phT + PHT_phx_home, phx_em(PHX_CK));
        st64(phT + PHT_ph_zcur, ((uptr) ld64(phT + PHT_phx_home)));
        st64(phT + PHT_ph_zpos, ld64(phT + PHT_phx_floor));
        st64(phT + PHT_ph_zlim, PHX_CK);
    }
    st64(phT + PHT_phx_depth, ld64(phT + PHT_phx_depth) + 1);
    st64(phT + PHT_ph_zalloc, &phx_zalloc);
}

// The runtime buffers what a php function echoes and flushes it at the end of
// a PROGRAM (php_rt.mc's ph_out); an extension has no end of program, so the
// buffer is flushed at the end of every call.
//
// And a php-level `throw` inside the body leaves the runtime's own pending
// flag set (D7 has no VM and no setjmp: T6's mechanism is a flag). Left
// alone it would be a silently wrong answer -- the handler would return a
// value the program never produced -- so it becomes a Zend exception with
// the same message and class name in its text.
void phx_throw() { uptr phT = ph_tcur; if (!phT) phT = ph_tslow();
    if (!((uptr) ld64(phT + PHT_ph_exc))) return;
    uptr o = ld64(((uptr) ld64(phT + PHT_ph_exc)));
    // the engine's own, taken off it by phx_zcatch and not caught here (or
    // rethrown as it was): the engine's object goes back, trace and all
    if (((uptr) ld64(phT + PHT_phx_zmirror)) && o == ((uptr) ld64(phT + PHT_phx_zmirror))) {
        st64(phT + PHT_ph_exc, 0);
        uptr e = ld64((phT + PHT_phx_zexcz));
        st64((phT + PHT_phx_zexcz), 0);
        st64((phT + PHT_phx_zexcz) + 8, 0);
        st64(phT + PHT_phx_zmirror, 0);
        zend_throw_exception_internal(e);
        return;
    }
    st64(phT + PHT_ph_exc, 0);
    zend_throw_exception_internal(phx_exc_obj(o));
}

// A runtime throwable as the engine's object, with one reference for the
// caller: thrown out of a handler (phx_throw) or stored where php reads it
// (phx_r2e). The CLASS, when the engine has one of that name -- every php
// built-in does, so `throw new InvalidArgumentException(...)` crosses the
// boundary as itself, with its message and code. A class this program
// DECLARED is the engine's only if the module publishes it, and a throwable
// class is not published yet: the fallback is a plain Exception whose message
// names the class, and it is written down rather than silent
// (docs/php-extension.md § What differs). object_init_ex runs the class's
// create handler, which is what gives it php's file and line -- the
// statement that is executing, as zend_throw_exception would.
// A class of the engine's by name. The name is ours only for the lookup:
// released the way the engine releases a string, in case an autoloader kept
// a reference.
uptr phx_lookup(uptr name) {
    uptr cz = phx_zstr(name);
    uptr ce = zend_lookup_class(cz);
    st32(cz, ld32(cz) - 1);
    if (!ld32(cz)) phx_ef(cz);
    return ce;
}

uptr phx_exc_obj(uptr o) {
    uptr cn = php_obj_cname(o);
    uptr m = php_zv_str(php_exm_message(o));
    uptr ce = phx_lookup(cn);
    uptr s = m;
    i64 code = 0;
    if (ce) code = php_zv_long(php_exm_code(o));
    if (!ce) {
        ce = phx_lookup(php_str_new("Exception", 9));
        s = cn;
        if (php_strlen(m)) {
            s = php_str_concat(s, php_str_new(": ", 2));
            s = php_str_concat(s, m);
        }
    }
    u8 z[16];
    object_init_ex(z, ce);
    uptr e = ld64(z);
    u8 v[16];
    phx_r2e(php_zstr(s), v);
    zend_update_property(zend_get_exception_base(e), e, "message", 7, v);
    zval_ptr_dtor(v);
    if (code) {
        st64(v, code);
        st32(v + ZVX_TYPE_INFO, IZ_LONG);
        zend_update_property(zend_get_exception_base(e), e, "code", 4, v);
    }
    return e;
}

// The common return: nothing echoed, nothing thrown, the outermost call, nothing
// pinned and nothing kept past the floors -- the call's strings go and the
// allocator is put back. Written in place by src/opt.mc; the rest is
// phx_leave_slow, which is the whole story.
void phx_leave_slow();
void phx_leave() { uptr phT = ph_tcur; if (!phT) phT = ph_tslow();
    if (!ld64(phT + PHT_ph_outn) && !((uptr) ld64(phT + PHT_ph_exc)) && ld64(phT + PHT_phx_depth) == 1 && !ld64(phT + PHT_ph_nob) && !ld64(phT + PHT_ph_pin) && ld64(phT + PHT_ph_en) == ld64(phT + PHT_phx_efloor) && ld64(phT + PHT_phx_cn) == ld64(phT + PHT_phx_keep) && !((uptr) ld64(phT + PHT_phx_zmirror))) {
        st64(phT + PHT_phx_depth, 0);
        php_rc_drain(0);
        st64(phT + PHT_ph_zalloc, 0);
        st64(phT + PHT_ph_zcur, 0);
        st64(phT + PHT_ph_zlim, 0);
    } else phx_leave_slow();
}
void phx_leave_slow() { uptr phT = ph_tcur; if (!phT) phT = ph_tslow();
    php_flush();
    phx_throw();
    // MINIT's own end: not a call
    if (!ld64(phT + PHT_phx_depth)) { if (!phx_mark) phx_snapshot(); return; }
    st64(phT + PHT_phx_depth, ld64(phT + PHT_phx_depth) - 1);
    if (ld64(phT + PHT_phx_depth)) return;
    // what the call held goes while the call is still open (phx_esc_open)
    if (!ld64(phT + PHT_ph_pin) && !ld64(phT + PHT_ph_nob) && ld64(phT + PHT_ph_en) > ld64(phT + PHT_phx_efloor)) {
        phx_esc_open();
        php_flush();
        phx_throw();
    }
    // the runtime object that stood for a caught engine exception is made of
    // the call's memory: kept past it, a later call's object at the same
    // address would be taken for it (phx_throw, phx_r2e)
    phx_zexc_drop();
    // the call's temporaries die: whatever it answered, return_value has its
    // own reference by now (phx_ret_str)
    php_rc_drain(0);
    uptr cur = ((uptr) ld64(phT + PHT_ph_zcur));
    i64 pos = ld64(phT + PHT_ph_zpos);
    st64(phT + PHT_ph_zalloc, 0);
    st64(phT + PHT_ph_zcur, 0);
    st64(phT + PHT_ph_zlim, 0);
    // an output buffer the call left open is made of the call's blocks
    if (ld64(phT + PHT_ph_nob)) st64(phT + PHT_ph_pin, 1);
    if (ld64(phT + PHT_ph_pin)) {
        // what the call used is kept, and the strings its blocks hold with it;
        // the chunk it ended in is where the next call goes on bumping, so a
        // pinned call costs its own bytes and not a chunk
        if (cur != ((uptr) ld64(phT + PHT_phx_home))) {
            phx_take(cur);
            phx_track(((uptr) ld64(phT + PHT_phx_home)));
            st64(phT + PHT_phx_home, cur);
        }
        st64(phT + PHT_phx_floor, pos);
        st64(phT + PHT_phx_keep, ld64(phT + PHT_phx_cn));
        st64(phT + PHT_phx_efloor, ld64(phT + PHT_ph_en));
        st64(phT + PHT_phx_dirty, 1);
        return;
    }
    // the strings the call's zvals, keys and rows held are released while
    // those blocks are still there, then the blocks go
    phx_esc_from(ld64(phT + PHT_phx_efloor));
    phx_free_from(ld64(phT + PHT_phx_keep));
}

// ---- a call through php's function table -----------------------------------
// A function the source does not declare and the runtime's library does not
// have is looked up where php looks it up: EG(function_table), when the call
// RUNS. Another extension, php itself or the script may define it. It is what
// a C extension does to call a function that belongs to another one
// (examples/two-extensions/c/extB.c): the zend_function found once and
// cached, the arguments laid out as engine zvals on the stack, and
// zend_call_known_function. Each call site caches what it found in two words
// the compiler emits beside it -- the pointer and the request it was found in
// -- because a function table does not shrink during a request and a userland
// function is gone at its end (RSHUTDOWN moves phx_gen on).
//
// zend_function's common.function_name and zend_reference.val: tests/ext/abi.c
// prints both from the installed headers, as it does the rest of this file.
#define ZRX_VAL             8       // zend_reference: the zval after its gc header
#define ZCX_PARENT          16      // zend_class_entry.parent, once linked
#define IZ_OBJECT_EX        776     // IS_OBJECT | (REFCOUNTED | COLLECTABLE) << 8

// ZEND_FASTCALL, which is __vectorcall in an MSVC php: an alias on Windows
// (src/win/php8.def), the ordinary convention for its two integer arguments.
extern uptr zend_fetch_function_str(uptr name, i64 len);
extern void zend_call_known_function(uptr fn, uptr obj, uptr scope, uptr rv, i64 n, uptr params, uptr named);
extern void zval_ptr_dtor(uptr zv);
extern uptr zend_read_property(uptr scope, uptr obj, uptr name, i64 len, i64 silent, uptr rv);
extern uptr zend_get_exception_base(uptr obj);
extern void zend_clear_exception();
extern void zend_throw_exception_internal(uptr obj);

// An exception the CALLEE threw, taken off the engine so that the module's
// own `catch` sees it, as the same source interpreted would: phx_zexcz holds
// a reference to the engine's object and phx_zmirror is the runtime object
// that stands for it -- the nearest class the runtime knows (every throwable
// descends from one it does), the same message, code, file and line.
// Uncaught, or rethrown as it is, the ENGINE's object goes back with its own
// class and trace (phx_throw).
//
// ponytail: one slot, released by the next one or at the end of the
// outermost call -- not when the module's catch is done with it. A second
// one taken while an outer mirror is still pending crosses as the runtime
// exception it was converted to (its class and message, not its trace), and
// an exception class with a destructor sees it run late.

void phx_zexc_drop() { uptr phT = ph_tcur; if (!phT) phT = ph_tslow();
    if (phx_type((phT + PHT_phx_zexcz)) == IZ_OBJECT) zval_ptr_dtor((phT + PHT_phx_zexcz));
    st64((phT + PHT_phx_zexcz), 0);
    st64((phT + PHT_phx_zexcz) + 8, 0);
    st64(phT + PHT_phx_zmirror, 0);
}

// a declared property of an engine throwable, read as its base class sees it
uptr phx_zprop(uptr e, uptr name, uptr rv) {
    return zend_read_property(zend_get_exception_base(e), e, name, php_cstrlen(name), 1, rv);
}

// the property's string, or "" when it is not one
uptr phx_zpstr(uptr e, uptr name) {
    u8 rv[16];
    uptr z = phx_zprop(e, name, rv);
    if (phx_type(z) != IZ_STRING) return php_str_new("", 0);
    uptr s = ld64(z);
    return php_str_new(s + ZSX_VAL, ld64(s + ZSX_LEN));
}

void phx_zcatch() { uptr phT = ph_tcur; if (!phT) phT = ph_tslow();
    // There is no exported way to read EG(exception); throwing a second one
    // on top of it is: php makes the pending one its `previous`, which can be
    // read, and clearing the second releases it and nothing else.
    uptr x = zend_throw_exception(0, "", 0);
    u8 rv[16];
    uptr pz = phx_zprop(x, "previous", rv);
    if (phx_type(pz) != IZ_OBJECT) {
        // the call failed and threw nothing php can hand over
        zend_clear_exception();
        php_throw_cls(php_str_new("Error", 5),
                      php_str_new("mc-php: a call through php's function table failed", 50));
        return;
    }
    uptr e = ld64(pz);
    phx_zexc_drop();
    st32(e, ld32(e) + 1);                   // GC_ADDREF: our reference
    st64((phT + PHT_phx_zexcz), e);
    st32((phT + PHT_phx_zexcz) + 8, IZ_OBJECT_EX);
    zend_clear_exception();
    // the nearest class the runtime has, walking up from the engine's
    uptr ce = ld64(e + ZOX_CE);
    uptr cn = php_str_new("Exception", 9);
    loop {
        if (!ce) break;
        uptr n = ld64(ce + ZCX_NAME);
        uptr cs = php_str_new(n + ZSX_VAL, ld64(n + ZSX_LEN));
        if (php_ce_find(cs)) { cn = cs; break; }
        ce = ld64(ce + ZCX_PARENT);
    }
    php_throw_cls(cn, phx_zpstr(e, "message"));
    uptr pr = php_obj_props(ld64(((uptr) ld64(phT + PHT_ph_exc))));
    u8 r2[16];
    uptr cz = phx_zprop(e, "code", r2);
    if (phx_type(cz) == IZ_LONG) php_zv_cp(php_arr_sslot(pr, php_str_new("code", 4)), php_zlong(ld64(cz)));
    php_zv_cp(php_arr_sslot(pr, php_str_new("file", 4)), php_zstr(phx_zpstr(e, "file")));
    u8 r3[16];
    uptr lz = phx_zprop(e, "line", r3);
    if (phx_type(lz) == IZ_LONG) php_zv_cp(php_arr_sslot(pr, php_str_new("line", 4)), php_zlong(ld64(lz)));
    st64(phT + PHT_phx_zmirror, ld64(((uptr) ld64(phT + PHT_ph_exc))));
}

// "Call to undefined function a_add()", thrown as the RUNTIME's own Error at
// the position the compiler announced: catchable by the module's source, and
// crossing into php at leave with that message (phx_throw).
uptr phx_undefined(uptr name) {
    uptr m = php_str_new("Call to undefined function ", 27);
    m = php_str_concat(m, php_str_new(name, php_cstrlen(name)));
    m = php_str_concat(m, php_str_new("()", 2));
    php_throw_cls(php_str_new("Error", 5), m);
    return php_znull();
}

uptr phx_nocross(uptr what, uptr name) {
    uptr m = php_str_new("mc-php: a php ", 14);
    m = php_str_concat(m, php_str_new(what, php_cstrlen(what)));
    m = php_str_concat(m, php_str_new(name, php_cstrlen(name)));
    m = php_str_concat(m, php_str_new("(): a resource does not cross php's function table", 50));
    php_throw_cls(php_str_new("Error", 5), m);
    return php_znull();
}

// One argument into an engine zval at d. The compiler says what it is (t,
// one byte of the call's packed word): an int or a string as itself
// (IZ_LONG, IZ_STRING), a bool as IZ_FALSE with the value 0 or 1, and
// anything else (0) as a runtime zval, whose scalar layout is the engine's.
// A string -- the runtime's IS a zend_string -- is passed as it stands: the
// engine copies the zval into the callee's frame and takes its own reference
// there, so the callee may keep it. 0 is "cannot cross".
// An array or an object crosses as the engine's own (§ engine values): the
// answer is then 2, a zval the call owns and releases after.
void phx_r2e(uptr z, uptr ez);
i64 phx_zin(uptr d, i64 v, i64 t) {
    if (t == IZ_LONG) { st64(d, v); st32(d + ZVX_TYPE_INFO, t); return 1; }
    if (!t) {
        t = ld8(v + 8);
        if (t == IZ_UNDEF) t = IZ_NULL;
        if (t == IZ_ARRAY || t == IZ_OBJECT) { phx_r2e(v, d); return 2; }
        if (t > IZ_STRING) return 0;
        v = ld64(v);
    }
    if (t == IZ_FALSE) t = t + v;
    st64(d, v);
    if (t == IZ_STRING && !(ld32(v + 4) & ZSX_INTERNED)) t = IZ_STRING_EX;
    st32(d + ZVX_TYPE_INFO, t);
    return 1;
}

// A handler's BARE road (src/ext.mc) runs with no call context at all; a
// call through the function table is the one thing it may do that can need
// one, and only on its slow side. The compiler marks such a call LAZY (its
// last argument): its slow side takes a context then (phx_enter_lz) and
// phx_lz says so, so the handler's end gives it back (phx_leave_lz). phx_lz
// is cleared around the engine call, because the callee may be one of this
// module's own handlers, and restored after.
void phx_enter_lz() { uptr phT = ph_tcur; if (!phT) phT = ph_tslow(); if (ld64(phT + PHT_phx_lz)) return; phx_enter(); st64(phT + PHT_phx_lz, 1); }
void phx_leave_lz() { uptr phT = ph_tcur; if (!phT) phT = ph_tslow(); st64(phT + PHT_phx_lz, 0); phx_leave(); }

// A call site's words, emitted beside it by the compiler: what it found and
// the request it found it in, then what only a slow road reads -- the name as
// the source spells it, the function the call is in (a TypeError names it)
// and the packed word below.
#define PHF_FN      0
#define PHF_GEN     8
#define PHF_NAME    16
#define PHF_IN      24
#define PHF_NT      32

// A thread other than the one php runs on (lib/php_rt.mc § other threads)
// must not enter the engine: a php built without ZTS has one executor and
// one allocator for the process. Every road into it -- a call through php's
// function table, a php callable, a proxy's property or method, a published
// class's `new` -- asks here first and answers the runtime's Error instead.
i64 phx_offthread(uptr phT) {
    if (!ld64(phT + PHT_ph_tidx)) return 0;
    php_throw_cls(php_str_new("Error", 5),
                  php_str_new("mc-php: php's engine called from another thread (this php has one engine for the process)", 89));
    return 1;
}

// The function a call site names, found and cached: 0 when php has none, and
// then php's own Error is pending in the runtime.
uptr phx_flook(uptr c, i64 lazy) { uptr phT = ph_tcur; if (!phT) phT = ph_tslow();
    if (phx_offthread(phT)) return 0;
    if (lazy) phx_enter_lz();
    // the table's key is lowercase: php compares a name case-insensitively
    uptr name = ld64(c + PHF_NAME);
    i64 len = php_cstrlen(name);
    uptr l = php_case(php_str_new(name, len), 0);
    uptr f = zend_fetch_function_str(l + ZSX_VAL, len);
    // an unqualified name inside a namespace: `ns\name`, then the global one
    if (!f && (ld64(c + PHF_NT) >> 48) & 1) {
        i64 k = len;
        loop { if (k == 0) break; if (ld8(name + k - 1) == 92) break; k = k - 1; }
        f = zend_fetch_function_str(l + ZSX_VAL + k, len - k);
    }
    if (!f) { phx_undefined(name); return 0; }
    st64(c + PHF_FN, f);
    st64(c + PHF_GEN, ld64(phT + PHT_phx_gen));
    return f;
}

// The call itself: the site's packed word has the argument count in its low
// byte and each argument's kind in the next four (phx_zin). The answer is
// left in the engine zval r; 0 when an argument could not cross (and the
// runtime's Error is pending).
i64 phx_fcall_do(uptr f, uptr c, i64 v1, i64 v2, i64 v3, i64 v4, uptr r, i64 lazy) { uptr phT = ph_tcur; if (!phT) phT = ph_tslow();
    if (phx_offthread(phT)) return 0;
    u8 pz[64];
    i64 nt = ld64(c + PHF_NT);
    i64 n = nt & 255;
    i64 ok = 1;
    u8 own[4];
    st32(own, 0);
    if (n > 0) { ok = phx_zin(pz, v1, (nt >> 8) & 255); st8(own, ok == 2); }
    if (n > 1 && ok) { ok = phx_zin(pz + 16, v2, (nt >> 16) & 255); st8(own + 1, ok == 2); }
    if (n > 2 && ok) { ok = phx_zin(pz + 32, v3, (nt >> 24) & 255); st8(own + 2, ok == 2); }
    if (n > 3 && ok) { ok = phx_zin(pz + 48, v4, (nt >> 32) & 255); st8(own + 3, ok == 2); }
    if (!ok) {
        i64 j = 0;
        loop { if (j >= 4) break; if (ld8(own + j)) zval_ptr_dtor(pz + j * 16); j = j + 1; }
        if (lazy) phx_enter_lz();
        phx_nocross("resource passed to ", ld64(c + PHF_NAME));
        return 0;
    }
    st32(r + ZVX_TYPE_INFO, IZ_UNDEF);
    // what the module echoed so far goes out BEFORE the callee's own output
    if (ld64(phT + PHT_ph_outn)) php_flush();
    i64 lz = ld64(phT + PHT_phx_lz);
    st64(phT + PHT_phx_lz, 0);
    zend_call_known_function(f, 0, 0, r, n, pz, 0);
    st64(phT + PHT_phx_lz, lz);
    i64 j = 0;
    loop { if (j >= 4) break; if (ld8(own + j)) zval_ptr_dtor(pz + j * 16); j = j + 1; }
    return 1;
}

// The engine's answer in r, as a runtime zval z (r may be z): a scalar as it
// is, a string with the engine's reference now the call's, a reference
// followed; an exception the callee threw taken off the engine
// (phx_zcatch), and what cannot cross refused.
uptr phx_fres(uptr r, uptr z, uptr name) {
    i64 t = ld8(r + ZVX_TYPE_INFO);
    st64(z, ld64(r));
    if (t <= IZ_DOUBLE) {
        if (t == IZ_UNDEF) { phx_zcatch(); t = IZ_NULL; }
        st64(z + ZVX_TYPE_INFO, t);
        return z;
    }
    if (t == IZ_REFERENCE) {
        // `function &f()`: the value it refers to, and the reference released
        u8 rz[16];
        st64(rz, ld64(r));
        st64(rz + 8, ld64(r + 8));
        uptr in = ld64(rz) + ZRX_VAL;
        t = ld8(in + ZVX_TYPE_INFO);
        if (t == IZ_ARRAY || t == IZ_OBJECT) {
            phx_e2r_into(in, z);
            zval_ptr_dtor(rz);
            return z;
        }
        if (t > IZ_STRING) {
            zval_ptr_dtor(rz);
            return phx_nocross("resource returned by ", name);
        }
        st64(z, ld64(in));
        st64(z + ZVX_TYPE_INFO, t);
        if (t == IZ_STRING && !(ld32(ld64(in) + 4) & ZSX_INTERNED)) st32(ld64(in), ld32(ld64(in)) + 1);
        zval_ptr_dtor(rz);
        if (t != IZ_STRING) return z;
    }
    if (t == IZ_ARRAY || t == IZ_OBJECT) {
        // the engine's answer, copied or proxied, then its reference given
        // back (from a copy of the zval: r may be z itself)
        u8 rc[16];
        st64(rc, ld64(r));
        st64(rc + 8, ld64(r + 8));
        phx_e2r_into(rc, z);
        zval_ptr_dtor(rc);
        return z;
    }
    if (t != IZ_STRING) {
        zval_ptr_dtor(r);
        return phx_nocross("resource returned by ", name);
    }
    // the engine's reference becomes the call's: kept until the call's
    // memory goes, as every string a runtime zval holds (php_str_esc)
    uptr s = ld64(z);
    st64(z + ZVX_TYPE_INFO, IZ_STRING);
    if (!(ld32(s + 4) & ZSX_INTERNED)) { php_str_esc(s); st32(s, ld32(s) - 1); }
    return z;
}

// A call site that names the function, `a_add($x, $y)` the source does not
// declare: the answer as a runtime zval, which the context types. `nt` is the
// site's packed word again, for src/lvalue.mc to read off the call.
uptr phx_fcall(uptr c, i64 nt, i64 v1, i64 v2, i64 v3, i64 v4) { uptr phT = ph_tcur; if (!phT) phT = ph_tslow();
    uptr f = ld64(c + PHF_FN);
    if (!f || ld64(c + PHF_GEN) != ld64(phT + PHT_phx_gen)) f = phx_flook(c, 0);
    if (!f) return php_znull();
    uptr z = php_alloc(ZVX_SIZE);
    if (!phx_fcall_do(f, c, v1, v2, v3, v4, z, 0)) return php_znull();
    return phx_fres(z, z, ld64(c + PHF_NAME));
}

// The same call as the value of `return` in a function declared `: int`:
// what the C twin does -- the arguments laid out as engine zvals, the call,
// and the answer read out of the zval on the stack when it is an int.
// Anything else takes php's return-value rule (php_param_coerce, argno 0),
// in a call context (phx_enter_lz when the call is lazy).
i64 phx_fl_slow(uptr r, uptr c, i64 lazy) { uptr phT = ph_tcur; if (!phT) phT = ph_tslow();
    if (lazy) phx_enter_lz();
    uptr z = phx_fres(r, php_alloc(ZVX_SIZE), ld64(c + PHF_NAME));
    if (((uptr) ld64(phT + PHT_ph_exc))) return 0;
    uptr fn = ld64(c + PHF_IN);
    z = php_param_coerce(z, PC_INT, php_str_new("", 0), php_str_new(fn, php_cstrlen(fn)), 0, php_str_new("", 0));
    if (((uptr) ld64(phT + PHT_ph_exc))) return 0;
    return php_zv_long(z);
}

i64 phx_fcall_l(uptr c, i64 nt, i64 v1, i64 v2, i64 v3, i64 v4, i64 lazy) { uptr phT = ph_tcur; if (!phT) phT = ph_tslow();
    uptr f = ld64(c + PHF_FN);
    if (!f || ld64(c + PHF_GEN) != ld64(phT + PHT_phx_gen)) f = phx_flook(c, lazy);
    if (!f) return 0;
    u8 r[16];
    if (!phx_fcall_do(f, c, v1, v2, v3, v4, r, lazy)) return 0;
    if (ld8(r + ZVX_TYPE_INFO) == IZ_LONG) return ld64(r);
    return phx_fl_slow(r, c, lazy);
}

// and its common case, two ints, written in place: one call, as the twin's
i64 phx_fcall_l2(uptr c, i64 v1, i64 v2, i64 lazy) { uptr phT = ph_tcur; if (!phT) phT = ph_tslow();
    uptr f = ld64(c + PHF_FN);
    if (!f || ld64(c + PHF_GEN) != ld64(phT + PHT_phx_gen)) return phx_fcall_l(c, 0, v1, v2, 0, 0, lazy);
    u8 pz[48];                                  // the two arguments, then the answer
    st64(pz, v1);
    st32(pz + ZVX_TYPE_INFO, IZ_LONG);
    st64(pz + 16, v2);
    st32(pz + 16 + ZVX_TYPE_INFO, IZ_LONG);
    st32(pz + 32 + ZVX_TYPE_INFO, IZ_UNDEF);
    if (ld64(phT + PHT_ph_outn)) php_flush();
    i64 lz = ld64(phT + PHT_phx_lz);
    if (lz) st64(phT + PHT_phx_lz, 0);
    zend_call_known_function(f, 0, 0, pz + 32, 2, pz, 0);
    if (lz) st64(phT + PHT_phx_lz, lz);
    if (ld8(pz + 32 + ZVX_TYPE_INFO) == IZ_LONG) return ld64(pz + 32);
    return phx_fl_slow(pz + 32, c, lazy);
}

// ---- engine values: php's arrays and objects inside the module ---------------
// A php ARRAY crosses as a copy -- it is a value in php, so a copy is what the
// callee would have had anyway -- and a php OBJECT as a PROXY: a runtime object
// of the one class phx_pce, flag 32, with the zend_object after its header
// (lib/php_rt.mc § an ENGINE object inside the runtime). What the module does
// to a proxy -- read or write a property, call a method, ask its class or
// instanceof -- is done to the engine's object, with the engine's rules and
// the engine's errors. A string is the engine's zend_string either way.
//
// Each engine object or array the module holds is a REFERENCE it took, kept
// on the same list as the strings a call escapes (ph_esc), tagged by bit 0,
// and given back where those are: when the call's memory goes, or at
// RSHUTDOWN for a call that pinned (phx_esc_from).
#define EGX_EXCEPTION       960     // zend_executor_globals.exception
// a php callable on a thread of its own (lib/php_zts.mc § 3b): the
// engine's tables and the few php, SAPI and compiler globals a worker
// request sets, a function and a class entry as the share and the copy read
// them, and a Closure's own layout (Zend/zend_closures.c's zend_closure,
// which no header declares; tests/ext/abi.c spells it out to grade it)
#define EGX_FUNCTION_TABLE  456
#define EGX_CLASS_TABLE     464
#define CGX_MAP_PTR_LAST    528
#define SGX_HEADERS_SENT    249
#define SGX_NO_HEADERS      73
#define PGX_EXPOSE_PHP      448
#define PGX_AUTO_GLOBALS_JIT 450
#define PGX_DURING_STARTUP  490
#define PGX_LAST_ERROR_MESSAGE 504
#define ZFX_TYPE            0
#define ZFX_FN_FLAGS        4
#define ZFX_NAME            8
#define ZFX_SCOPE           16
#define ZFX_SIZE            256
#define OPX_STATIC_VARS_PTR 112
#define OPX_REFCOUNT        136
#define IFX_HANDLER         88
#define CEX_TYPE            0
#define ACC_IMMUTABLE       128
#define ACC_HEAP_RT_CACHE   67108864
#define ACC_ENUM            268435456
#define ACC_FAKE_CLOSURE    8388608
#define IZ_INDIRECT         12
#define IZ_PTR              13
#define ZFN_USER            2
#define ZFN_INTERNAL        1
#define ZCE_USER            2
#define ZCLX_FUNC           56
#define ZCLX_THIS           312
#define ZCLX_CALLED         328
#define ZCLX_ORIG           336
#define IZ_ARRAY_EX         775     // IS_ARRAY | (REFCOUNTED | COLLECTABLE) << 8
#define GCX_IMMUTABLE       64      // GC_IMMUTABLE: never counted
#define HASH_KEY_IS_STRING  1
#define PHX_POBJ            40      // where a proxy keeps its zend_object
#define FETCH_NO_AUTOLOAD   128     // ZEND_FETCH_CLASS_NO_AUTOLOAD: instanceof loads nothing

extern uptr _zend_new_array(i64 size);
extern uptr zend_hash_update(uptr ht, uptr key, uptr zv);
extern uptr zend_hash_index_update(uptr ht, i64 h, uptr zv);
extern void zend_hash_internal_pointer_reset_ex(uptr ht, uptr pos);
extern i32  zend_hash_get_current_key_ex(uptr ht, uptr sk, uptr nk, uptr pos);
extern uptr zend_hash_get_current_data_ex(uptr ht, uptr pos);
extern i32  zend_hash_move_forward_ex(uptr ht, uptr pos);
extern void zend_update_property(uptr scope, uptr obj, uptr name, i64 len, uptr zv);
extern i32  zend_call_method_if_exists(uptr obj, uptr name, uptr rv, i64 n, uptr params);
extern uptr zend_lookup_class_ex(uptr name, uptr key, i64 flags);
extern i64  instanceof_function_slow(uptr a, uptr b);

uptr phx_eg;                        // &executor_globals, found at get_module
uptr phx_pce;                       // the proxies' class, made before MINIT ends
u64  phx_engt[7];                   // lib/php_rt.mc's ph_eng

// EG(exception)'s offset, MEASURED once in the first call rather than taken
// from the headers alone: executor_globals is laid out differently on Windows
// (an OSVERSIONINFOEX member sits before it). The first handler runs with
// nothing pending, so an exception thrown there is found among the globals
// and cleared; EGX_EXCEPTION (tests/ext/abi.c) is what it finds elsewhere,
// and the fallback.
i64 phx_egx = EGX_EXCEPTION;
i64 phx_egx_done;
void phx_egx_find() {
    phx_egx_done = 1;
    uptr x = zend_throw_exception(0, "", 0);
    i64 off = 0;
    loop {
        if (off >= 8192) break;
        if (ld64(phx_eg + off) == x) { phx_egx = off; break; }
        off = off + 8;
    }
    zend_clear_exception();
}
i64 phx_zexc() { return ld64(phx_eg + phx_egx) != 0; }

// a reference the module takes on an engine array or object
void phx_hold(uptr p) { uptr phT = ph_tcur; if (!phT) phT = ph_tslow();
    if (ld32(p + 4) & GCX_IMMUTABLE) return;
    st32(p, ld32(p) + 1);
    if (ld64(phT + PHT_ph_en) == ld64(phT + PHT_ph_ecap)) { st64(phT + PHT_ph_ecap, ld64(phT + PHT_ph_ecap) * 2 + 256); st64(phT + PHT_ph_esc, php_rc_grow(((uptr) ld64(phT + PHT_ph_esc)), ld64(phT + PHT_ph_en), ld64(phT + PHT_ph_ecap))); }
    st64(((uptr) ld64(phT + PHT_ph_esc)) + ld64(phT + PHT_ph_en) * 8, p + 1);
    st64(phT + PHT_ph_en, ld64(phT + PHT_ph_en) + 1);
}

// and its release: the zval shape zval_ptr_dtor reads, typed by the block's own
// GC type -- the last reference frees it the engine's way
void phx_unhold(uptr p) {
    u8 z[16];
    st64(z, p);
    st32(z + ZVX_TYPE_INFO, (ld32(p + 4) & 15) | 256);
    zval_ptr_dtor(z);
}

uptr phx_proxy(uptr zo) {
    phx_hold(zo);
    uptr o = php_alloc(PHX_POBJ + 8);
    st32(o, 1);
    st32(o + 4, IS_OBJECT);
    st32(o + 8, 0);
    st64(o + 16, phx_pce);
    st64(o + 24, php_arr_new(1));
    st64(o + 32, 0);
    st64(o + PHX_POBJ, zo);
    return o;
}

// An engine zval, into the runtime zval z. A reference is followed; a
// resource cannot cross and is the runtime's Error.
uptr phx_e2r_arr(uptr ht);
void phx_e2r_into(uptr ez, uptr z) {
    i64 t = phx_type(ez);
    if (t == IZ_REFERENCE) { ez = ld64(ez) + ZRX_VAL; t = phx_type(ez); }
    if (t == IZ_UNDEF) t = IZ_NULL;
    // the type word only: an array bucket's collision link is the u32 above
    // it, and a whole-word store there cut a chain into a loop
    st64(z, ld64(ez));
    st32(z + 8, t);
    if (t == IZ_STRING) php_str_esc(ld64(ez));
    if (t == IZ_ARRAY) st64(z, phx_e2r_arr(ld64(ez)));
    if (t == IZ_OBJECT) st64(z, phx_proxy(ld64(ez)));
    if (t > IZ_REFERENCE || t == IZ_RESOURCE) {
        st64(z, 0);
        st32(z + 8, IZ_NULL);
        php_throw_cls(php_str_new("Error", 5), php_str_new("mc-php: a php resource cannot cross into the module", 51));
    }
}

uptr phx_e2r(uptr ez) {
    uptr z = php_alloc(ZV_SIZE);
    st64(z + 8, 0);
    phx_e2r_into(ez, z);
    return z;
}

uptr phx_e2r_arr(uptr ht) {
    uptr a = php_arr_new(8);
    u8 pos[8];
    st64(pos, 0);
    zend_hash_internal_pointer_reset_ex(ht, pos);
    loop {
        uptr v = zend_hash_get_current_data_ex(ht, pos);
        if (!v) break;
        u8 sk[8];
        u8 nk[8];
        st64(sk, 0);
        st64(nk, 0);
        uptr slot = 0;
        if (zend_hash_get_current_key_ex(ht, sk, nk, pos) == HASH_KEY_IS_STRING)
            slot = php_arr_sslot(a, ld64(sk));
        else slot = php_arr_islot(a, ld64(nk));
        phx_e2r_into(v, slot);
        zend_hash_move_forward_ex(ht, pos);
    }
    return a;
}

// A runtime value, into the engine zval ez with the references it needs: the
// caller owns them, as return_value and an argument array do. A runtime
// object that is not a proxy -- one of a class the module does not publish --
// cannot cross, and is the runtime's Error with null in its place.
uptr phx_r2e_arr(uptr a);
void phx_r2e(uptr z, uptr ez) { uptr phT = ph_tcur; if (!phT) phT = ph_tslow();
    if (!z) { st64(ez, 0); st32(ez + ZVX_TYPE_INFO, IZ_NULL); return; }
    i64 t = php_zv_type(z);
    if (t == IZ_UNDEF) t = IZ_NULL;
    st64(ez, ld64(z));
    st32(ez + ZVX_TYPE_INFO, t);
    if (t == IZ_NULL) st64(ez, 0);
    if (t == IZ_STRING) {
        uptr s = ld64(z);
        if (!(ld32(s + 4) & ZSX_INTERNED)) { st32(s, ld32(s) + 1); st32(ez + ZVX_TYPE_INFO, IZ_STRING_EX); }
    }
    if (t == IZ_ARRAY) { st64(ez, phx_r2e_arr(ld64(z))); st32(ez + ZVX_TYPE_INFO, IZ_ARRAY_EX); }
    if (t == IZ_OBJECT) {
        uptr o = ld64(z);
        // the runtime object that stands for an engine exception the module
        // caught (phx_zcatch): the engine's own object goes back
        if (((uptr) ld64(phT + PHT_phx_zmirror)) && o == ((uptr) ld64(phT + PHT_phx_zmirror)) && phx_type((phT + PHT_phx_zexcz)) == IZ_OBJECT) {
            uptr ze = ld64((phT + PHT_phx_zexcz));
            st32(ze, ld32(ze) + 1);
            st64(ez, ze);
            st32(ez + ZVX_TYPE_INFO, IZ_OBJECT_EX);
            return;
        }
        // a throwable the module made -- caught, kept, stored in an object php
        // reads -- goes as the engine's object of that class (phx_exc_obj)
        if (!php_is_proxy(o) && php_instanceof(z, php_str_new("Throwable", 9))) {
            st64(ez, phx_exc_obj(o));
            st32(ez + ZVX_TYPE_INFO, IZ_OBJECT_EX);
            return;
        }
        if (!php_is_proxy(o)) {
            st64(ez, 0);
            st32(ez + ZVX_TYPE_INFO, IZ_NULL);
            php_throw_cls(php_str_new("Error", 5),
                          php_str_concat(php_str_new("mc-php: an object of a class this module does not publish cannot cross into php: ", 81),
                                         php_obj_cname(o)));
            return;
        }
        uptr zo = ld64(o + PHX_POBJ);
        st32(zo, ld32(zo) + 1);
        st64(ez, zo);
        st32(ez + ZVX_TYPE_INFO, IZ_OBJECT_EX);
    }
    if (t > IZ_OBJECT) { st64(ez, 0); st32(ez + ZVX_TYPE_INFO, IZ_NULL); }
}

uptr phx_r2e_arr(uptr a) {
    i64 used = php_ht_used(a);
    uptr ht = _zend_new_array(php_count(a));
    i64 i = 0;
    loop {
        if (i >= used) break;
        uptr b = php_ht_bkt(a, i);
        i = i + 1;
        if (php_zv_type(b) == IZ_UNDEF) continue;
        u8 ez[16];
        phx_r2e(b, ez);
        uptr k = ld64(b + 24);
        if (k) zend_hash_update(ht, k, ez);
        else zend_hash_index_update(ht, ld64(b + 16), ez);
    }
    return ht;
}

// what an engine call left: an exception the engine now holds becomes the
// runtime's (phx_zcatch), so the module's own catch sees it
void phx_zafter() { if (phx_zexc()) phx_zcatch(); }

// ---- the operations on a proxy (lib/php_rt.mc's ph_eng) --------------------
uptr phx_pcname(uptr o) {
    uptr n = ld64(ld64(ld64(o + PHX_POBJ) + ZOX_CE) + ZCX_NAME);
    return php_str_new(n + ZSX_VAL, ld64(n + ZSX_LEN));
}

// The scope is the runtime's: a class the module publishes is the engine's
// class there (a method reads its own private properties), any other scope
// is no class of the engine's -- public members only.
uptr phx_escope(uptr scope) {
    if (scope && (ld64(scope + 64) & 64)) return ld64(scope + CE_ENG);
    return 0;
}
uptr phx_pget(uptr o, uptr name, uptr scope, i64 quiet) { uptr phT = ph_tcur; if (!phT) phT = ph_tslow();
    if (phx_offthread(phT)) return php_znull();
    if (ld64(phT + PHT_ph_outn)) php_flush();
    uptr zo = ld64(o + PHX_POBJ);
    u8 rv[16];
    st32(rv + ZVX_TYPE_INFO, IZ_UNDEF);
    uptr z = zend_read_property(phx_escope(scope), zo, name + ZSX_VAL, ld64(name + ZSX_LEN), quiet, rv);
    uptr r = phx_e2r(z);
    if (z == rv) zval_ptr_dtor(rv);
    phx_zafter();
    return r;
}

void phx_pset(uptr o, uptr name, uptr v, uptr scope) { uptr phT = ph_tcur; if (!phT) phT = ph_tslow();
    if (phx_offthread(phT)) return;
    if (ld64(phT + PHT_ph_outn)) php_flush();
    u8 ez[16];
    phx_r2e(v, ez);
    zend_update_property(phx_escope(scope), ld64(o + PHX_POBJ), name + ZSX_VAL, ld64(name + ZSX_LEN), ez);
    zval_ptr_dtor(ez);
    phx_zafter();
}

uptr phx_pcall(uptr o, uptr name, i64 n, uptr a1, uptr a2, uptr a3, uptr a4, uptr a5, uptr a6) { uptr phT = ph_tcur; if (!phT) phT = ph_tslow();
    if (phx_offthread(phT)) return php_znull();
    if (ld64(phT + PHT_ph_outn)) php_flush();
    u8 av[96];
    if (n > 0) phx_r2e(a1, av);
    if (n > 1) phx_r2e(a2, av + 16);
    if (n > 2) phx_r2e(a3, av + 32);
    if (n > 3) phx_r2e(a4, av + 48);
    if (n > 4) phx_r2e(a5, av + 64);
    if (n > 5) phx_r2e(a6, av + 80);
    u8 rv[16];
    st32(rv + ZVX_TYPE_INFO, IZ_UNDEF);
    uptr zo = ld64(o + PHX_POBJ);
    i64 lz = ld64(phT + PHT_phx_lz);
    st64(phT + PHT_phx_lz, 0);
    i64 ok = zend_call_method_if_exists(zo, name, rv, n, av) == 0;
    st64(phT + PHT_phx_lz, lz);
    i64 k = 0;
    loop { if (k >= n) break; zval_ptr_dtor(av + k * 16); k = k + 1; }
    if (phx_zexc()) { phx_zcatch(); return php_znull(); }
    // a class with no constructor: `new` calls nothing, as php's own
    if (!ok && php_str_eq(php_case(name, 0), php_str_new("__construct", 11))) return php_znull();
    if (!ok) {
        uptr m = php_str_concat(php_str_new("Call to undefined method ", 25), phx_pcname(o));
        m = php_str_concat(m, php_str_new("::", 2));
        m = php_str_concat(m, name);
        m = php_str_concat(m, php_str_new("()", 2));
        php_throw_cls(php_str_new("Error", 5), m);
        return php_znull();
    }
    uptr r = phx_e2r(rv);
    zval_ptr_dtor(rv);
    return r;
}

// A php callable the module calls that is not the runtime's own closure: a
// function's name, an array callable, an engine object (a Closure, an
// __invoke) -- php resolves and calls it, as the C twin's
// zend_call_function does. What it throws is the module's to catch
// (phx_zcatch); what is not callable is php's own Error.
extern i32 _call_user_function_impl(uptr obj, uptr fn, uptr rv, i64 n, uptr params, uptr named);
uptr phx_vcall(uptr f, i64 n, uptr a1, uptr a2, uptr a3, uptr a4, uptr a5) { uptr phT = ph_tcur; if (!phT) phT = ph_tslow();
    if (phx_offthread(phT)) return php_znull();
    if (ld64(phT + PHT_ph_outn)) php_flush();
    // a spread's slots past the end of its array are 0, "not passed"
    // (php_unpack_at): php counts only the arguments there are
    if (n > 0 && !a1) n = 0;
    if (n > 1 && !a2) n = 1;
    if (n > 2 && !a3) n = 2;
    if (n > 3 && !a4) n = 3;
    if (n > 4 && !a5) n = 4;
    u8 fz[16];
    phx_r2e(f, fz);
    // not callable: php's own Error, in the words `$f()` says for a name, an
    // object and a scalar (an array's and a "C::m" string's are php's
    // "Invalid callback ..." of zend_call_function below)
    if (!(zend_is_callable_ex(fz, 0, 0, 0, 0, 0) & 255)) {
        i64 t = php_zv_type(f);
        uptr m = 0;
        if (t == IS_STRING && php_strpos(ld64(f), php_str_new("::", 2), 0) < 0)
            m = php_str_concat(php_str_concat(php_str_new("Call to undefined function ", 27), ld64(f)), php_str_new("()", 2));
        if (t == IS_OBJECT)
            m = php_str_concat(php_str_concat(php_str_new("Object of type ", 15), php_obj_cname(ld64(f))), php_str_new(" is not callable", 16));
        if (t != IS_STRING && t != IS_ARRAY && t != IS_OBJECT)
            m = php_str_concat(php_str_concat(php_str_new("Value of type ", 14), php_f_get_debug_type(f)), php_str_new(" is not callable", 16));
        if (m) {
            zval_ptr_dtor(fz);
            php_throw_cls(php_str_new("Error", 5), m);
            return php_znull();
        }
    }
    u8 av[80];
    if (n > 0) phx_r2e(a1, av);
    if (n > 1) phx_r2e(a2, av + 16);
    if (n > 2) phx_r2e(a3, av + 32);
    if (n > 3) phx_r2e(a4, av + 48);
    if (n > 4) phx_r2e(a5, av + 64);
    u8 rv[16];
    st32(rv + ZVX_TYPE_INFO, IZ_UNDEF);
    i64 lz = ld64(phT + PHT_phx_lz);
    st64(phT + PHT_phx_lz, 0);
    _call_user_function_impl(0, fz, rv, n, av, 0);
    st64(phT + PHT_phx_lz, lz);
    i64 k = 0;
    loop { if (k >= n) break; zval_ptr_dtor(av + k * 16); k = k + 1; }
    zval_ptr_dtor(fz);
    if (phx_zexc()) { zval_ptr_dtor(rv); phx_zcatch(); return php_znull(); }
    uptr r = phx_e2r(rv);
    zval_ptr_dtor(rv);
    return r;
}

i64 phx_pis(uptr o, uptr name) {
    uptr phT = ph_tcur; if (!phT) phT = ph_tslow();
    if (phx_offthread(phT)) return 0;
    uptr ce = ld64(ld64(o + PHX_POBJ) + ZOX_CE);
    uptr cz = phx_zstr(php_clskey(name));
    uptr want = zend_lookup_class_ex(cz, 0, FETCH_NO_AUTOLOAD);
    st32(cz, ld32(cz) - 1);
    if (!ld32(cz)) phx_ef(cz);
    if (!want) return 0;
    if (want == ce) return 1;
    return instanceof_function_slow(ce, want) & 255;
}

// get_module: the table, and the engine's globals
void phx_eng_init() {
    phx_eg = php_dlsym("executor_globals");
    st64(phx_engt, &phx_pcname);
    st64(phx_engt + 8, &phx_pget);
    st64(phx_engt + 16, &phx_pset);
    st64(phx_engt + 24, &phx_pcall);
    st64(phx_engt + 32, &phx_pis);
    st64(phx_engt + 40, &phx_pnew);
    st64(phx_engt + 48, &phx_vcall);
    ph_eng = phx_engt;
}

// ---- a signature beyond the scalars ------------------------------------------
// What src/ext.mc emits for a parameter or a return that is not a declared
// int, float, string or bool: the argument checked against what was DECLARED
// (types.mc's BK_* kind, the class name, null allowed), then converted
// (§ engine values), with php's own messages.
#define MAYBE_ARRAY         128
#define MAYBE_OBJECT        256
#define MAYBE_CALLABLE      4096
#define MAYBE_ANY           1022
#define ZTX_VARIADIC        134217728   // _ZEND_IS_VARIADIC_BIT
#define ZTX_LITERAL_NAME    8388608     // _ZEND_TYPE_LITERAL_NAME_BIT: ptr is a C string

extern i64 zend_is_callable_ex(uptr callable, uptr obj, i64 flags, uptr name, uptr fcc, uptr err);

// "f() expects exactly/at least/at most N argument(s), M given"
i64 phx_arity2(uptr ex, i64 mn, i64 mx, uptr fname) {
    i64 got = phx_nargs(ex);
    if (got >= mn && (mx < 0 || got <= mx)) return 1;
    uptr w = "exactly ";
    i64 want = mn;
    if (mx < 0 || mn != mx) {
        if (got < mn) w = "at least ";
        if (got >= mn) { w = "at most "; want = mx; }
    }
    uptr s = php_str_new(fname, php_cstrlen(fname));
    s = php_str_concat(s, php_str_new("() expects ", 11));
    s = php_str_concat(s, php_str_new(w, php_cstrlen(w)));
    s = php_str_concat(s, php_itos(want));
    if (want == 1) s = php_str_concat(s, php_str_new(" argument, ", 11));
    if (want != 1) s = php_str_concat(s, php_str_new(" arguments, ", 12));
    s = php_str_concat(s, php_itos(got));
    s = php_str_concat(s, php_str_new(" given", 6));
    zend_argument_count_error(s + ZSX_VAL);
    return 0;
}

// the declared type's name in a TypeError, `?` in front when null is allowed
uptr phx_bname(i64 dpt, i64 bk, uptr bname, i64 nul) {
    uptr n = "mixed";
    if (dpt == 0) n = "int";
    if (dpt == 1) n = "float";
    if (dpt == 2) n = "string";
    if (dpt == 3) n = "bool";
    if (dpt == 8) n = "array";
    if (bk == 1) n = "callable";
    if (bk == 2) n = "object";
    if (bk == 3) n = bname;
    if (!nul) return n;
    uptr s = php_str_concat(php_str_new("?", 1), php_str_new(n, php_cstrlen(n)));
    return s + ZSX_VAL;
}

// Argument k against its declaration; 0 after php's TypeError. Not passed is
// fine: the arity was checked and a default fills it.
i64 phx_chk2(uptr ex, i64 k, i64 dpt, i64 bk, uptr bname, i64 nul, uptr fname, uptr pname) {
    if (k >= phx_nargs(ex)) return 1;
    uptr z = phx_argz(ex, k);
    i64 t = phx_type(z);
    if (t == IZ_REFERENCE) { z = ld64(z) + ZRX_VAL; t = phx_type(z); }
    if (t == IZ_NULL && nul) return 1;
    i64 ok = 1;
    if (dpt >= 0 && dpt <= 3) {
        ok = 0;
        if (dpt == 0 && t == IZ_LONG) ok = 1;
        if (dpt == 1 && (t == IZ_DOUBLE || t == IZ_LONG)) ok = 1;
        if (dpt == 2 && t == IZ_STRING) ok = 1;
        if (dpt == 3 && (t == IZ_TRUE || t == IZ_FALSE)) ok = 1;
    }
    if (dpt == 8 && t != IZ_ARRAY) ok = 0;
    if (bk == 2 && t != IZ_OBJECT) ok = 0;
    if (bk == 3) {
        ok = 0;
        if (t == IZ_OBJECT) {
            uptr ce = ld64(ld64(z) + ZOX_CE);
            uptr cz = phx_zstr(php_str_new(bname, php_cstrlen(bname)));
            uptr want = zend_lookup_class_ex(cz, 0, FETCH_NO_AUTOLOAD);
            st32(cz, ld32(cz) - 1);
            if (!ld32(cz)) phx_ef(cz);
            if (want && (want == ce || (instanceof_function_slow(ce, want) & 255))) ok = 1;
        }
    }
    if (bk == 1) {
        u8 err[8];
        st64(err, 0);
        if (zend_is_callable_ex(z, 0, 0, 0, 0, err) & 255) return 1;
        uptr s = php_str_new(fname, php_cstrlen(fname));
        s = php_str_concat(s, php_str_new("(): Argument #", 14));
        s = php_str_concat(s, php_itos(k + 1));
        s = php_str_concat(s, php_str_new(" ($", 3));
        s = php_str_concat(s, php_str_new(pname, php_cstrlen(pname)));
        s = php_str_concat(s, php_str_new(") must be a valid callback", 26));
        if (ld64(err)) {
            s = php_str_concat(s, php_str_new(", ", 2));
            s = php_str_concat(s, php_str_new(ld64(err), php_cstrlen(ld64(err))));
            phx_ef(ld64(err));
        }
        zend_type_error(s + ZSX_VAL);
        return 0;
    }
    if (ok) return 1;
    phx_bad_type(fname, k, pname, phx_bname(dpt, bk, bname, nul), z);
    return 0;
}

// every argument from k on, against the variadic parameter's declaration
i64 phx_chk_rest(uptr ex, i64 k, i64 dpt, i64 bk, uptr bname, i64 nul, uptr fname, uptr pname) {
    i64 n = phx_nargs(ex);
    loop {
        if (k >= n) break;
        if (!phx_chk2(ex, k, dpt, bk, bname, nul, fname, "")) return 0;
        k = k + 1;
    }
    return 1;
}

// argument k as a runtime zval, 0 when it was not passed
uptr phx_zarg(uptr ex, i64 k) {
    if (k >= phx_nargs(ex)) return 0;
    return phx_e2r(phx_argz(ex, k));
}

uptr phx_aarg(uptr ex, i64 k) { return ld64(phx_zarg(ex, k)); }

// the arguments from k on, a runtime array: a variadic parameter
uptr phx_rest(uptr ex, i64 k) {
    uptr a = php_arr_new(8);
    i64 n = phx_nargs(ex);
    loop {
        if (k >= n) break;
        phx_e2r_into(phx_argz(ex, k), php_arr_nextslot(a));
        k = k + 1;
    }
    return a;
}

// the answer: return_value takes the references it needs
void phx_ret_zv(uptr rv, uptr z) { if (z) phx_r2e(z, rv); }
void phx_ret_arr(uptr rv, uptr a) {
    st64(rv, phx_r2e_arr(a));
    st32(rv + ZVX_TYPE_INFO, IZ_ARRAY_EX);
}

// A parameter's argument record for the declared type: a scalar's mask, an
// array's, a callable's, an object's, a class by name, null allowed; the
// variadic bit on the last. `nreq` in the function's entry is the count
// without a default.
i64 phx_mask2(i64 dpt, i64 bk, i64 nul) {
    i64 m = phx_mask(dpt);
    if (dpt == 8) m = MAYBE_ARRAY;
    if (bk == 1) m = MAYBE_CALLABLE;
    if (bk == 2) m = MAYBE_OBJECT;
    if (dpt < 0 || (dpt == 7 && bk == 0)) m = MAYBE_ANY;
    if (nul && m != MAYBE_ANY) m = m | MAYBE_NULL;
    return m;
}

void phx_arg2(uptr name, i64 dpt, i64 bk, uptr bname, i64 nul, i64 variadic) {
    phx_arg(name, 0);
    uptr a = phx_ai + (phx_nai - 1) * AIX_SIZE;
    i64 m = phx_mask2(dpt, bk, nul);
    if (bk == 3) {
        st64(a + AIX_TYPE_PTR, bname);
        m = ZTX_LITERAL_NAME;
        if (nul) m = m | MAYBE_NULL;
    }
    if (variadic) m = m | ZTX_VARIADIC;
    st32(a + AIX_TYPE_MASK, m);
}

// and the return's, written over what phx_fn put there
void phx_ret2(i64 dpt, i64 bk, uptr bname, i64 nul) {
    uptr e = phx_fe + (phx_nfn - 1) * FEX_SIZE;
    uptr a = ld64(e + FEX_ARG_INFO);
    i64 m = phx_mask2(dpt, bk, nul);
    if (bk == 3) {
        st64(a + AIX_TYPE_PTR, bname);
        m = ZTX_LITERAL_NAME;
        if (nul) m = m | MAYBE_NULL;
    }
    st32(a + AIX_TYPE_MASK, m);
}

// ---- published classes ---------------------------------------------------------
// A class the module publishes is the ENGINE's: registered at MINIT as an
// internal class of that name -- its declared properties with their defaults
// and visibility, its methods as internal methods whose handlers run the
// compiled bodies -- and every object of it, made by php or by the module, is
// a zend_object the module holds as a proxy (§ engine values). The runtime's
// own class stays: it carries the methods the handlers call and the defaults
// the declaration reads, and its CE_ENG is the engine's (flag 64).
#define CEX_SIZE            520
#define CEX_FLAGS           28      // u32 ce_flags
#define CEX_HANDLERS        360     // default_object_handlers
#define CEX_FUNCS           504     // info.internal.builtin_functions
#define EXX_THIS            32      // execute_data->This: the object
#define ACC_FINAL           32
#define ACC_EXPLICIT_ABSTRACT 64

extern uptr zend_register_internal_class_ex(uptr ce, uptr parent);
extern void zend_declare_property(uptr ce, uptr name, i64 len, uptr zv, i64 flags);
extern void object_init_ex(uptr zv, uptr ce);

// One zend_function_entry table per class, laid one after the other in one
// buffer, each ending in its zero row: phx_cls_begin opens one, phx_meth adds a
// row (its argument records in phx_ai, as a function's), phx_cls_end closes it
// and registers the class.
#define PHX_MAXCM 512
u8  phx_cfe[24624];                 // (PHX_MAXCM + 1) * FEX_SIZE
i64 phx_ncm;
i64 phx_cfirst;

void phx_cls_begin() { phx_cfirst = phx_ncm; }

void phx_meth(uptr name, uptr handler, i64 nreq, i64 vis) {
    if (phx_ncm >= PHX_MAXCM) php_die("mc-php: too many published methods\n", 35);
    if (phx_nai >= PHX_MAXAI) php_die("mc-php: too many argument records\n", 34);
    uptr e = phx_cfe + phx_ncm * FEX_SIZE;
    uptr a = phx_ai + phx_nai * AIX_SIZE;
    st64(e + FEX_FNAME, name);
    st64(e + FEX_HANDLER, handler);
    st64(e + FEX_ARG_INFO, a);
    st32(e + FEX_NUM_ARGS, 0);
    i64 fl = 1;                     // ZEND_ACC_PUBLIC
    if (vis == 1) fl = 2;           // protected
    if (vis == 2) fl = 4;           // private
    st32(e + FEX_FLAGS, fl);
    st64(a + AIX_NAME, nreq);
    st64(a + AIX_TYPE_PTR, 0);
    st32(a + AIX_TYPE_MASK, 0);
    st64(a + AIX_DEFAULT_VALUE, 0);
    phx_nai = phx_nai + 1;
    phx_ncm = phx_ncm + 1;
}

// a method's parameter, untyped: the compiled body checks what it declared
void phx_marg(uptr name) {
    uptr e = phx_cfe + (phx_ncm - 1) * FEX_SIZE;
    uptr a = phx_ai + phx_nai * AIX_SIZE;
    st32(e + FEX_NUM_ARGS, ld32(e + FEX_NUM_ARGS) + 1);
    st64(a + AIX_NAME, name);
    st64(a + AIX_TYPE_PTR, 0);
    st32(a + AIX_TYPE_MASK, 0);
    st64(a + AIX_DEFAULT_VALUE, 0);
    phx_nai = phx_nai + 1;
}

// The class, registered: `flags` is the runtime's (1 abstract, 2 final).
void phx_cls_end(uptr rce, uptr name, i64 flags) {
    // the table's zero row
    uptr z = phx_cfe + phx_ncm * FEX_SIZE;
    i64 k = 0;
    loop { if (k >= FEX_SIZE) break; st64(z + k, 0); k = k + 8; }
    uptr tbl = phx_cfe + phx_cfirst * FEX_SIZE;
    if (phx_ncm == phx_cfirst) tbl = 0;
    phx_ncm = phx_ncm + 1;
    uptr t = php_alloc(CEX_SIZE);
    k = 0;
    loop { if (k >= CEX_SIZE) break; st64(t + k, 0); k = k + 8; }
    // the name interned the engine's way (zend_string_init_interned is a
    // POINTER the engine sets), the standard handlers, the method table
    uptr sip = php_dlsym("zend_string_init_interned");
    st64(t + ZCX_NAME, callp(ld64(sip), name, php_cstrlen(name), 1));
    st64(t + CEX_HANDLERS, php_dlsym("std_object_handlers"));
    st64(t + CEX_FUNCS, tbl);
    uptr ece = zend_register_internal_class_ex(t, 0);
    if (flags & 2) st32(ece + CEX_FLAGS, ld32(ece + CEX_FLAGS) | ACC_FINAL);
    if (flags & 1) st32(ece + CEX_FLAGS, ld32(ece + CEX_FLAGS) | ACC_EXPLICIT_ABSTRACT);
    // the declared properties, in declaration order, with their visibility
    uptr p = ld64(rce + 40);
    i64 used = php_ht_used(p);
    i64 i = 0;
    loop {
        if (i >= used) break;
        uptr b = php_ht_bkt(p, i);
        i = i + 1;
        if (php_zv_type(b) == IZ_UNDEF) continue;
        uptr pn = ld64(b + 24);
        u8 ez[16];
        i64 t2 = php_zv_type(b);
        if (t2 == IZ_ARRAY || t2 == IZ_OBJECT)
            php_die("mc-php: a published class's array or object default is not implemented yet\n", 75);
        phx_r2e(b, ez);
        i64 vis = 0;
        uptr vb = php_ht_find(ld64(rce + 72), php_str_hash(pn), pn);
        if (vb) vis = ld64(vb) / 8;
        i64 fl = 1;
        if (vis == 1) fl = 2;
        if (vis == 2) fl = 4;
        zend_declare_property(ece, pn + ZSX_VAL, ld64(pn + ZSX_LEN), ez, fl);
    }
    st64(rce + CE_ENG, ece);
    php_ce_flag(rce, 64);
}

// `new C` of a published class, in the module: the engine's object, with
// the defaults its class declares; the constructor is php_ctor's call
uptr phx_pnew(uptr rce) {
    uptr phT = ph_tcur; if (!phT) phT = ph_tslow();
    if (phx_offthread(phT)) return php_znull();
    u8 z[16];
    object_init_ex(z, ld64(rce + CE_ENG));
    uptr o = phx_proxy(ld64(z));
    zval_ptr_dtor(z);
    phx_zafter();
    return o;
}

// A published method's handler: $this the engine's object as a proxy, the
// arguments as runtime zvals (0 for one not passed: the body raises php's
// own error or takes the default), the compiled body, the answer back.
void phx_mh(uptr ex, uptr rv, uptr fn, uptr mname) { uptr phT = ph_tcur; if (!phT) phT = ph_tslow();
    phx_enter();
    i64 n = phx_nargs(ex);
    if (n > 6) {
        phx_arity2(ex, 0, 6, mname);
        phx_leave();
        return;
    }
    u8 a[48];
    i64 k = 0;
    loop { if (k >= 6) break; st64(a + k * 8, 0); if (k < n) st64(a + k * 8, phx_e2r(phx_argz(ex, k))); k = k + 1; }
    uptr o = phx_proxy(ld64(ex + EXX_THIS));
    uptr r = callp(fn, o, ld64(a), ld64(a + 8), ld64(a + 16), ld64(a + 24), ld64(a + 32), ld64(a + 40));
    if (!((uptr) ld64(phT + PHT_ph_exc)) && r) phx_r2e(r, rv);
    phx_leave();
}

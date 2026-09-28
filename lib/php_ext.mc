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
// What it does NOT do, and why it is not an omission: it registers no class,
// no constant and no INI entry, and it declares no module globals. The scope
// of this back end is plain functions with declared scalar parameters and a
// declared scalar return (docs/plan.md D11); everything else is a NAMED
// refusal in src/ext.mc rather than a silent wrong answer.

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
uptr php_str_alloc(i64 n) {
    if (!ph_zalloc) return php_str_mk(n, 1);
    // a size that wrapped negative is a huge size_t to _emalloc, which php's
    // memory limit refuses by name
    uptr s = _emalloc(ZSX_HDR + n + 1, "mc-php", 0, 0, 0);
    ph_rc_built = ph_rc_built + 1;
    st64(s, 94489280513);                       // refcount 1 | GC_STRING (22) << 32
    st64(s + 8, 0);
    st64(s + ZSX_LEN, n);
    st8(s + ZSX_VAL + n, 0);
    i64 k = ph_pn;
    if (k < ph_pcap) { st64(ph_pool + (k << 3), s); ph_pn = k + 1; return s; }
    php_pool_push(s);
    return s;
}

// php's pefree for a string whose count reached zero
void php_str_free(uptr s) {
    if (ld32(s + 4) & ZSX_PERSIST) { free(s); return; }
    _efree(s, "mc-php", 0, 0, 0);
}

// The temporaries above mark m die (php_rt.mc § who owns a string): every
// return and every loop iteration of the compiled code comes here, so the
// free is in the loop itself. A pool entry is never 0 and never interned.
void php_rc_drain(i64 m) {
    i64 i = ph_pn;
    uptr p = ph_pool;
    loop {
        if (i <= m) break;
        i = i - 1;
        uptr s = ld64(p + (i << 3));
        i64 rc = ld32(s);
        if (rc > 1) { st32(s, rc - 1); continue; }
        if (ld32(s + 4) & ZSX_PERSIST) { free(s); continue; }
        _efree(s, "mc-php", 0, 0, 0);
    }
    if (ph_pn > m) ph_pn = m;
}
void phx_ef(uptr p) { _efree(p, "mc-php", 0, 0, 0); }
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
                i64 zts, i64 dbg, uptr minit, uptr mshutdown) {
    // Output goes through php's own output layer from here on: what the
    // module echoes passes every ob_start() level the script opened, as an
    // internal function's php_printf does (before a request is active, php
    // writes it straight through). Set here, before MINIT runs, and never on
    // the program road.
    //
    // Through a local function and not &php_output_write: mc materialises
    // the address of an extern with adrp/add, which Apple's ld refuses for a
    // symbol the bundle resolves at load time (docs/plan.md § 5).
    ph_osink = &phx_owrite;
    ph_obx = &phx_ob;
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
    s = php_str_concat(s, php_str_new(" ($", 3));
    s = php_str_concat(s, php_str_new(pname, php_cstrlen(pname)));
    s = php_str_concat(s, php_str_new(") must be of type ", 18));
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

uptr phx_cl;
i64  phx_cn;
i64  phx_cc;
i64  phx_keep;
i64  phx_depth;
uptr phx_home;                      // the request's reusable chunk
i64  phx_floor;                     // below it: what pinned calls kept
i64  phx_efloor;                    // the escaped strings pinned calls kept
i64  phx_dirty;                     // a call of this request pinned
i64  phx_mark;                      // the arena's top when MINIT ended
uptr phx_snap;                      // and a copy of the arena below it

void phx_grow() {
    i64 nc = phx_cc * 2 + 256;
    uptr nl = phx_em(nc * 8);
    i64 i = 0;
    loop { if (i >= phx_cn) break; st64(nl + i * 8, ld64(phx_cl + i * 8)); i = i + 1; }
    if (phx_cl) phx_ef(phx_cl);
    phx_cl = nl;
    phx_cc = nc;
}

void phx_track(uptr p) {
    if (phx_cn == phx_cc) phx_grow();
    st64(phx_cl + phx_cn * 8, p);
    phx_cn = phx_cn + 1;
}

// the slow path: a block too big for a chunk gets its own, and a full chunk
// gets a successor
uptr phx_zalloc(i64 n) {
    // a size that wrapped negative (PHP_INT_MAX bytes and a header) is a
    // huge one: Zend's allocator refuses it with php's own memory fatal
    if (n > PH_ZBIG || n < 0) {
        uptr b = phx_em(n);
        phx_track(b);
        return b;
    }
    uptr c = phx_em(PHX_CK);
    phx_track(c);
    ph_zcur = c;
    ph_zlim = PHX_CK;
    ph_zpos = n;
    return c;
}

// a block this call made: taken OUT of the list
i64 phx_take(uptr p) {
    i64 i = phx_cn;
    loop {
        if (i <= phx_keep) break;
        i = i - 1;
        if (ld64(phx_cl + i * 8) == p) { st64(phx_cl + i * 8, 0); return 1; }
    }
    return 0;
}

// free every block of the list from `from` up
void phx_free_from(i64 from) {
    i64 i = from;
    loop {
        if (i >= phx_cn) break;
        uptr b = ld64(phx_cl + i * 8);
        if (b) phx_ef(b);
        i = i + 1;
    }
    phx_cn = from;
}

// the escaped strings from `from` up lose the reference the chunk held
void phx_esc_from(i64 from) {
    i64 i = ph_en;
    loop {
        if (i <= from) break;
        i = i - 1;
        php_str_release(ld64(ph_esc + i * 8));
    }
    if (ph_en > from) ph_en = from;
}

// the arena and its copy are 8-aligned, and the copy has 8 bytes to spare
void phx_copy(uptr d, uptr s, i64 n) {
    i64 i = 0;
    loop { if (i >= n) break; st64(d + i, ld64(s + i)); i = i + 8; }
}

// MINIT ends here: what it built is module state, and a copy of it is what
// every request that changed it is put back to
void phx_snapshot() {
    phx_mark = ph_top;
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
void phx_stat_line() {
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
    st64(w, phx_put_n(b, ld64(w), ph_rc_inplace));
    phx_put_s(b, w, ", copied ");
    st64(w, phx_put_n(b, ld64(w), ph_rc_copied));
    phx_put_s(b, w, ", strings built ");
    st64(w, phx_put_n(b, ld64(w), ph_rc_built));
    phx_put_s(b, w, "\n");
    write(2, b, ld64(w));
}

// RSHUTDOWN: the request's state goes back to what MINIT left, and what the
// request's pinned calls kept is freed -- Zend would free it anyway at the
// end of the request; freeing it here keeps a debug php's leak report quiet.
// the request a call through php's function table cached its function in,
// and the engine exception one of them holds (both below)
i64 phx_gen;
void phx_zexc_drop();
u8   phx_zexcz[16];                 // the engine exception a call took off it
uptr phx_zmirror;                   // and the runtime object that stands for it

i64 phx_rshutdown(i64 mtype, i64 mnum) {
    php_flush();
    php_request_reset();
    // a userland function a call site cached is gone with the request
    phx_gen = phx_gen + 1;
    phx_zexc_drop();
    if (phx_dirty) {
        phx_copy(ph_heap, phx_snap, phx_mark);
        phx_dirty = 0;
    }
    phx_stat_line();
    ph_rc_inplace = 0;
    ph_rc_copied = 0;
    ph_rc_built = 0;
    // the kept strings go while their holders are still readable, then the
    // blocks that held them
    phx_esc_from(0);
    phx_efloor = 0;
    if (ph_esc) phx_ef(ph_esc);
    ph_esc = 0;
    ph_ecap = 0;
    if (ph_pool) phx_ef(ph_pool);
    ph_pool = 0;
    ph_pcap = 0;
    ph_pn = 0;
    phx_free_from(0);
    if (phx_home) phx_ef(phx_home);
    phx_home = 0;
    phx_floor = 0;
    if (phx_cl) phx_ef(phx_cl);
    phx_cl = 0;
    phx_cc = 0;
    phx_keep = 0;
    return 0;
}

// ---- around every handler --------------------------------------------------
// The common call: the runtime is up, no call is open and the home chunk
// exists -- a handful of stores, written in place by src/opt.mc (the first
// call and a nested one take phx_enter_slow)
uptr phx_zalloc_fn;
void phx_enter_slow();
void phx_enter() {
    if (ph_boot_done && !phx_depth && phx_home) {
        ph_pin = 0;
        ph_zcur = phx_home;
        ph_zpos = phx_floor;
        ph_zlim = PHX_CK;
        phx_depth = 1;
        ph_zalloc = phx_zalloc_fn;
    } else phx_enter_slow();
}
void phx_enter_slow() {
    php_bootstrap();
    phx_zalloc_fn = &phx_zalloc;
    if (!phx_depth) {
        ph_pin = 0;
        if (!phx_home) phx_home = phx_em(PHX_CK);
        ph_zcur = phx_home;
        ph_zpos = phx_floor;
        ph_zlim = PHX_CK;
    }
    phx_depth = phx_depth + 1;
    ph_zalloc = &phx_zalloc;
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
void phx_throw() {
    if (!ph_exc) return;
    uptr o = ld64(ph_exc);
    // the engine's own, taken off it by phx_zcatch and not caught here (or
    // rethrown as it was): the engine's object goes back, trace and all
    if (phx_zmirror && o == phx_zmirror) {
        ph_exc = 0;
        uptr e = ld64(phx_zexcz);
        st64(phx_zexcz, 0);
        st64(phx_zexcz + 8, 0);
        phx_zmirror = 0;
        zend_throw_exception_internal(e);
        return;
    }
    uptr cn = php_obj_cname(o);
    uptr m = php_zv_str(php_exm_message(o));
    ph_exc = 0;
    // The CLASS, when the engine has one of that name -- every php built-in
    // does, so `throw new InvalidArgumentException(...)` crosses the boundary
    // as itself. A class this program DECLARED is the engine's only if the
    // program also registered it, which this back end does not do yet: the
    // fallback is a plain Exception whose message names the class, and it is
    // written down rather than silent (docs/php-extension.md § What differs).
    // the name is ours only for the lookup: released the way the engine
    // releases a string, in case an autoloader kept a reference
    uptr cz = phx_zstr(cn);
    uptr ce = zend_lookup_class(cz);
    st32(cz, ld32(cz) - 1);
    if (!ld32(cz)) phx_ef(cz);
    uptr s = m;
    if (!ce) {
        s = cn;
        if (php_strlen(m)) {
            s = php_str_concat(s, php_str_new(": ", 2));
            s = php_str_concat(s, m);
        }
    }
    zend_throw_exception(ce, s + ZSX_VAL, 0);
}

// The common return: nothing echoed, nothing thrown, the outermost call, nothing
// pinned and nothing kept past the floors -- the call's strings go and the
// allocator is put back. Written in place by src/opt.mc; the rest is
// phx_leave_slow, which is the whole story.
void phx_leave_slow();
void phx_leave() {
    if (!ph_outn && !ph_exc && phx_depth == 1 && !ph_nob && !ph_pin && ph_en == phx_efloor && phx_cn == phx_keep) {
        phx_depth = 0;
        php_rc_drain(0);
        ph_zalloc = 0;
        ph_zcur = 0;
        ph_zlim = 0;
    } else phx_leave_slow();
}
void phx_leave_slow() {
    php_flush();
    phx_throw();
    // MINIT's own end: not a call
    if (!phx_depth) { if (!phx_mark) phx_snapshot(); return; }
    phx_depth = phx_depth - 1;
    if (phx_depth) return;
    // the call's temporaries die: whatever it answered, return_value has its
    // own reference by now (phx_ret_str)
    php_rc_drain(0);
    uptr cur = ph_zcur;
    i64 pos = ph_zpos;
    ph_zalloc = 0;
    ph_zcur = 0;
    ph_zlim = 0;
    // an output buffer the call left open is made of the call's blocks
    if (ph_nob) ph_pin = 1;
    if (ph_pin) {
        // what the call used is kept, and the strings its blocks hold with it;
        // the chunk it ended in is where the next call goes on bumping, so a
        // pinned call costs its own bytes and not a chunk
        if (cur != phx_home) {
            phx_take(cur);
            phx_track(phx_home);
            phx_home = cur;
        }
        phx_floor = pos;
        phx_keep = phx_cn;
        phx_efloor = ph_en;
        phx_dirty = 1;
        return;
    }
    // the strings the call's zvals, keys and rows held are released while
    // those blocks are still there, then the blocks go
    phx_esc_from(phx_efloor);
    phx_free_from(phx_keep);
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
// ponytail: one slot, released by the next one or at RSHUTDOWN -- not when
// the module's catch is done with it, which would put a test on every
// handler's return. A second one taken while an outer mirror is still
// pending crosses as the runtime exception it was converted to (its class
// and message, not its trace), and an exception class with a destructor
// sees it run late.

void phx_zexc_drop() {
    if (phx_type(phx_zexcz) == IZ_OBJECT) zval_ptr_dtor(phx_zexcz);
    st64(phx_zexcz, 0);
    st64(phx_zexcz + 8, 0);
    phx_zmirror = 0;
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

void phx_zcatch() {
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
    st64(phx_zexcz, e);
    st32(phx_zexcz + 8, IZ_OBJECT_EX);
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
    uptr pr = php_obj_props(ld64(ph_exc));
    u8 r2[16];
    uptr cz = phx_zprop(e, "code", r2);
    if (phx_type(cz) == IZ_LONG) php_zv_cp(php_arr_sslot(pr, php_str_new("code", 4)), php_zlong(ld64(cz)));
    php_zv_cp(php_arr_sslot(pr, php_str_new("file", 4)), php_zstr(phx_zpstr(e, "file")));
    u8 r3[16];
    uptr lz = phx_zprop(e, "line", r3);
    if (phx_type(lz) == IZ_LONG) php_zv_cp(php_arr_sslot(pr, php_str_new("line", 4)), php_zlong(ld64(lz)));
    phx_zmirror = ld64(ph_exc);
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
    m = php_str_concat(m, php_str_new("(): only null, bool, int, float and string cross php's function table", 69));
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
i64 phx_zin(uptr d, i64 v, i64 t) {
    if (t == IZ_LONG) { st64(d, v); st32(d + ZVX_TYPE_INFO, t); return 1; }
    if (!t) {
        t = ld8(v + 8);
        if (t == IZ_UNDEF) t = IZ_NULL;
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
i64 phx_lz;
void phx_enter_lz() { if (phx_lz) return; phx_enter(); phx_lz = 1; }
void phx_leave_lz() { phx_lz = 0; phx_leave(); }

// A call site's words, emitted beside it by the compiler: what it found and
// the request it found it in, then what only a slow road reads -- the name as
// the source spells it, the function the call is in (a TypeError names it)
// and the packed word below.
#define PHF_FN      0
#define PHF_GEN     8
#define PHF_NAME    16
#define PHF_IN      24
#define PHF_NT      32

// The function a call site names, found and cached: 0 when php has none, and
// then php's own Error is pending in the runtime.
uptr phx_flook(uptr c, i64 lazy) {
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
    st64(c + PHF_GEN, phx_gen);
    return f;
}

// The call itself: the site's packed word has the argument count in its low
// byte and each argument's kind in the next four (phx_zin). The answer is
// left in the engine zval r; 0 when an argument could not cross (and the
// runtime's Error is pending).
i64 phx_fcall_do(uptr f, uptr c, i64 v1, i64 v2, i64 v3, i64 v4, uptr r, i64 lazy) {
    u8 pz[64];
    i64 nt = ld64(c + PHF_NT);
    i64 n = nt & 255;
    i64 ok = 1;
    if (n > 0) ok = phx_zin(pz, v1, (nt >> 8) & 255);
    if (n > 1 && ok) ok = phx_zin(pz + 16, v2, (nt >> 16) & 255);
    if (n > 2 && ok) ok = phx_zin(pz + 32, v3, (nt >> 24) & 255);
    if (n > 3 && ok) ok = phx_zin(pz + 48, v4, (nt >> 32) & 255);
    if (!ok) {
        if (lazy) phx_enter_lz();
        phx_nocross("array, object or resource passed to ", ld64(c + PHF_NAME));
        return 0;
    }
    st32(r + ZVX_TYPE_INFO, IZ_UNDEF);
    // what the module echoed so far goes out BEFORE the callee's own output
    if (ph_outn) php_flush();
    i64 lz = phx_lz;
    phx_lz = 0;
    zend_call_known_function(f, 0, 0, r, n, pz, 0);
    phx_lz = lz;
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
        if (t > IZ_STRING) {
            zval_ptr_dtor(rz);
            return phx_nocross("array, object or resource returned by ", name);
        }
        st64(z, ld64(in));
        st64(z + ZVX_TYPE_INFO, t);
        if (t == IZ_STRING && !(ld32(ld64(in) + 4) & ZSX_INTERNED)) st32(ld64(in), ld32(ld64(in)) + 1);
        zval_ptr_dtor(rz);
        if (t != IZ_STRING) return z;
    }
    if (t != IZ_STRING) {
        zval_ptr_dtor(r);
        return phx_nocross("array, object or resource returned by ", name);
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
uptr phx_fcall(uptr c, i64 nt, i64 v1, i64 v2, i64 v3, i64 v4) {
    uptr f = ld64(c + PHF_FN);
    if (!f || ld64(c + PHF_GEN) != phx_gen) f = phx_flook(c, 0);
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
i64 phx_fl_slow(uptr r, uptr c, i64 lazy) {
    if (lazy) phx_enter_lz();
    uptr z = phx_fres(r, php_alloc(ZVX_SIZE), ld64(c + PHF_NAME));
    if (ph_exc) return 0;
    uptr fn = ld64(c + PHF_IN);
    z = php_param_coerce(z, PC_INT, php_str_new("", 0), php_str_new(fn, php_cstrlen(fn)), 0, php_str_new("", 0));
    if (ph_exc) return 0;
    return php_zv_long(z);
}

i64 phx_fcall_l(uptr c, i64 nt, i64 v1, i64 v2, i64 v3, i64 v4, i64 lazy) {
    uptr f = ld64(c + PHF_FN);
    if (!f || ld64(c + PHF_GEN) != phx_gen) f = phx_flook(c, lazy);
    if (!f) return 0;
    u8 r[16];
    if (!phx_fcall_do(f, c, v1, v2, v3, v4, r, lazy)) return 0;
    if (ld8(r + ZVX_TYPE_INFO) == IZ_LONG) return ld64(r);
    return phx_fl_slow(r, c, lazy);
}

// and its common case, two ints, written in place: one call, as the twin's
i64 phx_fcall_l2(uptr c, i64 v1, i64 v2, i64 lazy) {
    uptr f = ld64(c + PHF_FN);
    if (!f || ld64(c + PHF_GEN) != phx_gen) return phx_fcall_l(c, 0, v1, v2, 0, 0, lazy);
    u8 pz[48];                                  // the two arguments, then the answer
    st64(pz, v1);
    st32(pz + ZVX_TYPE_INFO, IZ_LONG);
    st64(pz + 16, v2);
    st32(pz + 16 + ZVX_TYPE_INFO, IZ_LONG);
    st32(pz + 32 + ZVX_TYPE_INFO, IZ_UNDEF);
    if (ph_outn) php_flush();
    i64 lz = phx_lz;
    if (lz) phx_lz = 0;
    zend_call_known_function(f, 0, 0, pz + 32, 2, pz, 0);
    if (lz) phx_lz = lz;
    if (ld8(pz + 32 + ZVX_TYPE_INFO) == IZ_LONG) return ld64(pz + 32);
    return phx_fl_slow(pz + 32, c, lazy);
}

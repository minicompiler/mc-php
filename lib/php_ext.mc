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
extern uptr _emalloc(i64 n);
extern uptr _ecalloc(i64 nmemb, i64 size);
extern void _efree(uptr p);
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
i64  phx_take(uptr p);
i64  phx_isbor(uptr p);
i64  phx_rshutdown(i64 mtype, i64 mnum);

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
        php_output_get_length(z);
        return php_zlong(ld64(z));
    }
    // a copy of the buffer (IS_STRING, refcount 1): ours, then released
    php_output_get_contents(z);
    uptr zs = ld64(z);
    uptr r = php_str_new(zs + ZSX_VAL, ld64(zs + ZSX_LEN));
    if (!(ld32(zs + 4) & ZSX_INTERNED)) {
        st32(zs, ld32(zs) - 1);
        if (!ld32(zs)) _efree(zs);
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
// measured the layout, docs/php-abi.md records it), strings are immutable
// here, and the engine keeps the argument alive until the call returns. The
// runtime may write the hash into it -- the same DJBX33A, top bit set, that
// zend_string_hash_val stores, and never into an interned string, whose hash
// is already there. A call that PINS may have stored it somewhere that
// outlives the call, so phx_leave takes a reference on each one then.
u8  phx_bor[128];                   // the current call's borrowed strings
i64 phx_nbor;

uptr phx_s(uptr ex, i64 k) {
    uptr z = ld64(phx_argz(ex, k) + ZVX_VALUE);
    // at most 12: one per string parameter (mc's MAXPARAMS), read once by
    // the handler, and a handler is never re-entered -- a module's code cannot
    // call php code (examples/two-extensions pins that refusal). Loud, not
    // silent, if that ever stops being true.
    if (phx_nbor >= 16) php_die("mc-php: too many borrowed strings in one call\n", 46);
    st64(phx_bor + phx_nbor * 8, z);
    phx_nbor = phx_nbor + 1;
    return z;
}

// one more reference to an engine string (not to an interned one, which has
// no count)
void phx_addref(uptr z) {
    if (ld32(z + 4) & ZSX_INTERNED) return;
    st32(z, ld32(z) + 1);
}

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

// A zend_string the ENGINE owns: laid by hand over _emalloc, because
// zend_string_alloc is inline and unexported. refcount 1 and GC_STRING with
// no interned bit, so the engine's own release frees it.
uptr phx_zstr(uptr s) {
    i64 n = ld64(s + ZSX_LEN);
    uptr z = _emalloc(ZSX_HDR + n + 1);
    st32(z, 1);
    st32(z + 4, ZSX_GC_STRING);
    st64(z + 8, 0);
    st64(z + ZSX_LEN, n);
    i64 i = 0;
    loop {
        if (i >= n) break;
        st8(z + ZSX_VAL + i, ld8(s + ZSX_VAL + i));
        i = i + 1;
    }
    st8(z + ZSX_VAL + n, 0);
    return z;
}

// A string the call built in a block of its own -- anything over PH_ZBIG --
// is HANDED OVER, not copied: it is one Zend block already, laid as a
// zend_string with refcount 1 and GC_STRING, so it leaves the call's list and
// the engine owns it. A small one lives inside a chunk and is copied, which
// costs one allocation the size of the answer. So is a literal (module
// memory), and anything a PINNED call returns, which the state that pinned it
// may hold too. An argument handed straight back is the engine's own string
// and gains a reference.
void phx_ret_str(uptr rv, uptr s) {
    if (!ph_pin && phx_take(s)) {
        st64(rv + ZVX_VALUE, s);
        st32(rv + ZVX_TYPE_INFO, IZ_STRING_EX);
        return;
    }
    if (phx_isbor(s)) {
        phx_addref(s);
        st64(rv + ZVX_VALUE, s);
        if (ld32(s + 4) & ZSX_INTERNED) st32(rv + ZVX_TYPE_INFO, IZ_STRING);
        if (!(ld32(s + 4) & ZSX_INTERNED)) st32(rv + ZVX_TYPE_INFO, IZ_STRING_EX);
        return;
    }
    st64(rv + ZVX_VALUE, phx_zstr(s));
    st32(rv + ZVX_TYPE_INFO, IZ_STRING_EX);
}

// ---- the call's memory -----------------------------------------------------
// Inside a call the runtime bumps through a Zend chunk (php_rt.mc's php_alloc
// seam); this file is the slow path and the bookkeeping. Every chunk comes
// from Zend's allocator, zeroed as the arena it replaces was. The request has
// one HOME chunk the calls reuse: when a call returns, the part of it the
// call used is zeroed again and every other block the call took -- a second
// chunk, a block too big for one -- is freed. A PINNED call's part stays:
// the next call starts above it (phx_floor). So a call's memory is released
// when it returns, and a million calls in one request use the same 32 KiB.
// The list is [phx_keep, phx_cn) for the call and [0, phx_keep) for what the
// request's PINNED calls kept; RSHUTDOWN frees all of it.
#define PHX_CK   32768

uptr phx_cl;
i64  phx_cn;
i64  phx_cc;
i64  phx_keep;
i64  phx_depth;
uptr phx_home;                      // the request's reusable chunk
i64  phx_floor;                     // below it: what pinned calls kept
i64  phx_hused;                     // what the call used of it, once it moved on
i64  phx_dirty;                     // a call of this request pinned
i64  phx_mark;                      // the arena's top when MINIT ended
uptr phx_snap;                      // and a copy of the arena below it

void phx_grow() {
    i64 nc = phx_cc * 2 + 256;
    uptr nl = _ecalloc(nc, 8);
    i64 i = 0;
    loop { if (i >= phx_cn) break; st64(nl + i * 8, ld64(phx_cl + i * 8)); i = i + 1; }
    if (phx_cl) _efree(phx_cl);
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
    if (n > PH_ZBIG) {
        uptr b = _ecalloc(n, 1);
        phx_track(b);
        return b;
    }
    if (ph_zcur == phx_home) phx_hused = ph_zpos;
    uptr c = _ecalloc(PHX_CK, 1);
    phx_track(c);
    ph_zcur = c;
    ph_zlim = PHX_CK;
    ph_zpos = n;
    return c;
}

// Zero n bytes of a chunk: 64 at a time while a whole 64 fits, then 8, then
// bytes. `p` is where the call started (a pinned call's end, not 64-aligned),
// so no store may pass p + n (found by the review of #19). Written out rather
// than a call to memset, which is not in every host's import list here.
void phx_zero(uptr p, i64 n) {
    uptr e = p + n;
    loop {
        if (p + 64 > e) break;
        st64(p, 0); st64(p + 8, 0); st64(p + 16, 0); st64(p + 24, 0);
        st64(p + 32, 0); st64(p + 40, 0); st64(p + 48, 0); st64(p + 56, 0);
        p = p + 64;
    }
    loop { if (p + 8 > e) break; st64(p, 0); p = p + 8; }
    loop { if (p >= e) break; st8(p, 0); p = p + 1; }
}

// a block this call made: taken OUT of the list (the engine owns it now)
i64 phx_take(uptr p) {
    i64 i = phx_cn;
    loop {
        if (i <= phx_keep) break;
        i = i - 1;
        if (ld64(phx_cl + i * 8) == p) { st64(phx_cl + i * 8, 0); return 1; }
    }
    return 0;
}

i64 phx_isbor(uptr p) {
    i64 i = 0;
    loop { if (i >= phx_nbor) break; if (ld64(phx_bor + i * 8) == p) return 1; i = i + 1; }
    return 0;
}

// free every block of the list from `from` up
void phx_free_from(i64 from) {
    i64 i = from;
    loop {
        if (i >= phx_cn) break;
        uptr b = ld64(phx_cl + i * 8);
        if (b) _efree(b);
        i = i + 1;
    }
    phx_cn = from;
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

// RSHUTDOWN: the request's state goes back to what MINIT left, and what the
// request's pinned calls kept is freed -- Zend would free it anyway at the
// end of the request; freeing it here keeps a debug php's leak report quiet.
i64 phx_rshutdown(i64 mtype, i64 mnum) {
    php_flush();
    php_request_reset();
    if (phx_dirty) {
        phx_copy(ph_heap, phx_snap, phx_mark);
        phx_dirty = 0;
    }
    phx_free_from(0);
    if (phx_home) _efree(phx_home);
    phx_home = 0;
    phx_floor = 0;
    if (phx_cl) _efree(phx_cl);
    phx_cl = 0;
    phx_cc = 0;
    phx_keep = 0;
    return 0;
}

// ---- around every handler --------------------------------------------------
void phx_enter() {
    php_bootstrap();
    if (!phx_depth) {
        ph_pin = 0;
        phx_nbor = 0;
        if (!phx_home) phx_home = _ecalloc(PHX_CK, 1);
        ph_zcur = phx_home;
        ph_zpos = phx_floor;
        ph_zlim = PHX_CK;
        phx_hused = 0 - 1;
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
    if (!ld32(cz)) _efree(cz);
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

void phx_leave() {
    php_flush();
    phx_throw();
    // MINIT's own end: not a call
    if (!phx_depth) { if (!phx_mark) phx_snapshot(); return; }
    phx_depth = phx_depth - 1;
    if (phx_depth) return;
    i64 used = phx_hused;
    if (ph_zcur == phx_home) used = ph_zpos;
    uptr cur = ph_zcur;
    i64 pos = ph_zpos;
    ph_zalloc = 0;
    ph_zcur = 0;
    ph_zlim = 0;
    // an output buffer the call left open is made of the call's blocks
    if (ph_nob) ph_pin = 1;
    if (ph_pin) {
        i64 i = 0;
        loop { if (i >= phx_nbor) break; phx_addref(ld64(phx_bor + i * 8)); i = i + 1; }
        // what the call used is kept; the chunk it ended in is where the
        // next call goes on bumping, so a pinned call costs its own bytes
        // and not a chunk
        if (cur != phx_home) {
            phx_take(cur);
            phx_track(phx_home);
            phx_home = cur;
        }
        phx_floor = pos;
        phx_keep = phx_cn;
        phx_dirty = 1;
        return;
    }
    // the home chunk is zeroed for the next call, as the arena was fresh
    phx_zero(phx_home + phx_floor, used - phx_floor);
    phx_free_from(phx_keep);
}

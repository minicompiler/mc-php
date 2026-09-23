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
extern void zend_type_error(uptr fmt);
extern void zend_argument_count_error(uptr fmt);
extern uptr zend_throw_exception(uptr ce, uptr msg, i64 code);
extern uptr zend_lookup_class(uptr name);

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

// A COPY into the arena, not the engine's own zend_string. The two records
// have the same shape (probes/t3 measured it), so reading php's directly
// would work -- and then the runtime would be holding a pointer the engine
// frees when the call returns. One memcpy per string argument is what that
// costs, and D7's arena is what it costs it to.
uptr phx_s(uptr ex, i64 k) {
    uptr z = ld64(phx_argz(ex, k) + ZVX_VALUE);
    return php_str_new(z + ZSX_VAL, ld64(z + ZSX_LEN));
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

void phx_ret_str(uptr rv, uptr s) {
    st64(rv + ZVX_VALUE, phx_zstr(s));
    st32(rv + ZVX_TYPE_INFO, IZ_STRING_EX);
}

// ---- around every handler --------------------------------------------------
void phx_enter() { php_bootstrap(); }

// The runtime buffers what a php function echoes and flushes it at the end of
// a PROGRAM (php_rt.mc's ph_out); an extension has no end of program, so the
// buffer is flushed at the end of every call.
//
// And a php-level `throw` inside the body leaves the runtime's own pending
// flag set (D7 has no VM and no setjmp: T6's mechanism is a flag). Left
// alone it would be a silently wrong answer -- the handler would return a
// value the program never produced -- so it becomes a Zend exception with
// the same message and class name in its text.
void phx_leave() {
    php_flush();
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
    uptr ce = zend_lookup_class(phx_zstr(cn));
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

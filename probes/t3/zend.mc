// T3 -- the minimal Zend runtime a real extension .so needs, written in mc.
//
// Every offset below is MEASURED, not assumed: probes/t3/layout.c prints them
// from the installed php headers with offsetof/sizeof, and run.sh diffs the two
// lists. The header line that defines each is named in the comment.

// --- zval: Zend/zend_types.h:355 struct _zval_struct -----------------------
#define ZVAL_SIZE       16
#define ZVAL_VALUE      0       // zend_value value
#define ZVAL_TYPE_INFO  8       // u1.type_info (u32): type | type_flags << 8
#define ZVAL_U2         12      // u2 (u32)

// Zend/zend_types.h:620..627
#define IS_UNDEF        0
#define IS_FALSE        2
#define IS_TRUE         3
#define IS_LONG         4
#define IS_STRING       6
// Zend/zend_types.h:825
#define IS_TYPE_REFCOUNTED 1

// --- zend_string: Zend/zend_types.h:393 struct _zend_string ----------------
#define ZSTR_SIZE           32  // sizeof(zend_string), val[1] included
#define ZSTR_GC_REFCOUNT    0   // gc.refcount (u32)
#define ZSTR_GC_TYPE_INFO   4   // gc.u.type_info (u32)
#define ZSTR_H              8   // h (u64), the hash -- 0 means "not computed"
#define ZSTR_LEN            16  // len (usize)
#define ZSTR_VAL            24  // val[], the bytes

// Zend/zend_types.h:817,849: GC_STRING = IS_STRING | GC_NOT_COLLECTABLE << 0,
// IS_STR_INTERNED = GC_IMMUTABLE = 1 << 6. An interned string is not
// refcounted, so the zval that points at it carries IS_STRING with no flags.
#define GC_STRING           22
#define IS_STR_INTERNED     64

// --- zend_execute_data: Zend/zend_compile.h:625 ----------------------------
#define EX_SIZE             80
#define EX_OPLINE           0
#define EX_CALL             8
#define EX_RETURN_VALUE     16
#define EX_FUNC             24
#define EX_THIS             32
#define EX_NUM_ARGS         44  // This.u2.num_args -- ZEND_CALL_NUM_ARGS, zend_compile.h:691
#define EX_PREV             48
#define EX_RUN_TIME_CACHE   64
// ZEND_CALL_FRAME_SLOT = (sizeof(ex) + sizeof(zval) - 1) / sizeof(zval) = 5,
// so ZEND_CALL_ARG(ex, n) is at ex + 80 + 16*(n-1). zend_compile.h:698,704,707
#define EX_ARG1             80

// --- zend_function_entry: Zend/zend_API.h:35 -------------------------------
#define FE_SIZE             48
#define FE_FNAME            0
#define FE_HANDLER          8
#define FE_ARG_INFO         16
#define FE_NUM_ARGS         24
#define FE_FLAGS            28

// --- zend_module_entry: Zend/zend_modules.h:71 -----------------------------
#define ME_SIZE             168
#define ME_NAME             32
#define ME_FUNCTIONS        40
#define ME_MODULE_STARTUP   48
#define ME_VERSION          88

// ---------------------------------------------------------------------------
// The memory this runtime hands out. A probe allocates a handful of strings and
// one call frame and never frees, so a bump pointer over one static array is
// the whole allocator. The real thing is ZendMM; that is not what T3 measures.
// ---------------------------------------------------------------------------
u8 zheap[65536];
i64 zheap_used;

uptr zalloc(i64 n) {
    i64 off = (zheap_used + 15) / 16 * 16;
    if (off + n > 65536) {
        puts("zalloc: out of memory\n");
        exit(9);
    }
    zheap_used = off + n;
    uptr p = zheap + off;
    i64 i = 0;
    loop {
        if (i == n) break;
        st8(p + i, 0);
        i = i + 1;
    }
    return p;
}

// --- zend_string ------------------------------------------------------------
// Built as INTERNED (refcount 1, GC_IMMUTABLE): nothing in the call path takes
// or drops a reference, so no refcounting has to exist for T3.
uptr zend_string_new(uptr bytes, i64 len) {
    uptr s = zalloc(ZSTR_SIZE + len + 1);
    st32(s + ZSTR_GC_REFCOUNT, 1);
    st32(s + ZSTR_GC_TYPE_INFO, GC_STRING + IS_STR_INTERNED);
    st64(s + ZSTR_H, 0);
    st64(s + ZSTR_LEN, len);
    i64 i = 0;
    loop {
        if (i == len) break;
        st8(s + ZSTR_VAL + i, ld8(bytes + i));
        i = i + 1;
    }
    st8(s + ZSTR_VAL + len, 0);
    return s;
}

// --- zval -------------------------------------------------------------------
void zval_undef(uptr z) {
    st64(z + ZVAL_VALUE, 0);
    st32(z + ZVAL_TYPE_INFO, IS_UNDEF);
    st32(z + ZVAL_U2, 0);
}

void zval_string(uptr z, uptr zstr) {
    st64(z + ZVAL_VALUE, zstr);
    st32(z + ZVAL_TYPE_INFO, IS_STRING);   // interned: no IS_TYPE_REFCOUNTED
    st32(z + ZVAL_U2, 0);
}

void zval_long(uptr z, i64 v) {
    st64(z + ZVAL_VALUE, v);
    st32(z + ZVAL_TYPE_INFO, IS_LONG);
    st32(z + ZVAL_U2, 0);
}

i64 zval_type(uptr z) {
    return ld32(z + ZVAL_TYPE_INFO) % 256;
}

// --- the call frame ---------------------------------------------------------
// ZEND_CALL_FRAME_SLOT zvals of header, then one zval per argument.
uptr zend_frame_new(i64 nargs, uptr return_value) {
    uptr ex = zalloc(EX_SIZE + ZVAL_SIZE * nargs);
    st64(ex + EX_RETURN_VALUE, return_value);
    st32(ex + EX_NUM_ARGS, nargs);
    return ex;
}

uptr zend_call_arg(uptr ex, i64 n) {
    return ex + EX_ARG1 + ZVAL_SIZE * (n - 1);
}

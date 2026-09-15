// T3 -- does a real php extension run on a zval built in mc?
//
// Loads php-src's own ctype.so, finds ctype_digit through its zend_module_entry,
// builds a zend_execute_data with one IS_STRING argument at the layout the
// headers define, and calls the extension's handler.
//
// The seven symbols ctype.so imports (T1) are all DEFINED here, because
// dlopen(RTLD_NOW) resolves every one of them or fails. Two are IMPLEMENTED
// because the IS_LONG path really reaches them; five are STUBS that print the
// symbol's name and abort, so a path this probe did not expect is visible
// rather than silent.

#include <sys>
#include <io>
#include "zend.mc"

extern uptr dlopen(uptr path, i64 mode);
extern uptr dlsym(uptr handle, uptr name);
extern uptr dlerror();

#define RTLD_NOW 2

void nl() { write(1, "\n", 1); }

void die(uptr msg) {
    puts(msg);
    nl();
    exit(1);
}

i64 str_eq(uptr a, uptr b) {
    i64 i = 0;
    loop {
        i64 ca = ld8(a + i);
        if (ca != ld8(b + i)) return 0;
        if (ca == 0) return 1;
        i = i + 1;
    }
}

// ---------------------------------------------------------------------------
// The host half of the Zend API, for ctype.so's seven imports.
// ---------------------------------------------------------------------------

// STUBS: never reached by this probe. Each names itself and stops, so an
// unexpected path is a diagnostic and not a wrong answer.
void unimplemented(uptr name) {
    puts("UNIMPLEMENTED zend symbol reached: ");
    puts(name);
    nl();
    exit(7);
}

void php_info_print_table_start()          { unimplemented("php_info_print_table_start"); }
void php_info_print_table_end()            { unimplemented("php_info_print_table_end"); }
void php_info_print_table_row()            { unimplemented("php_info_print_table_row"); }
void zend_wrong_parameter_error()          { unimplemented("zend_wrong_parameter_error"); }
void zend_wrong_parameters_count_error()   { unimplemented("zend_wrong_parameters_count_error"); }

// IMPLEMENTED: the IS_LONG path of ctype_impl calls both of these.
// Zend/zend_API.h: const char *zend_zval_type_name(const zval *arg)
uptr zend_zval_type_name(uptr z) {
    i64 t = zval_type(z);
    if (t == IS_UNDEF)  return "null";
    if (t == IS_FALSE)  return "bool";
    if (t == IS_TRUE)   return "bool";
    if (t == IS_LONG)   return "int";
    if (t == IS_STRING) return "string";
    return "mixed";
}

// main/php.h: void php_error_docref(const char *docref, int type, const char *format, ...)
// Three named arguments, then variadic. On Apple arm64 the variadic ones land
// on the stack, which mc reads as parameters 9..12 (T2). The one this call site
// passes is the %s of "Argument of type %s ...", i.e. a char*.
i64 docref_calls;

void php_error_docref(uptr docref, i64 type, uptr fmt,
                      i64 x4, i64 x5, i64 x6, i64 x7, i64 x8,
                      uptr v1) {
    docref_calls = docref_calls + 1;
    puts("    [php_error_docref type=");
    putnum(type);
    puts(" fmt=\"");
    puts(fmt);
    puts("\" arg1=\"");
    puts(v1);
    puts("\"]");
    nl();
}

// ---------------------------------------------------------------------------
// Finding the function in the module
// ---------------------------------------------------------------------------

uptr find_handler(uptr module, uptr want) {
    uptr fe = ld64(module + ME_FUNCTIONS);
    if (fe == 0) return 0;
    loop {
        uptr fname = ld64(fe + FE_FNAME);
        if (fname == 0) return 0;
        if (str_eq(fname, want) != 0) return ld64(fe + FE_HANDLER);
        fe = fe + FE_SIZE;
    }
}

// ---------------------------------------------------------------------------
// One call
// ---------------------------------------------------------------------------

// calls handler(execute_data, return_value) with the argument already built
i64 call1(uptr handler, uptr arg) {
    uptr rv = zalloc(ZVAL_SIZE);
    zval_undef(rv);
    uptr ex = zend_frame_new(1, rv);
    uptr a1 = zend_call_arg(ex, 1);
    st64(a1 + ZVAL_VALUE, ld64(arg + ZVAL_VALUE));
    st32(a1 + ZVAL_TYPE_INFO, ld32(arg + ZVAL_TYPE_INFO));
    st32(a1 + ZVAL_U2, ld32(arg + ZVAL_U2));
    callp(handler, ex, rv);
    return zval_type(rv);
}

void show(uptr label, i64 t, i64 want, uptr bad) {
    puts("  ctype_digit(");
    puts(label);
    puts(") -> ");
    if (t == IS_TRUE) puts("true");
    if (t == IS_FALSE) puts("false");
    if (t != IS_TRUE) { if (t != IS_FALSE) { puts("type "); putnum(t); } }
    if (t == want) {
        puts("  OK");
    } else {
        puts("  WRONG (want ");
        putnum(want);
        puts(")");
        st64(bad, ld64(bad) + 1);
    }
    nl();
}

uptr mkstr(uptr s) {
    uptr z = zalloc(ZVAL_SIZE);
    zval_string(z, zend_string_new(s, strlen(s)));
    return z;
}

uptr mklong(i64 v) {
    uptr z = zalloc(ZVAL_SIZE);
    zval_long(z, v);
    return z;
}

i64 main(i64 argc, uptr argv) {
    if (argc < 2) die("usage: host <ctype.so>");
    uptr path = ld64(argv + 8);

    uptr h = dlopen(path, RTLD_NOW);
    if (h == 0) {
        puts("dlopen failed: ");
        puts(dlerror());
        nl();
        return 1;
    }
    uptr gm = dlsym(h, "get_module");
    if (gm == 0) die("no get_module in the extension");

    uptr module = callp(gm);
    if (module == 0) die("get_module returned NULL");

    puts("module: ");
    puts(ld64(module + ME_NAME));
    puts(" ");
    puts(ld64(module + ME_VERSION));
    nl();

    uptr handler = find_handler(module, "ctype_digit");
    if (handler == 0) die("ctype_digit not found in the module's function table");
    puts("ctype_digit handler found\n");

    u8 badbuf[8];
    uptr bad = badbuf;
    st64(bad, 0);

    show("\"123\"", call1(handler, mkstr("123")), IS_TRUE,  bad);
    show("\"12a\"", call1(handler, mkstr("12a")), IS_FALSE, bad);
    show("\"\"",    call1(handler, mkstr("")),    IS_FALSE, bad);
    // the IS_LONG path: goes through ctype_fallback, which really calls
    // php_error_docref and zend_zval_type_name -- both implemented above.
    show("53",      call1(handler, mklong(53)),   IS_TRUE,  bad);   // '5'
    show("97",      call1(handler, mklong(97)),   IS_FALSE, bad);   // 'a'

    puts("php_error_docref calls: ");
    putnum(docref_calls);
    nl();

    if (ld64(bad) != 0) return 1;
    if (docref_calls != 2) { puts("expected 2 docref calls\n"); return 1; }
    puts("T3 OK\n");
    return 0;
}

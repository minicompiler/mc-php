/* abi.c -- the ORACLE for lib/php_ext.mc's layout.
 *
 * It prints every offset and constant the extension runtime names, read out
 * of the installed php headers with offsetof/sizeof. tests/ext.sh diffs this
 * against the `#define`s in lib/php_ext.mc and fails on any that disagree --
 * which is probes/t3's own gate, for the records t3 did not cover.
 *
 * The headers are the ORACLE and nothing else. The COMPILER never opens one:
 * that is the whole claim of this repository, and a gate that measures the
 * claim is not a dependency of it. Build it the way t3 builds layout.c:
 *
 *     clang -o abi abi.c $(php-config --includes)
 */
#include <stdio.h>
#include <stddef.h>
#include "php.h"
#include "zend_API.h"
#include "zend_modules.h"

#define P(n, v) printf("%-24s %ld\n", n, (long)(v))

int main(void) {
    /* zend_module_entry: Zend/zend_modules.h */
    P("MEX_SIZE",            sizeof(zend_module_entry));
    P("MEX_SIZE_FIELD",      offsetof(zend_module_entry, size));
    P("MEX_ZEND_API",        offsetof(zend_module_entry, zend_api));
    P("MEX_ZEND_DEBUG",      offsetof(zend_module_entry, zend_debug));
    P("MEX_ZTS",             offsetof(zend_module_entry, zts));
    P("MEX_INI_ENTRY",       offsetof(zend_module_entry, ini_entry));
    P("MEX_DEPS",            offsetof(zend_module_entry, deps));
    P("MEX_NAME",            offsetof(zend_module_entry, name));
    P("MEX_FUNCTIONS",       offsetof(zend_module_entry, functions));
    P("MEX_MODULE_STARTUP",  offsetof(zend_module_entry, module_startup_func));
    P("MEX_MODULE_SHUTDOWN", offsetof(zend_module_entry, module_shutdown_func));
    P("MEX_REQUEST_STARTUP", offsetof(zend_module_entry, request_startup_func));
    P("MEX_REQUEST_SHUTDOWN", offsetof(zend_module_entry, request_shutdown_func));
    P("MEX_VERSION",         offsetof(zend_module_entry, version));
    P("MEX_BUILD_ID",        offsetof(zend_module_entry, build_id));

    /* zend_function_entry: Zend/zend_API.h -- num_args and flags are TWO
       fields, and a table that wrote one 64-bit word over both would put an
       arity where a flag belongs. */
    P("FEX_SIZE",            sizeof(zend_function_entry));
    P("FEX_FNAME",           offsetof(zend_function_entry, fname));
    P("FEX_HANDLER",         offsetof(zend_function_entry, handler));
    P("FEX_ARG_INFO",        offsetof(zend_function_entry, arg_info));
    P("FEX_NUM_ARGS",        offsetof(zend_function_entry, num_args));
    P("FEX_FLAGS",           offsetof(zend_function_entry, flags));

    /* zend_internal_arg_info: type is a zend_type, whose type_mask is 8 bytes
       into it -- so the mask a parameter declares sits at 16. */
    P("AIX_SIZE",            sizeof(zend_internal_arg_info));
    P("AIX_NAME",            offsetof(zend_internal_arg_info, name));
    P("AIX_TYPE_PTR",        offsetof(zend_internal_arg_info, type));
    P("AIX_TYPE_MASK",       offsetof(zend_internal_arg_info, type)
                             + offsetof(zend_type, type_mask));
    P("AIX_DEFAULT_VALUE",   offsetof(zend_internal_arg_info, default_value));

    /* zval, zend_execute_data, zend_string */
    P("ZVX_SIZE",            sizeof(zval));
    P("ZVX_VALUE",           offsetof(zval, value));
    P("ZVX_TYPE_INFO",       offsetof(zval, u1));
    P("EXX_NUM_ARGS",        offsetof(zend_execute_data, This)
                             + offsetof(zval, u2));
    P("EXX_ARG1",            ZEND_CALL_FRAME_SLOT * sizeof(zval));
    P("ZSX_HDR",             offsetof(zend_string, val));
    P("ZSX_LEN",             offsetof(zend_string, len));
    P("ZSX_VAL",             offsetof(zend_string, val));
    P("ZSX_GC_STRING",       GC_STRING);
    P("ZSX_INTERNED",        IS_STR_INTERNED);
    P("ZSX_PERSIST",         IS_STR_PERSISTENT);

    /* the same string, as lib/php_rt.mc counts it (its § who owns a string):
       the runtime cannot include php_ext.mc, so it spells these itself and
       they are graded here too */
    P("ZS_HDR",              offsetof(zend_string, val));
    P("ZS_GC_STRING",        GC_STRING);
    P("ZS_INTERNED",         IS_STR_INTERNED);
    P("ZS_PERSIST",          IS_STR_PERSISTENT);
    P("ZS_MODULE",           GC_STRING | IS_STR_INTERNED);

    /* the type tags, and the two flags a zval's type_info carries */
    P("IZ_UNDEF",            IS_UNDEF);
    P("IZ_NULL",             IS_NULL);
    P("IZ_FALSE",            IS_FALSE);
    P("IZ_TRUE",             IS_TRUE);
    P("IZ_LONG",             IS_LONG);
    P("IZ_DOUBLE",           IS_DOUBLE);
    P("IZ_STRING",           IS_STRING);
    P("IZ_ARRAY",            IS_ARRAY);
    P("IZ_OBJECT",           IS_OBJECT);
    P("IZ_RESOURCE",         IS_RESOURCE);
    P("IZ_REFERENCE",        IS_REFERENCE);
    P("IZ_STRING_EX",        IS_STRING_EX);

    /* a type_mask */
    P("MAYBE_NULL",          MAY_BE_NULL);
    P("MAYBE_FALSE",         MAY_BE_FALSE);
    P("MAYBE_TRUE",          MAY_BE_TRUE);
    P("MAYBE_BOOL",          MAY_BE_BOOL);
    P("MAYBE_LONG",          MAY_BE_LONG);
    P("MAYBE_DOUBLE",        MAY_BE_DOUBLE);
    P("MAYBE_STRING",        MAY_BE_STRING);
    P("MAYBE_VOID",          MAY_BE_VOID);

    /* the class name a TypeError puts after "given" */
    P("ZOX_CE",              offsetof(zend_object, ce));
    P("ZCX_NAME",            offsetof(zend_class_entry, name));
    return 0;
}

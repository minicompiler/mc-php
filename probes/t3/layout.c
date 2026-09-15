/* T3 -- the layout oracle.
 *
 * Prints, from the installed php headers themselves, every offset and size the
 * mc side hardcodes. run.sh diffs this against the #defines in zend.mc, so a
 * layout fact in mc is measured against the header and never assumed.
 */
#include <stdio.h>
#include <stddef.h>
#include "php.h"
#include "zend_API.h"
#include "zend_modules.h"

#define P(name, v) printf("%-28s %d\n", name, (int)(v))

int main(void)
{
    P("ZVAL_SIZE",            sizeof(zval));
    P("ZVAL_VALUE",           offsetof(zval, value));
    P("ZVAL_TYPE_INFO",       offsetof(zval, u1.type_info));
    P("ZVAL_U2",              offsetof(zval, u2));

    P("IS_UNDEF",             IS_UNDEF);
    P("IS_FALSE",             IS_FALSE);
    P("IS_TRUE",              IS_TRUE);
    P("IS_LONG",              IS_LONG);
    P("IS_STRING",            IS_STRING);
    P("IS_TYPE_REFCOUNTED",   IS_TYPE_REFCOUNTED);
    P("GC_STRING",            GC_STRING);
    P("IS_STR_INTERNED",      IS_STR_INTERNED);

    P("ZSTR_SIZE",            sizeof(zend_string));
    P("ZSTR_GC_REFCOUNT",     offsetof(zend_string, gc.refcount));
    P("ZSTR_GC_TYPE_INFO",    offsetof(zend_string, gc.u.type_info));
    P("ZSTR_H",               offsetof(zend_string, h));
    P("ZSTR_LEN",             offsetof(zend_string, len));
    P("ZSTR_VAL",             offsetof(zend_string, val));

    P("EX_SIZE",              sizeof(zend_execute_data));
    P("EX_OPLINE",            offsetof(zend_execute_data, opline));
    P("EX_CALL",              offsetof(zend_execute_data, call));
    P("EX_RETURN_VALUE",      offsetof(zend_execute_data, return_value));
    P("EX_FUNC",              offsetof(zend_execute_data, func));
    P("EX_THIS",              offsetof(zend_execute_data, This));
    P("EX_NUM_ARGS",          offsetof(zend_execute_data, This.u2.num_args));
    P("EX_PREV",              offsetof(zend_execute_data, prev_execute_data));
    P("EX_RUN_TIME_CACHE",    offsetof(zend_execute_data, run_time_cache));
    P("ZEND_CALL_FRAME_SLOT", ZEND_CALL_FRAME_SLOT);
    /* where ZEND_CALL_ARG(ex, 1) lands, in bytes from ex */
    P("EX_ARG1",              ZEND_CALL_FRAME_SLOT * (int)sizeof(zval));

    P("FE_SIZE",              sizeof(zend_function_entry));
    P("FE_FNAME",             offsetof(zend_function_entry, fname));
    P("FE_HANDLER",           offsetof(zend_function_entry, handler));
    P("FE_ARG_INFO",          offsetof(zend_function_entry, arg_info));
    P("FE_NUM_ARGS",          offsetof(zend_function_entry, num_args));
    P("FE_FLAGS",             offsetof(zend_function_entry, flags));

    P("ME_SIZE",              sizeof(zend_module_entry));
    P("ME_NAME",              offsetof(zend_module_entry, name));
    P("ME_FUNCTIONS",         offsetof(zend_module_entry, functions));
    P("ME_MODULE_STARTUP",    offsetof(zend_module_entry, module_startup_func));
    P("ME_VERSION",           offsetof(zend_module_entry, version));
    return 0;
}

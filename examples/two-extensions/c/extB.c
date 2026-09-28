/* extB.c -- the C TWIN of extB.php: b_use calls a_add, which extension A
 * publishes, THROUGH PHP'S FUNCTION TABLE -- exactly what the compiled
 * extB.php does, and what a C author does when the function belongs to
 * another extension: two separately loaded modules share no C ABI (A's C
 * symbols are not exported on Linux or Windows, and nothing promises their
 * shape), so the name is looked up in EG(function_table) when the call runs
 * and the zend_function is cached for the rest of the request.
 *
 *     cc -O2 -bundle -undefined dynamic_lookup -o extB.so extB.c $(php-config --includes)   # macOS
 *     cc -O2 -shared -fPIC -o extB.so extB.c $(php-config --includes)                      # Linux
 */
#include "php.h"

static zend_function *a_add_fn;   /* found once per request; RSHUTDOWN forgets it */

ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(arginfo_b_use, 0, 2, IS_LONG, 0)
    ZEND_ARG_TYPE_INFO(0, a, IS_LONG, 0)
    ZEND_ARG_TYPE_INFO(0, b, IS_LONG, 0)
ZEND_END_ARG_INFO()

PHP_FUNCTION(b_use) {
    zend_long a, b;
    zval args[2], rv;
    ZEND_PARSE_PARAMETERS_START(2, 2)
        Z_PARAM_LONG(a)
        Z_PARAM_LONG(b)
    ZEND_PARSE_PARAMETERS_END();
    if (!a_add_fn) {
        a_add_fn = zend_hash_str_find_ptr(EG(function_table), "a_add", sizeof("a_add") - 1);
        if (!a_add_fn) {
            zend_throw_error(NULL, "Call to undefined function a_add()");
            RETURN_THROWS();
        }
    }
    ZVAL_LONG(&args[0], a);
    ZVAL_LONG(&args[1], b);
    zend_call_known_function(a_add_fn, NULL, NULL, &rv, 2, args, NULL);
    if (Z_ISUNDEF(rv)) RETURN_THROWS();
    /* extB.php's `: int` return: php checks it and throws its TypeError */
    if (Z_TYPE(rv) != IS_LONG) {
        zend_type_error("b_use(): Return value must be of type int, %s returned", zend_zval_value_name(&rv));
        zval_ptr_dtor(&rv);
        RETURN_THROWS();
    }
    RETURN_LONG(Z_LVAL(rv));
}

static PHP_RSHUTDOWN_FUNCTION(extB) {
    a_add_fn = NULL;
    return SUCCESS;
}

static const zend_function_entry extB_functions[] = {
    PHP_FE(b_use, arginfo_b_use)
    PHP_FE_END
};

zend_module_entry extB_module_entry = {
    STANDARD_MODULE_HEADER, "extB", extB_functions,
    NULL, NULL, NULL, PHP_RSHUTDOWN(extB), NULL, "0.1.0", STANDARD_MODULE_PROPERTIES
};

ZEND_GET_MODULE(extB)

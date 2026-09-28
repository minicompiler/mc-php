/* extA.c -- the C TWIN of extA.php: the same function written as an ordinary
 * C extension, the way php-src's own are. It is the third column of the
 * bench (bench.php) and is graded by the same check.php.
 *
 *     cc -O2 -bundle -undefined dynamic_lookup -o extA.so extA.c $(php-config --includes)   # macOS
 *     cc -O2 -shared -fPIC -o extA.so extA.c $(php-config --includes)                      # Linux
 */
#include "php.h"

ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(arginfo_a_add, 0, 2, IS_LONG, 0)
    ZEND_ARG_TYPE_INFO(0, a, IS_LONG, 0)
    ZEND_ARG_TYPE_INFO(0, b, IS_LONG, 0)
ZEND_END_ARG_INFO()

PHP_FUNCTION(a_add) {
    zend_long a, b;
    ZEND_PARSE_PARAMETERS_START(2, 2)
        Z_PARAM_LONG(a)
        Z_PARAM_LONG(b)
    ZEND_PARSE_PARAMETERS_END();
    /* extA.php's `$a + $b` overflows into a float in php; the check only
       passes it values that do not (check.php stays inside int) */
    RETURN_LONG(a + b);
}

static const zend_function_entry extA_functions[] = {
    PHP_FE(a_add, arginfo_a_add)
    PHP_FE_END
};

zend_module_entry extA_module_entry = {
    STANDARD_MODULE_HEADER, "extA", extA_functions,
    NULL, NULL, NULL, NULL, NULL, "0.1.0", STANDARD_MODULE_PROPERTIES
};

ZEND_GET_MODULE(extA)

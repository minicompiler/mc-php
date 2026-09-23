/* refx.c -- the REFERENCE extension: examples/hello's seven functions, built
 * the ordinary C way, so that examples/hello/errors.expect is a MEASUREMENT
 * and not a transcription.
 *
 * What it is for: an extension's function is an INTERNAL function, and php
 * does not report a wrong call to one the way it reports a wrong call to a
 * userland function -- no "called in FILE on line N" tail, and an extra
 * argument is an ArgumentCountError rather than being ignored. So
 * examples/hello/errors.php cannot be graded against the interpreted source;
 * it is graded against this, which is what php itself would say.
 *
 * It is a gate's oracle and never a dependency: the compiler does not need a
 * C toolchain, php-config or a php header, and tests/ext.sh skips this whole
 * step (and falls back to the committed expectation) where they are absent.
 *
 *     clang -bundle -undefined dynamic_lookup -o refx.so refx.c \
 *         $(php-config --includes)
 */
#include "php.h"
#include "zend_exceptions.h"

ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(ai_addone, 0, 1, IS_LONG, 0)
    ZEND_ARG_TYPE_INFO(0, n, IS_LONG, 0)
ZEND_END_ARG_INFO()
ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(ai_greet, 0, 1, IS_STRING, 0)
    ZEND_ARG_TYPE_INFO(0, who, IS_STRING, 0)
ZEND_END_ARG_INFO()
ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(ai_half, 0, 1, IS_DOUBLE, 0)
    ZEND_ARG_TYPE_INFO(0, x, IS_DOUBLE, 0)
ZEND_END_ARG_INFO()
ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(ai_not, 0, 1, _IS_BOOL, 0)
    ZEND_ARG_TYPE_INFO(0, b, _IS_BOOL, 0)
ZEND_END_ARG_INFO()
ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(ai_say, 0, 1, IS_VOID, 0)
    ZEND_ARG_TYPE_INFO(0, s, IS_STRING, 0)
ZEND_END_ARG_INFO()
ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(ai_sum, 0, 3, IS_LONG, 0)
    ZEND_ARG_TYPE_INFO(0, a, IS_LONG, 0)
    ZEND_ARG_TYPE_INFO(0, b, IS_LONG, 0)
    ZEND_ARG_TYPE_INFO(0, c, IS_LONG, 0)
ZEND_END_ARG_INFO()
ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(ai_pos, 0, 1, IS_LONG, 0)
    ZEND_ARG_TYPE_INFO(0, n, IS_LONG, 0)
ZEND_END_ARG_INFO()

PHP_FUNCTION(hello_addone) {
    zend_long n;
    ZEND_PARSE_PARAMETERS_START(1, 1) Z_PARAM_LONG(n) ZEND_PARSE_PARAMETERS_END();
    RETURN_LONG(n + 1);
}
PHP_FUNCTION(hello_greet) {
    zend_string *w;
    ZEND_PARSE_PARAMETERS_START(1, 1) Z_PARAM_STR(w) ZEND_PARSE_PARAMETERS_END();
    RETURN_STR(zend_strpprintf(0, "hi %s", ZSTR_VAL(w)));
}
PHP_FUNCTION(hello_half) {
    double x;
    ZEND_PARSE_PARAMETERS_START(1, 1) Z_PARAM_DOUBLE(x) ZEND_PARSE_PARAMETERS_END();
    RETURN_DOUBLE(x / 2.0);
}
PHP_FUNCTION(hello_not) {
    bool b;
    ZEND_PARSE_PARAMETERS_START(1, 1) Z_PARAM_BOOL(b) ZEND_PARSE_PARAMETERS_END();
    RETURN_BOOL(!b);
}
PHP_FUNCTION(hello_say) {
    zend_string *s;
    ZEND_PARSE_PARAMETERS_START(1, 1) Z_PARAM_STR(s) ZEND_PARSE_PARAMETERS_END();
    php_printf("[%s]\n", ZSTR_VAL(s));
}
PHP_FUNCTION(hello_sum) {
    zend_long a, b, c;
    ZEND_PARSE_PARAMETERS_START(3, 3)
        Z_PARAM_LONG(a) Z_PARAM_LONG(b) Z_PARAM_LONG(c)
    ZEND_PARSE_PARAMETERS_END();
    RETURN_LONG(a + b + c);
}
PHP_FUNCTION(hello_pos) {
    zend_long n;
    ZEND_PARSE_PARAMETERS_START(1, 1) Z_PARAM_LONG(n) ZEND_PARSE_PARAMETERS_END();
    if (n < 0) {
        zend_throw_exception_ex(zend_ce_exception, 0, "negative: " ZEND_LONG_FMT, n);
        RETURN_THROWS();
    }
    RETURN_LONG(n);
}

static const zend_function_entry refx_functions[] = {
    PHP_FE(hello_addone, ai_addone)
    PHP_FE(hello_greet,  ai_greet)
    PHP_FE(hello_half,   ai_half)
    PHP_FE(hello_not,    ai_not)
    PHP_FE(hello_say,    ai_say)
    PHP_FE(hello_sum,    ai_sum)
    PHP_FE(hello_pos,    ai_pos)
    PHP_FE_END
};

zend_module_entry refx_module_entry = {
    STANDARD_MODULE_HEADER,
    "hello", refx_functions,
    NULL, NULL, NULL, NULL, NULL,
    "0.1.0",
    STANDARD_MODULE_PROPERTIES
};
ZEND_GET_MODULE(refx)

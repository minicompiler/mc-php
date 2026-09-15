/* T2 -- the C side: a bundle shaped exactly like a php extension.
 *
 * Built with -bundle -undefined dynamic_lookup, so mcphp_cb and mcphp_va are
 * UNDEFINED here and resolved at dlopen time against whatever the host process
 * exports -- which is what every php-src .so does with _zend_* (T1).
 *
 * mcphp_va is called the way zend_parse_parameters is: a fixed first argument
 * and the rest variadic.
 */

long mcphp_cb(long a, long b);
long mcphp_va(const char *fmt, ...);

/* the callback road: a plain fixed-arity call into the host */
long ext_call_cb(void)
{
    return mcphp_cb(7, 35);
}

/* the variadic road: two integers after the format */
long ext_call_va(void)
{
    return mcphp_va("ll", 7, 35);
}

/* how the C compiler itself reads the same call, as the oracle */
#include <stdarg.h>

long c_va(const char *fmt, ...)
{
    va_list ap;
    long a, b;
    va_start(ap, fmt);
    a = va_arg(ap, long);
    b = va_arg(ap, long);
    va_end(ap);
    return a * 100 + b;
}

long ext_call_c_va(void)
{
    return c_va("ll", 7, 35);
}

/* how many variadic arguments reach the mc callee: parameters 9..12 are the
 * only slots mc has (MAXPARAMS 12), so four is the ceiling. */
long mcphp_va4(const char *fmt, ...);

long ext_call_va4(void)
{
    return mcphp_va4("llll", 1, 2, 3, 4);
}

long c_va4(const char *fmt, ...)
{
    va_list ap;
    long a, b, c, d;
    va_start(ap, fmt);
    a = va_arg(ap, long); b = va_arg(ap, long);
    c = va_arg(ap, long); d = va_arg(ap, long);
    va_end(ap);
    return ((a * 10 + b) * 10 + c) * 10 + d;
}

long ext_call_c_va4(void)
{
    return c_va4("llll", 1, 2, 3, 4);
}

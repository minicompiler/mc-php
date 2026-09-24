/* decimal.c -- the C TWIN of examples/decimal: the same six functions, the
 * same strings in and out, the same half-even rule, written the ordinary way
 * a C extension is written. It is the REFERENCE the compiled PHP is measured
 * against (examples/decimal/README.md), not a competitor tuned to win: plain
 * base-10 digit strings, schoolbook multiplication, long division by repeated
 * subtraction -- what a competent author writes first -- and the Zend
 * allocator for every buffer.
 *
 * Its answers are graded byte for byte against decimal.php interpreted by
 * the same check.php the compiled module is graded with (tests/examples.sh).
 *
 *     cc -bundle -undefined dynamic_lookup -O2 -o decimal.so decimal.c $(php-config --includes)
 *     cc -shared -fPIC -O2 -o decimal.so decimal.c $(php-config --includes)      # Linux
 */
#include "php.h"
#include "zend_exceptions.h"

/* ---- a number: sign, all its digits, how many of them follow the point ---- */
typedef struct {
    int neg;            /* negative, and not zero */
    const char *d;      /* the digits, integer part then fraction, no point */
    size_t n;
    size_t sc;
} dnum;

/* [+-]?[0-9]+(\.[0-9]+)? -- the digits are copied into `buf` (n + 1 bytes) */
static int dparse(zend_string *s, dnum *x, char *buf)
{
    const char *p = ZSTR_VAL(s), *e = p + ZSTR_LEN(s);
    int neg = 0;
    size_t n = 0, sc = 0, id = 0;
    if (p < e && (*p == '-' || *p == '+')) { neg = *p == '-'; p++; }
    while (p < e && *p >= '0' && *p <= '9') { buf[n++] = *p++; id++; }
    if (!id) return 0;
    if (p < e) {
        if (*p != '.') return 0;
        p++;
        while (p < e && *p >= '0' && *p <= '9') { buf[n++] = *p++; sc++; }
        if (!sc || p != e) return 0;
    }
    int allz = 1;
    for (size_t i = 0; i < n; i++) if (buf[i] != '0') { allz = 0; break; }
    x->neg = neg && !allz;
    x->d = buf;
    x->n = n;
    x->sc = sc;
    return 1;
}

static int dvalid(zend_string *s, dnum *x, char *buf, uint32_t argno)
{
    if (dparse(s, x, buf)) return 1;
    zend_argument_value_error(argno, "is not a decimal number");
    return 0;
}

/* ---- magnitudes: digit strings, most significant first ---------------------- */
static void skip0(const char **d, size_t *n) { while (*n > 1 && **d == '0') { (*d)++; (*n)--; } }

static int ucmp(const char *a, size_t na, const char *b, size_t nb)
{
    skip0(&a, &na); skip0(&b, &nb);
    if (na != nb) return na < nb ? -1 : 1;
    int c = memcmp(a, b, na);
    return c < 0 ? -1 : c > 0;
}

/* out has max(na, nb) + 1 bytes; returns its length */
static size_t uadd(const char *a, size_t na, const char *b, size_t nb, char *out)
{
    size_t n = (na > nb ? na : nb) + 1;
    int carry = 0;
    for (size_t k = 0; k < n; k++) {
        int d = carry;
        if (k < na) d += a[na - 1 - k] - '0';
        if (k < nb) d += b[nb - 1 - k] - '0';
        carry = d >= 10;
        out[n - 1 - k] = (char) ('0' + d % 10);
    }
    return n;
}

/* a >= b; out has na bytes */
static void usub(const char *a, size_t na, const char *b, size_t nb, char *out)
{
    int borrow = 0;
    for (size_t k = 0; k < na; k++) {
        int d = a[na - 1 - k] - '0' - borrow;
        if (k < nb) d -= b[nb - 1 - k] - '0';
        borrow = d < 0;
        out[na - 1 - k] = (char) ('0' + (d + 10) % 10);
    }
}

/* out has na + nb bytes */
static void umul(const char *a, size_t na, const char *b, size_t nb, char *out)
{
    size_t n = na + nb;
    uint64_t *acc = ecalloc(n, sizeof(uint64_t));
    for (size_t i = 0; i < na; i++) {
        uint64_t x = (uint64_t) (a[na - 1 - i] - '0');
        if (!x) continue;
        for (size_t j = 0; j < nb; j++) acc[i + j] += x * (uint64_t) (b[nb - 1 - j] - '0');
    }
    uint64_t carry = 0;
    for (size_t k = 0; k < n; k++) {
        uint64_t t = acc[k] + carry;
        out[n - 1 - k] = (char) ('0' + t % 10);
        carry = t / 10;
    }
    efree(acc);
}

/* long division, b not zero: q has na bytes, the remainder is left in r
 * (nb + 1 bytes) with length *nr */
static void udivmod(const char *a, size_t na, const char *b, size_t nb,
                    char *q, char *r, size_t *nr)
{
    skip0(&b, &nb);
    size_t n = 0;
    for (size_t i = 0; i < na; i++) {
        if (n == 1 && r[0] == '0') n = 0;
        r[n++] = a[i];
        int k = 0;
        while (ucmp(r, n, b, nb) >= 0) {
            const char *rr = r; size_t rn = n;
            skip0(&rr, &rn);
            memmove(r, rr, rn); n = rn;
            usub(r, n, b, nb, r);
            k++;
        }
        const char *rs = r; size_t rsn = n;
        skip0(&rs, &rsn);
        memmove(r, rs, rsn); n = rsn;
        q[i] = (char) ('0' + k);
    }
    if (!n) r[n++] = '0';
    *nr = n;
}

/* ---- the ONE place a result is rounded and written: half-even -------------- */
/* c: a magnitude at scale `from`; the answer has exactly `to` digits after
 * the point, and a zero is never negative */
static zend_string *dfmt(int neg, const char *c, size_t n, size_t from, size_t to)
{
    skip0(&c, &n);
    size_t cap = n + to + 3;
    char *w = emalloc(cap);
    size_t wn;
    if (from > to) {
        size_t k = from - to;
        /* the digits kept are the first n - k, each a zero where n <= k */
        size_t kn = n > k ? n - k : 0;
        int first = n >= k ? c[n - k] : '0';
        int up = 0;
        if (first > '5') up = 1;
        else if (first == '5') {
            for (size_t i = n - k + 1; i < n; i++) if (c[i] != '0') { up = 1; break; }
            if (!up) up = kn && (c[kn - 1] - '0') % 2 == 1;
        }
        if (!kn) { w[0] = '0'; wn = 1; } else { memcpy(w, c, kn); wn = kn; }
        if (up) {
            char *t = emalloc(wn + 1);
            wn = uadd(w, wn, "1", 1, t);
            const char *tt = t; skip0(&tt, &wn);
            memcpy(w, tt, wn);
            efree(t);
        }
    } else {
        memcpy(w, c, n); wn = n;
        if (!(wn == 1 && w[0] == '0')) { memset(w + wn, '0', to - from); wn += to - from; }
    }
    int z = 1;
    for (size_t i = 0; i < wn; i++) if (w[i] != '0') { z = 0; break; }
    if (z) neg = 0;
    size_t il = wn > to ? wn - to : 1;          /* digits before the point */
    size_t len = neg + il + (to ? to + 1 : 0);
    zend_string *s = zend_string_alloc(len, 0);
    char *o = ZSTR_VAL(s);
    if (neg) *o++ = '-';
    if (wn > to) { memcpy(o, w, il); o += il; }
    else *o++ = '0';
    if (to) {
        *o++ = '.';
        size_t fz = wn < to ? to - wn : 0;
        memset(o, '0', fz); o += fz;
        memcpy(o, w + (wn > to ? il : 0), wn > to ? to : wn); o += wn > to ? to : wn;
    }
    *o = 0;
    efree(w);
    return s;
}

/* a number's digits at scale s (>= its own): the magnitude padded with zeros */
static char *dat(const dnum *x, size_t s, size_t *n)
{
    *n = x->n + (s - x->sc);
    char *p = emalloc(*n + 1);
    memcpy(p, x->d, x->n);
    memset(p + x->n, '0', s - x->sc);
    return p;
}

#define DBUF(s) (ZSTR_LEN(s) + 1)

static int dscale(zend_long scale, uint32_t argno)
{
    if (scale >= 0) return 1;
    zend_argument_value_error(argno, "must be greater than or equal to 0");
    return 0;
}

static void daddsub(INTERNAL_FUNCTION_PARAMETERS, int minus)
{
    zend_string *a, *b;
    zend_long scale;
    ZEND_PARSE_PARAMETERS_START(3, 3)
        Z_PARAM_STR(a) Z_PARAM_STR(b) Z_PARAM_LONG(scale)
    ZEND_PARSE_PARAMETERS_END();
    if (!dscale(scale, 3)) RETURN_THROWS();
    char *ba = emalloc(DBUF(a)), *bb = emalloc(DBUF(b));
    dnum x, y;
    if (!dvalid(a, &x, ba, 1) || !dvalid(b, &y, bb, 2)) { efree(ba); efree(bb); RETURN_THROWS(); }
    if (minus && y.n) y.neg = !y.neg && ucmp(y.d, y.n, "0", 1) != 0;
    size_t s = x.sc > y.sc ? x.sc : y.sc, nx, ny;
    char *cx = dat(&x, s, &nx), *cy = dat(&y, s, &ny);
    size_t n = (nx > ny ? nx : ny) + 1;
    char *r = emalloc(n);
    int neg;
    if (x.neg == y.neg) {
        n = uadd(cx, nx, cy, ny, r);
        neg = x.neg;
    } else if (ucmp(cx, nx, cy, ny) >= 0) {
        usub(cx, nx, cy, ny, r); n = nx; neg = x.neg;
    } else {
        usub(cy, ny, cx, nx, r); n = ny; neg = y.neg;
    }
    RETVAL_STR(dfmt(neg, r, n, s, (size_t) scale));
    efree(r); efree(cx); efree(cy); efree(ba); efree(bb);
}

PHP_FUNCTION(dec_add) { daddsub(INTERNAL_FUNCTION_PARAM_PASSTHRU, 0); }
PHP_FUNCTION(dec_sub) { daddsub(INTERNAL_FUNCTION_PARAM_PASSTHRU, 1); }

PHP_FUNCTION(dec_mul)
{
    zend_string *a, *b;
    zend_long scale;
    ZEND_PARSE_PARAMETERS_START(3, 3)
        Z_PARAM_STR(a) Z_PARAM_STR(b) Z_PARAM_LONG(scale)
    ZEND_PARSE_PARAMETERS_END();
    if (!dscale(scale, 3)) RETURN_THROWS();
    char *ba = emalloc(DBUF(a)), *bb = emalloc(DBUF(b));
    dnum x, y;
    if (!dvalid(a, &x, ba, 1) || !dvalid(b, &y, bb, 2)) { efree(ba); efree(bb); RETURN_THROWS(); }
    char *r = emalloc(x.n + y.n);
    umul(x.d, x.n, y.d, y.n, r);
    RETVAL_STR(dfmt(x.neg != y.neg, r, x.n + y.n, x.sc + y.sc, (size_t) scale));
    efree(r); efree(ba); efree(bb);
}

/* a / b = (ca * 10^sb) / (cb * 10^sa), scaled by 10^scale: one integer
 * division, and 2r against the divisor decides the rounding */
PHP_FUNCTION(dec_div)
{
    zend_string *a, *b;
    zend_long scale;
    ZEND_PARSE_PARAMETERS_START(3, 3)
        Z_PARAM_STR(a) Z_PARAM_STR(b) Z_PARAM_LONG(scale)
    ZEND_PARSE_PARAMETERS_END();
    if (!dscale(scale, 3)) RETURN_THROWS();
    char *ba = emalloc(DBUF(a)), *bb = emalloc(DBUF(b));
    dnum x, y;
    if (!dvalid(a, &x, ba, 1) || !dvalid(b, &y, bb, 2)) { efree(ba); efree(bb); RETURN_THROWS(); }
    if (ucmp(y.d, y.n, "0", 1) == 0) {
        efree(ba); efree(bb);
        zend_throw_exception(zend_ce_division_by_zero_error, "Division by zero", 0);
        RETURN_THROWS();
    }
    size_t nn = x.n + y.sc + (size_t) scale, nd = y.n + x.sc;
    char *num = emalloc(nn), *den = emalloc(nd);
    memcpy(num, x.d, x.n); memset(num + x.n, '0', nn - x.n);
    memcpy(den, y.d, y.n); memset(den + y.n, '0', nd - y.n);
    char *q = emalloc(nn), *r = emalloc(nd + 2);
    size_t nr;
    udivmod(num, nn, den, nd, q, r, &nr);
    char *r2 = emalloc(nr + 1);
    size_t n2 = uadd(r, nr, r, nr, r2);
    int c = ucmp(r2, n2, den, nd);
    size_t nq = nn;
    char *qq = q;
    if (c > 0 || (c == 0 && (q[nn - 1] - '0') % 2 == 1)) {
        qq = emalloc(nn + 1);
        nq = uadd(q, nn, "1", 1, qq);
    }
    RETVAL_STR(dfmt(x.neg != y.neg, qq, nq, (size_t) scale, (size_t) scale));
    if (qq != q) efree(qq);
    efree(r2); efree(q); efree(r); efree(num); efree(den); efree(ba); efree(bb);
}

PHP_FUNCTION(dec_cmp)
{
    zend_string *a, *b;
    ZEND_PARSE_PARAMETERS_START(2, 2)
        Z_PARAM_STR(a) Z_PARAM_STR(b)
    ZEND_PARSE_PARAMETERS_END();
    char *ba = emalloc(DBUF(a)), *bb = emalloc(DBUF(b));
    dnum x, y;
    if (!dvalid(a, &x, ba, 1) || !dvalid(b, &y, bb, 2)) { efree(ba); efree(bb); RETURN_THROWS(); }
    zend_long r;
    if (x.neg != y.neg) {
        r = x.neg ? -1 : 1;
    } else {
        size_t s = x.sc > y.sc ? x.sc : y.sc, nx, ny;
        char *cx = dat(&x, s, &nx), *cy = dat(&y, s, &ny);
        r = ucmp(cx, nx, cy, ny);
        if (x.neg) r = -r;
        efree(cx); efree(cy);
    }
    efree(ba); efree(bb);
    RETURN_LONG(r);
}

PHP_FUNCTION(dec_round)
{
    zend_string *a;
    zend_long scale;
    ZEND_PARSE_PARAMETERS_START(2, 2)
        Z_PARAM_STR(a) Z_PARAM_LONG(scale)
    ZEND_PARSE_PARAMETERS_END();
    if (!dscale(scale, 2)) RETURN_THROWS();
    char *ba = emalloc(DBUF(a));
    dnum x;
    if (!dvalid(a, &x, ba, 1)) { efree(ba); RETURN_THROWS(); }
    RETVAL_STR(dfmt(x.neg, x.d, x.n, x.sc, (size_t) scale));
    efree(ba);
}

ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(ai_arith, 0, 3, IS_STRING, 0)
    ZEND_ARG_TYPE_INFO(0, a, IS_STRING, 0)
    ZEND_ARG_TYPE_INFO(0, b, IS_STRING, 0)
    ZEND_ARG_TYPE_INFO(0, scale, IS_LONG, 0)
ZEND_END_ARG_INFO()
ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(ai_cmp, 0, 2, IS_LONG, 0)
    ZEND_ARG_TYPE_INFO(0, a, IS_STRING, 0)
    ZEND_ARG_TYPE_INFO(0, b, IS_STRING, 0)
ZEND_END_ARG_INFO()
ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(ai_round, 0, 2, IS_STRING, 0)
    ZEND_ARG_TYPE_INFO(0, a, IS_STRING, 0)
    ZEND_ARG_TYPE_INFO(0, scale, IS_LONG, 0)
ZEND_END_ARG_INFO()

static const zend_function_entry decimal_functions[] = {
    PHP_FE(dec_add, ai_arith)
    PHP_FE(dec_sub, ai_arith)
    PHP_FE(dec_mul, ai_arith)
    PHP_FE(dec_div, ai_arith)
    PHP_FE(dec_cmp, ai_cmp)
    PHP_FE(dec_round, ai_round)
    PHP_FE_END
};

zend_module_entry decimal_module_entry = {
    STANDARD_MODULE_HEADER, "decimal", decimal_functions,
    NULL, NULL, NULL, NULL, NULL, "0.1.0", STANDARD_MODULE_PROPERTIES
};

ZEND_GET_MODULE(decimal)

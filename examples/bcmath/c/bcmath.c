/* bcmath.c -- the C TWIN of examples/bcmath: the same functions, the same
 * strings in and out, the same EXACT bcmath semantics (TRUNCATION at the
 * scale), written the ordinary way a C extension is written. It is the
 * REFERENCE the compiled PHP is measured against (examples/bcmath/README.md),
 * not a competitor tuned to win: plain base-10 digit strings, schoolbook
 * multiplication, long division by repeated subtraction, Newton's method for
 * the square root -- what a competent author writes first -- and the Zend
 * allocator for every buffer.
 *
 * Its answers are graded byte for byte against bcmath.php interpreted by the
 * same check.php the compiled module is graded with (tests/examples.sh). It is
 * bcmath.php's algorithm, function by function, so the three bench columns
 * measure one algorithm three ways. Functions are bc_* (php's own bcmath is
 * loaded; an internal name cannot be redeclared).
 *
 *     cc -bundle -undefined dynamic_lookup -O2 -o bcmath_port.so bcmath.c $(php-config --includes)
 *     cc -shared -fPIC -O2 -o bcmath_port.so bcmath.c $(php-config --includes)      # Linux
 */
#include "php.h"
#include "zend_exceptions.h"
#include <limits.h>

/* the request default scale (bcscale), set by bc_scale, used when the scale
 * argument is null. One CLI request, so a file-scope int matches the module's
 * per-request global. */
static int bc_def_scale = 0;

/* ---- a number: sign, all its digits, how many of them follow the point ---- */
typedef struct {
    int neg;            /* negative, and not zero */
    const char *d;      /* the digits, integer part then fraction, no point */
    size_t n;
    size_t sc;
} dnum;

/* bc_str2num's grammar: [+-]? [0-9]* ('.' [0-9]*)? and nothing else. Every part
 * may be empty, so "", ".", "5.", ".5" are all valid. Digits are copied into
 * `buf` (ZSTR_LEN + 2 bytes). */
static int bcparse(zend_string *s, dnum *x, char *buf)
{
    const char *p = ZSTR_VAL(s), *e = p + ZSTR_LEN(s);
    int neg = 0;
    size_t n = 0, sc = 0;
    if (p < e && (*p == '-' || *p == '+')) { neg = *p == '-'; p++; }
    while (p < e && *p >= '0' && *p <= '9') { buf[n++] = *p++; }
    if (p < e && *p == '.') {
        p++;
        while (p < e && *p >= '0' && *p <= '9') { buf[n++] = *p++; sc++; }
    }
    if (p != e) return 0;
    if (n == 0) { buf[0] = '0'; n = 1; }     /* "", ".", "+", "-" -> 0 */
    int allz = 1;
    for (size_t i = 0; i < n; i++) if (buf[i] != '0') { allz = 0; break; }
    x->neg = neg && !allz;
    x->d = buf;
    x->n = n;
    x->sc = sc;
    return 1;
}

static int bcvalid(zend_string *s, dnum *x, char *buf, uint32_t argno)
{
    if (bcparse(s, x, buf)) return 1;
    zend_argument_value_error(argno, "is not well-formed");
    return 0;
}

/* ---- magnitudes: digit strings, most significant first --------------------- */
static void skip0(const char **d, size_t *n) { while (*n > 1 && **d == '0') { (*d)++; (*n)--; } }

static int ucmp(const char *a, size_t na, const char *b, size_t nb)
{
    skip0(&a, &na); skip0(&b, &nb);
    if (na != nb) return na < nb ? -1 : 1;
    int c = memcmp(a, b, na);
    return c < 0 ? -1 : c > 0;
}

static int is_zero(const char *a, size_t na) { skip0(&a, &na); return na == 1 && a[0] == '0'; }

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
 * (nb + 2 bytes) with length *nr */
static void udivmod(const char *a, size_t na, const char *b, size_t nb,
                    char *q, char *r, size_t *nr)
{
    skip0(&b, &nb);
    size_t n = 0;
    for (size_t i = 0; i < na; i++) {
        if (n == 1 && r[0] == '0') n = 0;
        r[n++] = a[i];
        int k = 0;
        for (;;) {
            const char *rr = r; size_t rn = n;
            skip0(&rr, &rn);
            memmove(r, rr, rn); n = rn;
            if (ucmp(r, n, b, nb) < 0) break;
            usub(r, n, b, nb, r);
            k++;
        }
        q[i] = (char) ('0' + k);
    }
    if (!n) r[n++] = '0';
    *nr = n;
}

/* a malloc'd magnitude: a plain (char*, len) that the caller frees */
typedef struct { char *d; size_t n; } mag;

/* floor(S / x) and floor((x + S/x) / 2): Newton's integer square root */
static mag misqrt(const char *s, size_t ns)
{
    skip0(&s, &ns);
    if (ns == 1 && s[0] == '0') { mag z = { emalloc(1), 1 }; z.d[0] = '0'; return z; }
    size_t xn = 1 + (ns + 1) / 2;
    char *x = emalloc(xn + 2);
    x[0] = '1';
    memset(x + 1, '0', xn - 1);
    for (;;) {
        char *q = emalloc(ns + 1), *r = emalloc(ns + 2);
        size_t nr;
        udivmod(s, ns, x, xn, q, r, &nr);      /* q = floor(S / x), ns digits */
        char *sum = emalloc((ns > xn ? ns : xn) + 2);
        size_t nsum = uadd(x, xn, q, ns, sum);
        char *y = emalloc(nsum + 1), *ry = emalloc(3);
        size_t nry;
        udivmod(sum, nsum, "2", 1, y, ry, &nry);  /* y = floor((x + q) / 2) */
        const char *ys = y; size_t nys = nsum;
        skip0(&ys, &nys);
        int done = ucmp(ys, nys, x, xn) >= 0;
        if (!done) { memmove(x, ys, nys); xn = nys; }
        efree(q); efree(r); efree(sum); efree(y); efree(ry);
        if (done) break;
    }
    mag out = { x, xn };
    return out;
}

/* base^e (magnitude, e >= 1), exponentiation by squaring */
static mag mpow(const char *d, size_t nd, long e)
{
    skip0(&d, &nd);
    char *base = emalloc(nd); memcpy(base, d, nd); size_t nb = nd;
    char *res = emalloc(1); res[0] = '1'; size_t nres = 1;
    while (e > 0) {
        if (e & 1) {
            char *t = emalloc(nres + nb);
            umul(res, nres, base, nb, t);
            efree(res);
            const char *ts = t; size_t ns = nres + nb;
            skip0(&ts, &ns);
            res = emalloc(ns); memcpy(res, ts, ns); nres = ns;
            efree(t);
        }
        e >>= 1;
        if (e > 0) {
            char *t = emalloc(nb + nb);
            umul(base, nb, base, nb, t);
            efree(base);
            const char *ts = t; size_t ns = nb + nb;
            skip0(&ts, &ns);
            base = emalloc(ns); memcpy(base, ts, ns); nb = ns;
            efree(t);
        }
    }
    efree(base);
    mag out = { res, nres };
    return out;
}

/* ---- the ONE place a result is written: TRUNCATION, never rounding --------- */
/* c: a magnitude at scale `from`; the answer has exactly `to` digits after the
 * point, obtained by dropping (not rounding) the digits past `to` or padding
 * with zeros. A zero is never negative. */
static zend_string *bfmt(int neg, const char *c, size_t n, size_t from, size_t to)
{
    char *w = emalloc(n + to + 2);
    size_t wn;
    if (from > to) {
        size_t k = from - to;
        if (n > k) { memcpy(w, c, n - k); wn = n - k; }
        else { w[0] = '0'; wn = 1; }
    } else {
        memcpy(w, c, n); wn = n;
        memset(w + wn, '0', to - from); wn += to - from;
    }
    const char *ws = w; size_t wsn = wn;
    skip0(&ws, &wsn);
    int z = 1;
    for (size_t i = 0; i < wsn; i++) if (ws[i] != '0') { z = 0; break; }
    if (z) neg = 0;
    size_t il = wsn > to ? wsn - to : 1;
    size_t len = (size_t) (neg != 0) + il + (to ? to + 1 : 0);
    zend_string *s = zend_string_alloc(len, 0);
    char *o = ZSTR_VAL(s);
    if (neg) *o++ = '-';
    if (wsn > to) { memcpy(o, ws, il); o += il; }
    else *o++ = '0';
    if (to) {
        *o++ = '.';
        size_t fz = wsn < to ? to - wsn : 0;
        memset(o, '0', fz); o += fz;
        size_t fd = wsn > to ? to : wsn;
        memcpy(o, ws + (wsn > to ? il : 0), fd); o += fd;
    }
    *o = 0;
    efree(w);
    return s;
}

/* a number's digits at scale s (>= its own): the magnitude padded with zeros */
static char *bat(const dnum *x, size_t s, size_t *n)
{
    *n = x->n + (s - x->sc);
    char *p = emalloc(*n + 1);
    memcpy(p, x->d, x->n);
    memset(p + x->n, '0', s - x->sc);
    return p;
}

#define DBUF(s) (ZSTR_LEN(s) + 2)

/* resolve the optional scale argument into 0..INT_MAX; 0 = threw */
static int scaleof(zend_long sp, int isnull, uint32_t argno, int *out)
{
    if (isnull) { *out = bc_def_scale; return 1; }
    if (sp < 0 || sp > INT_MAX) {
        zend_argument_value_error(argno, "must be between 0 and %d", INT_MAX);
        return 0;
    }
    *out = (int) sp;
    return 1;
}

/* the fraction must be all zeros; returns the integer magnitude (skip0'd) */
static int intonly(dnum *x, uint32_t argno)
{
    if (x->sc > 0) {
        for (size_t i = x->n - x->sc; i < x->n; i++) {
            if (x->d[i] != '0') {
                zend_argument_value_error(argno, "cannot have a fractional part");
                return 0;
            }
        }
        x->n -= x->sc;
        if (x->n == 0) { x->n = 1; }   /* d still points at the leading '0' */
        x->sc = 0;
    }
    return 1;
}

/* ---- add / sub ------------------------------------------------------------- */
static void bc_addsub(INTERNAL_FUNCTION_PARAMETERS, int minus)
{
    zend_string *a, *b;
    zend_long sp;
    bool isnull = 1;
    int scale;
    ZEND_PARSE_PARAMETERS_START(2, 3)
        Z_PARAM_STR(a) Z_PARAM_STR(b)
        Z_PARAM_OPTIONAL Z_PARAM_LONG_OR_NULL(sp, isnull)
    ZEND_PARSE_PARAMETERS_END();
    if (!scaleof(sp, isnull, 3, &scale)) RETURN_THROWS();
    char *ba = emalloc(DBUF(a)), *bb = emalloc(DBUF(b));
    dnum x, y;
    if (!bcvalid(a, &x, ba, 1) || !bcvalid(b, &y, bb, 2)) { efree(ba); efree(bb); RETURN_THROWS(); }
    if (minus) y.neg = !y.neg && !is_zero(y.d, y.n);
    size_t s = x.sc > y.sc ? x.sc : y.sc, nx, ny;
    char *cx = bat(&x, s, &nx), *cy = bat(&y, s, &ny);
    size_t cap = (nx > ny ? nx : ny) + 1;
    char *r = emalloc(cap);
    size_t n;
    int neg;
    if (x.neg == y.neg) {
        n = uadd(cx, nx, cy, ny, r);
        neg = x.neg;
    } else if (ucmp(cx, nx, cy, ny) >= 0) {
        usub(cx, nx, cy, ny, r); n = nx; neg = x.neg;
    } else {
        usub(cy, ny, cx, nx, r); n = ny; neg = y.neg;
    }
    RETVAL_STR(bfmt(neg, r, n, s, (size_t) scale));
    efree(r); efree(cx); efree(cy); efree(ba); efree(bb);
}

PHP_FUNCTION(bc_add) { bc_addsub(INTERNAL_FUNCTION_PARAM_PASSTHRU, 0); }
PHP_FUNCTION(bc_sub) { bc_addsub(INTERNAL_FUNCTION_PARAM_PASSTHRU, 1); }

PHP_FUNCTION(bc_mul)
{
    zend_string *a, *b;
    zend_long sp;
    bool isnull = 1;
    int scale;
    ZEND_PARSE_PARAMETERS_START(2, 3)
        Z_PARAM_STR(a) Z_PARAM_STR(b)
        Z_PARAM_OPTIONAL Z_PARAM_LONG_OR_NULL(sp, isnull)
    ZEND_PARSE_PARAMETERS_END();
    if (!scaleof(sp, isnull, 3, &scale)) RETURN_THROWS();
    char *ba = emalloc(DBUF(a)), *bb = emalloc(DBUF(b));
    dnum x, y;
    if (!bcvalid(a, &x, ba, 1) || !bcvalid(b, &y, bb, 2)) { efree(ba); efree(bb); RETURN_THROWS(); }
    char *r = emalloc(x.n + y.n);
    umul(x.d, x.n, y.d, y.n, r);
    RETVAL_STR(bfmt(x.neg != y.neg, r, x.n + y.n, x.sc + y.sc, (size_t) scale));
    efree(r); efree(ba); efree(bb);
}

PHP_FUNCTION(bc_div)
{
    zend_string *a, *b;
    zend_long sp;
    bool isnull = 1;
    int scale;
    ZEND_PARSE_PARAMETERS_START(2, 3)
        Z_PARAM_STR(a) Z_PARAM_STR(b)
        Z_PARAM_OPTIONAL Z_PARAM_LONG_OR_NULL(sp, isnull)
    ZEND_PARSE_PARAMETERS_END();
    if (!scaleof(sp, isnull, 3, &scale)) RETURN_THROWS();
    char *ba = emalloc(DBUF(a)), *bb = emalloc(DBUF(b));
    dnum x, y;
    if (!bcvalid(a, &x, ba, 1) || !bcvalid(b, &y, bb, 2)) { efree(ba); efree(bb); RETURN_THROWS(); }
    if (is_zero(y.d, y.n)) {
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
    RETVAL_STR(bfmt(x.neg != y.neg, q, nn, (size_t) scale, (size_t) scale));
    efree(q); efree(r); efree(num); efree(den); efree(ba); efree(bb);
}

PHP_FUNCTION(bc_mod)
{
    zend_string *a, *b;
    zend_long sp;
    bool isnull = 1;
    int scale;
    ZEND_PARSE_PARAMETERS_START(2, 3)
        Z_PARAM_STR(a) Z_PARAM_STR(b)
        Z_PARAM_OPTIONAL Z_PARAM_LONG_OR_NULL(sp, isnull)
    ZEND_PARSE_PARAMETERS_END();
    if (!scaleof(sp, isnull, 3, &scale)) RETURN_THROWS();
    char *ba = emalloc(DBUF(a)), *bb = emalloc(DBUF(b));
    dnum x, y;
    if (!bcvalid(a, &x, ba, 1) || !bcvalid(b, &y, bb, 2)) { efree(ba); efree(bb); RETURN_THROWS(); }
    if (is_zero(y.d, y.n)) {
        efree(ba); efree(bb);
        zend_throw_exception(zend_ce_division_by_zero_error, "Modulo by zero", 0);
        RETURN_THROWS();
    }
    size_t s = x.sc > y.sc ? x.sc : y.sc, nx, ny;
    char *cx = bat(&x, s, &nx), *cy = bat(&y, s, &ny);
    char *q = emalloc(nx), *r = emalloc(ny + 2);
    size_t nr;
    udivmod(cx, nx, cy, ny, q, r, &nr);
    RETVAL_STR(bfmt(x.neg, r, nr, s, (size_t) scale));
    efree(q); efree(r); efree(cx); efree(cy); efree(ba); efree(bb);
}

PHP_FUNCTION(bc_pow)
{
    zend_string *a, *ex;
    zend_long sp;
    bool isnull = 1;
    int scale;
    ZEND_PARSE_PARAMETERS_START(2, 3)
        Z_PARAM_STR(a) Z_PARAM_STR(ex)
        Z_PARAM_OPTIONAL Z_PARAM_LONG_OR_NULL(sp, isnull)
    ZEND_PARSE_PARAMETERS_END();
    if (!scaleof(sp, isnull, 3, &scale)) RETURN_THROWS();
    char *ba = emalloc(DBUF(a)), *be = emalloc(DBUF(ex));
    dnum x, y;
    if (!bcvalid(a, &x, ba, 1) || !bcvalid(ex, &y, be, 2)) { efree(ba); efree(be); RETURN_THROWS(); }
    if (!intonly(&y, 2)) { efree(ba); efree(be); RETURN_THROWS(); }
    const char *ed = y.d; size_t ne = y.n;
    skip0(&ed, &ne);
    if (ne > 18) {
        efree(ba); efree(be);
        zend_argument_value_error(2, "is too large");
        RETURN_THROWS();
    }
    long e = 0;
    for (size_t i = 0; i < ne; i++) e = e * 10 + (ed[i] - '0');
    if (e == 0) { RETVAL_STR(bfmt(0, "1", 1, 0, (size_t) scale)); efree(ba); efree(be); return; }
    if (is_zero(x.d, x.n)) {
        if (y.neg) {
            efree(ba); efree(be);
            zend_throw_exception(zend_ce_division_by_zero_error, "Negative power of zero", 0);
            RETURN_THROWS();
        }
        RETVAL_STR(bfmt(0, "0", 1, 0, (size_t) scale));
        efree(ba); efree(be);
        return;
    }
    mag p = mpow(x.d, x.n, e);
    size_t psc = x.sc * (size_t) e;
    int psign = x.neg && (e & 1);
    if (!y.neg) {
        RETVAL_STR(bfmt(psign, p.d, p.n, psc, (size_t) scale));
    } else {
        size_t nn = 1 + psc + (size_t) scale;
        char *num = emalloc(nn);
        num[0] = '1'; memset(num + 1, '0', nn - 1);
        char *q = emalloc(nn), *r = emalloc(p.n + 2);
        size_t nr;
        udivmod(num, nn, p.d, p.n, q, r, &nr);
        RETVAL_STR(bfmt(psign, q, nn, (size_t) scale, (size_t) scale));
        efree(num); efree(q); efree(r);
    }
    efree(p.d); efree(ba); efree(be);
}

/* signed integer remainder (sign follows the dividend), for powmod */
static mag immod(int sa, const char *a, size_t na, const char *m, size_t nm, int *rsign)
{
    char *q = emalloc(na + 1), *r = emalloc(nm + 2);
    size_t nr;
    udivmod(a, na, m, nm, q, r, &nr);
    efree(q);
    char *out = emalloc(nr); memcpy(out, r, nr); efree(r);
    *rsign = sa && !(nr == 1 && out[0] == '0');
    mag v = { out, nr };
    return v;
}

PHP_FUNCTION(bc_powmod)
{
    zend_string *a, *ex, *mo;
    zend_long sp;
    bool isnull = 1;
    int scale;
    ZEND_PARSE_PARAMETERS_START(3, 4)
        Z_PARAM_STR(a) Z_PARAM_STR(ex) Z_PARAM_STR(mo)
        Z_PARAM_OPTIONAL Z_PARAM_LONG_OR_NULL(sp, isnull)
    ZEND_PARSE_PARAMETERS_END();
    if (!scaleof(sp, isnull, 4, &scale)) RETURN_THROWS();
    char *ba = emalloc(DBUF(a)), *be = emalloc(DBUF(ex)), *bm = emalloc(DBUF(mo));
    dnum x, y, m;
    if (!bcvalid(a, &x, ba, 1) || !bcvalid(ex, &y, be, 2) || !bcvalid(mo, &m, bm, 3)) {
        efree(ba); efree(be); efree(bm); RETURN_THROWS();
    }
    if (!intonly(&x, 1) || !intonly(&y, 2)) { efree(ba); efree(be); efree(bm); RETURN_THROWS(); }
    if (y.neg) {
        efree(ba); efree(be); efree(bm);
        zend_argument_value_error(2, "must be greater than or equal to 0");
        RETURN_THROWS();
    }
    if (!intonly(&m, 3)) { efree(ba); efree(be); efree(bm); RETURN_THROWS(); }
    if (is_zero(m.d, m.n)) {
        efree(ba); efree(be); efree(bm);
        zend_throw_exception(zend_ce_division_by_zero_error, "Modulo by zero", 0);
        RETURN_THROWS();
    }
    const char *md = m.d; size_t nm = m.n;
    skip0(&md, &nm);
    if (nm == 1 && md[0] == '1') {
        RETVAL_STR(bfmt(0, "0", 1, 0, (size_t) scale));
        efree(ba); efree(be); efree(bm);
        return;
    }
    /* power = base mod modulus (signed); temp = 1 */
    int psign;
    mag power = immod(x.neg, x.d, x.n, md, nm, &psign);
    int tsign = 0;
    char *temp = emalloc(1); temp[0] = '1'; size_t nt = 1;
    /* exponent magnitude, consumed by halving */
    const char *eds = y.d; size_t nes = y.n;
    skip0(&eds, &nes);
    char *exp = emalloc(nes); memcpy(exp, eds, nes); size_t nexp = nes;
    while (!(nexp == 1 && exp[0] == '0')) {
        int odd = (exp[nexp - 1] - '0') & 1;
        char *q = emalloc(nexp), *r = emalloc(3);
        size_t nr;
        udivmod(exp, nexp, "2", 1, q, r, &nr);
        const char *qs = q; size_t nq = nexp;
        skip0(&qs, &nq);
        memmove(exp, qs, nq); nexp = nq;
        efree(q); efree(r);
        if (odd) {
            /* temp = (temp * power) mod modulus */
            char *prod = emalloc(nt + power.n);
            umul(temp, nt, power.d, power.n, prod);
            int prodsign = tsign != psign;
            int ns;
            mag red = immod(prodsign, prod, nt + power.n, md, nm, &ns);
            efree(prod); efree(temp);
            temp = red.d; nt = red.n; tsign = ns;
        }
        /* power = (power * power) mod modulus (always non-negative) */
        char *sq = emalloc(power.n * 2);
        umul(power.d, power.n, power.d, power.n, sq);
        int ns2;
        mag red2 = immod(0, sq, power.n * 2, md, nm, &ns2);
        efree(sq); efree(power.d);
        power.d = red2.d; power.n = red2.n; psign = ns2;
    }
    RETVAL_STR(bfmt(tsign, temp, nt, 0, (size_t) scale));
    efree(temp); efree(power.d); efree(exp); efree(ba); efree(be); efree(bm);
}

PHP_FUNCTION(bc_sqrt)
{
    zend_string *a;
    zend_long sp;
    bool isnull = 1;
    int scale;
    ZEND_PARSE_PARAMETERS_START(1, 2)
        Z_PARAM_STR(a)
        Z_PARAM_OPTIONAL Z_PARAM_LONG_OR_NULL(sp, isnull)
    ZEND_PARSE_PARAMETERS_END();
    if (!scaleof(sp, isnull, 2, &scale)) RETURN_THROWS();
    char *ba = emalloc(DBUF(a));
    dnum x;
    if (!bcvalid(a, &x, ba, 1)) { efree(ba); RETURN_THROWS(); }
    if (x.neg) {
        efree(ba);
        zend_argument_value_error(1, "must be greater than or equal to 0");
        RETURN_THROWS();
    }
    if (is_zero(x.d, x.n)) { RETVAL_STR(bfmt(0, "0", 1, 0, (size_t) scale)); efree(ba); return; }
    long d2 = 2L * scale - (long) x.sc;
    char *mbuf;
    size_t nm;
    if (d2 >= 0) {
        nm = x.n + (size_t) d2;
        mbuf = emalloc(nm);
        memcpy(mbuf, x.d, x.n);
        memset(mbuf + x.n, '0', (size_t) d2);
    } else {
        size_t drop = (size_t) (-d2);
        if (x.n > drop) { nm = x.n - drop; mbuf = emalloc(nm); memcpy(mbuf, x.d, nm); }
        else { nm = 1; mbuf = emalloc(1); mbuf[0] = '0'; }
    }
    mag root = misqrt(mbuf, nm);
    RETVAL_STR(bfmt(0, root.d, root.n, (size_t) scale, (size_t) scale));
    efree(root.d); efree(mbuf); efree(ba);
}

PHP_FUNCTION(bc_comp)
{
    zend_string *a, *b;
    zend_long sp;
    bool isnull = 1;
    int scale;
    ZEND_PARSE_PARAMETERS_START(2, 3)
        Z_PARAM_STR(a) Z_PARAM_STR(b)
        Z_PARAM_OPTIONAL Z_PARAM_LONG_OR_NULL(sp, isnull)
    ZEND_PARSE_PARAMETERS_END();
    if (!scaleof(sp, isnull, 3, &scale)) RETURN_THROWS();
    char *ba = emalloc(DBUF(a)), *bb = emalloc(DBUF(b));
    dnum x, y;
    if (!bcvalid(a, &x, ba, 1) || !bcvalid(b, &y, bb, 2)) { efree(ba); efree(bb); RETURN_THROWS(); }
    size_t tx = x.sc > (size_t) scale ? (size_t) scale : x.sc;
    size_t ty = y.sc > (size_t) scale ? (size_t) scale : y.sc;
    size_t nxd = x.n - (x.sc - tx);
    size_t nyd = y.n - (y.sc - ty);
    int xn = x.neg && !is_zero(x.d, nxd);
    int yn = y.neg && !is_zero(y.d, nyd);
    zend_long r;
    if (xn != yn) {
        r = xn ? -1 : 1;
    } else {
        size_t s = tx > ty ? tx : ty;
        char *cx = emalloc(nxd + (s - tx) + 1), *cy = emalloc(nyd + (s - ty) + 1);
        memcpy(cx, x.d, nxd); memset(cx + nxd, '0', s - tx);
        memcpy(cy, y.d, nyd); memset(cy + nyd, '0', s - ty);
        r = ucmp(cx, nxd + (s - tx), cy, nyd + (s - ty));
        if (xn) r = -r;
        efree(cx); efree(cy);
    }
    efree(ba); efree(bb);
    RETURN_LONG(r);
}

PHP_FUNCTION(bc_scale)
{
    zend_long sp;
    bool isnull = 1;
    ZEND_PARSE_PARAMETERS_START(0, 1)
        Z_PARAM_OPTIONAL Z_PARAM_LONG_OR_NULL(sp, isnull)
    ZEND_PARSE_PARAMETERS_END();
    zend_long old = bc_def_scale;
    if (!isnull) {
        if (sp < 0 || sp > INT_MAX) {
            zend_argument_value_error(1, "must be between 0 and %d", INT_MAX);
            RETURN_THROWS();
        }
        bc_def_scale = (int) sp;
    }
    RETURN_LONG(old);
}

static void bc_floorceil(INTERNAL_FUNCTION_PARAMETERS, int isfloor)
{
    zend_string *a;
    ZEND_PARSE_PARAMETERS_START(1, 1)
        Z_PARAM_STR(a)
    ZEND_PARSE_PARAMETERS_END();
    char *ba = emalloc(DBUF(a));
    dnum x;
    if (!bcvalid(a, &x, ba, 1)) { efree(ba); RETURN_THROWS(); }
    size_t ilen = x.sc >= x.n ? 0 : x.n - x.sc;
    char *ip;
    size_t nip;
    if (ilen == 0) { ip = emalloc(1); ip[0] = '0'; nip = 1; }
    else { ip = emalloc(ilen); memcpy(ip, x.d, ilen); nip = ilen; }
    int fracnz = 0;
    for (size_t i = ilen; i < x.n; i++) if (x.d[i] != '0') { fracnz = 1; break; }
    if (fracnz && ((x.neg && isfloor) || (!x.neg && !isfloor))) {
        char *t = emalloc(nip + 1);
        size_t nt = uadd(ip, nip, "1", 1, t);
        efree(ip); ip = t; nip = nt;
    }
    RETVAL_STR(bfmt(x.neg, ip, nip, 0, 0));
    efree(ip); efree(ba);
}

PHP_FUNCTION(bc_floor) { bc_floorceil(INTERNAL_FUNCTION_PARAM_PASSTHRU, 1); }
PHP_FUNCTION(bc_ceil)  { bc_floorceil(INTERNAL_FUNCTION_PARAM_PASSTHRU, 0); }

/* round, HalfAwayFromZero (the default mode), negative precision allowed */
PHP_FUNCTION(bc_round)
{
    zend_string *a;
    zend_long precision = 0;
    ZEND_PARSE_PARAMETERS_START(1, 2)
        Z_PARAM_STR(a)
        Z_PARAM_OPTIONAL Z_PARAM_LONG(precision)
    ZEND_PARSE_PARAMETERS_END();
    if (precision > INT_MAX) {
        zend_argument_value_error(2, "must be between " ZEND_LONG_FMT " and %d", (zend_long) ZEND_LONG_MIN, INT_MAX);
        RETURN_THROWS();
    }
    char *ba = emalloc(DBUF(a));
    dnum x;
    if (!bcvalid(a, &x, ba, 1)) { efree(ba); RETURN_THROWS(); }
    /* canonical n_value: integer part leading zeros removed (>=1), then sc frac */
    size_t total = x.n;
    long ilen = (long) total - (long) x.sc;
    char *nval;
    size_t nlen, nsize;
    if (ilen <= 0) {
        nlen = 1;
        nsize = 1 + (size_t) (-ilen) + x.sc;   /* '0' + leading frac zeros + frac */
        nval = emalloc(nsize + 2);
        nval[0] = '0';
        memset(nval + 1, '0', (size_t) (-ilen));
        memcpy(nval + 1 + (size_t) (-ilen), x.d, x.n);
    } else {
        const char *ip = x.d; size_t nip = (size_t) ilen;
        skip0(&ip, &nip);
        nlen = nip;
        nsize = nlen + x.sc;
        nval = emalloc(nsize + 2);
        memcpy(nval, ip, nip);
        memcpy(nval + nip, x.d + ilen, x.sc);
    }
    zend_string *out;
    if (precision < 0 && (long) nlen < -(precision + 1) + 1) {
        out = zend_string_init("0", 1, 0);
    } else if (precision >= 0 && (long) x.sc <= precision) {
        out = bfmt(x.neg, nval, nsize, x.sc, (size_t) precision);
    } else {
        size_t rsc = precision > 0 ? (size_t) precision : 0;
        long rlen = (long) nlen + precision;    /* kept digits from the left */
        int up = rlen < (long) nsize && (nval[rlen] - '0') >= 5;
        if (rlen <= 0) {
            if (!up) out = bfmt(0, "0", 1, 0, rsc);
            else {
                size_t zn = nlen - (size_t) rlen;  /* rlen <= 0 */
                char *one = emalloc(1 + zn);
                one[0] = '1'; memset(one + 1, '0', zn);
                out = bfmt(x.neg, one, 1 + zn, 0, rsc);
                efree(one);
            }
        } else {
            size_t w = nlen + rsc;
            char *kept = emalloc(w + 2);
            memcpy(kept, nval, (size_t) rlen);
            memset(kept + rlen, '0', w - (size_t) rlen);
            if (up) {
                char *one = emalloc(w);
                memset(one, '0', w);
                one[rlen - 1] = '1';
                char *sum = emalloc(w + 1);
                size_t nsum = uadd(kept, w, one, w, sum);
                out = bfmt(x.neg, sum, nsum, rsc, rsc);
                efree(one); efree(sum);
            } else {
                out = bfmt(x.neg, kept, w, rsc, rsc);
            }
            efree(kept);
        }
    }
    efree(nval); efree(ba);
    RETVAL_STR(out);
}

/* ---- arginfo (the names matter: they appear in the error messages) --------- */
ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(ai_bin, 0, 2, IS_STRING, 0)
    ZEND_ARG_TYPE_INFO(0, num1, IS_STRING, 0)
    ZEND_ARG_TYPE_INFO(0, num2, IS_STRING, 0)
    ZEND_ARG_TYPE_INFO_WITH_DEFAULT_VALUE(0, scale, IS_LONG, 1, "null")
ZEND_END_ARG_INFO()
ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(ai_comp, 0, 2, IS_LONG, 0)
    ZEND_ARG_TYPE_INFO(0, num1, IS_STRING, 0)
    ZEND_ARG_TYPE_INFO(0, num2, IS_STRING, 0)
    ZEND_ARG_TYPE_INFO_WITH_DEFAULT_VALUE(0, scale, IS_LONG, 1, "null")
ZEND_END_ARG_INFO()
ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(ai_pow, 0, 2, IS_STRING, 0)
    ZEND_ARG_TYPE_INFO(0, num, IS_STRING, 0)
    ZEND_ARG_TYPE_INFO(0, exponent, IS_STRING, 0)
    ZEND_ARG_TYPE_INFO_WITH_DEFAULT_VALUE(0, scale, IS_LONG, 1, "null")
ZEND_END_ARG_INFO()
ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(ai_powmod, 0, 3, IS_STRING, 0)
    ZEND_ARG_TYPE_INFO(0, num, IS_STRING, 0)
    ZEND_ARG_TYPE_INFO(0, exponent, IS_STRING, 0)
    ZEND_ARG_TYPE_INFO(0, modulus, IS_STRING, 0)
    ZEND_ARG_TYPE_INFO_WITH_DEFAULT_VALUE(0, scale, IS_LONG, 1, "null")
ZEND_END_ARG_INFO()
ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(ai_sqrt, 0, 1, IS_STRING, 0)
    ZEND_ARG_TYPE_INFO(0, num, IS_STRING, 0)
    ZEND_ARG_TYPE_INFO_WITH_DEFAULT_VALUE(0, scale, IS_LONG, 1, "null")
ZEND_END_ARG_INFO()
ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(ai_scale, 0, 0, IS_LONG, 0)
    ZEND_ARG_TYPE_INFO_WITH_DEFAULT_VALUE(0, scale, IS_LONG, 1, "null")
ZEND_END_ARG_INFO()
ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(ai_un, 0, 1, IS_STRING, 0)
    ZEND_ARG_TYPE_INFO(0, num, IS_STRING, 0)
ZEND_END_ARG_INFO()
ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(ai_round, 0, 1, IS_STRING, 0)
    ZEND_ARG_TYPE_INFO(0, num, IS_STRING, 0)
    ZEND_ARG_TYPE_INFO_WITH_DEFAULT_VALUE(0, precision, IS_LONG, 0, "0")
ZEND_END_ARG_INFO()

static const zend_function_entry bcmath_functions[] = {
    PHP_FE(bc_add, ai_bin)
    PHP_FE(bc_sub, ai_bin)
    PHP_FE(bc_mul, ai_bin)
    PHP_FE(bc_div, ai_bin)
    PHP_FE(bc_mod, ai_bin)
    PHP_FE(bc_pow, ai_pow)
    PHP_FE(bc_powmod, ai_powmod)
    PHP_FE(bc_sqrt, ai_sqrt)
    PHP_FE(bc_comp, ai_comp)
    PHP_FE(bc_scale, ai_scale)
    PHP_FE(bc_floor, ai_un)
    PHP_FE(bc_ceil, ai_un)
    PHP_FE(bc_round, ai_round)
    PHP_FE_END
};

zend_module_entry bcmath_port_module_entry = {
    STANDARD_MODULE_HEADER, "bcmath_port", bcmath_functions,
    NULL, NULL, NULL, NULL, NULL, "0.1.0", STANDARD_MODULE_PROPERTIES
};

ZEND_GET_MODULE(bcmath_port)

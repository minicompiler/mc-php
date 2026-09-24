// php_rt.mc -- the runtime, pushed into every program the compiler compiles
// (src/program.mc's user_init: #embed + p_push_source). It is mc source, not
// a library the program links: there is no linker on this road.
//
// Carved from probes/t10/php_rt.txt, which is frozen. This header block
// replaces that file's, and is the whole difference between the two:
// tests/carve.sh compares everything from the D10 table down and requires
// it to be byte for byte identical. The header may be any length.
//
// docs/plan.md D10 is the lowering table this file implements:
//   bool   -> u8, the two values 0 and 1
//   int    -> i64
//   float  -> f64 (<float>)
//   string -> a handle to a zend_string-shaped record, BINARY-SAFE and never
//             encoding-validated: strlen("\xc3\xa9") is 2. Immutable: every
//             write makes a new string.
//   array  -> a packed vector of 8-byte slots, HOMOGENEOUS (T5's own limit,
//             named at the refusal, not silently coerced)
//
// D7 is the memory model: one arena, never freed, released by exit.
//
// The system layer is NOT here. `#include <sys>` is libSystem's, and a runtime
// that names it writes macOS programs and nothing else; since the hosts branch
// it is one file per host under lib/rt_host_*.mc, pushed ahead of this one by
// src/program.mc. Everything below may call open/read/write/close/exit/creat,
// stat/lseek/access/getenv/unlink/rename/mkdir/rmdir/getpid/getcwd/chdir/
// chmod/putenv/unsetenv, the O_ and S_IF flags, and php_stat_mode and
// php_stat_size -- and the host layer is what answers all of it.

// ---- the arena (D7) --------------------------------------------------------
#define PH_ARENA 50331648

u8  ph_heap[50331648];
i64 ph_top;

void php_flush();
void php_die(uptr msg, i64 n) { php_flush(); write(2, msg, n); exit(255); }

uptr php_alloc(i64 n) {
    i64 a = (ph_top + 7) / 8 * 8;
    if (a + n > PH_ARENA) php_die("mc-php: arena exhausted\n", 24);
    ph_top = a + n;
    return ph_heap + a;
}

// ---- string: the zend_string shape (T3's probes/t3/zend.mc, verbatim) ------
// 0 refcount u32 | 4 type_info u32 | 8 h u64 | 16 len u64 | 24 val[]
#define ZS_HDR 24

uptr php_str_alloc(i64 n) {
    uptr s = php_alloc(ZS_HDR + n + 1);
    st32(s, 1);
    st32(s + 4, 22);                          // GC_STRING
    st64(s + 8, 0);                           // h: not computed
    st64(s + 16, n);
    st8(s + ZS_HDR + n, 0);
    return s;
}

i64  php_strlen(uptr s) { return ld64(s + 16); }
uptr php_str_val(uptr s) { return s + ZS_HDR; }

void php_memcpy(uptr d, uptr s, i64 n) {
    i64 i = 0;
    loop { if (i >= n) break; st8(d + i, ld8(s + i)); i = i + 1; }
}

uptr php_str_new(uptr b, i64 n) {
    uptr s = php_str_alloc(n);
    php_memcpy(s + ZS_HDR, b, n);
    return s;
}

// A literal is built once per program run and cached in a global the compiler
// emits beside it -- an arena with no free cannot afford one copy per loop
// iteration (D7's risk, measured in RESULTS.md).
uptr php_str_lit(uptr cache, uptr b, i64 n) {
    uptr s = ld64(cache);
    if (s) return s;
    s = php_str_new(b, n);
    st64(cache, s);
    return s;
}

uptr php_str_concat(uptr a, uptr b) {
    i64 la = php_strlen(a);
    i64 lb = php_strlen(b);
    uptr s = php_str_alloc(la + lb);
    php_memcpy(s + ZS_HDR, a + ZS_HDR, la);
    php_memcpy(s + ZS_HDR + la, b + ZS_HDR, lb);
    return s;
}

// memcmp over the bytes, then the length: PHP's own strcmp ordering.
i64 php_str_cmp(uptr a, uptr b) {
    i64 la = php_strlen(a);
    i64 lb = php_strlen(b);
    i64 n = la;
    if (lb < n) n = lb;
    i64 i = 0;
    loop {
        if (i >= n) break;
        i64 x = ld8(a + ZS_HDR + i);
        i64 y = ld8(b + ZS_HDR + i);
        if (x != y) { if (x < y) return -1; return 1; }
        i = i + 1;
    }
    if (la < lb) return -1;
    if (la > lb) return 1;
    return 0;
}

i64 php_str_eq(uptr a, uptr b) { if (php_str_cmp(a, b) == 0) return 1; return 0; }

// ---- int and bool to string ------------------------------------------------
uptr php_itos(i64 v) {
    u8 t[24];
    i64 k = 0;
    i64 neg = 0;
    u64 u = v;
    if (v < 0) { neg = 1; u = 0 - u; }
    loop {
        st8(t + k, '0' + u % 10);
        u = u / 10;
        k = k + 1;
        if (u == 0) break;
    }
    uptr s = php_str_alloc(k + neg);
    if (neg) st8(s + ZS_HDR, '-');
    i64 i = 0;
    loop {
        if (i >= k) break;
        st8(s + ZS_HDR + neg + i, ld8(t + k - 1 - i));
        i = i + 1;
    }
    return s;
}

uptr php_btos(u8 b) {
    if (b) return php_str_new("1", 1);
    return php_str_new("", 0);
}

// ---- float formatting ------------------------------------------------------
// PHP prints a float two ways and this runtime implements both:
//   echo / string cast : precision=14, php's %.14G with its own ".0E+" shape
//   var_dump           : serialize_precision=-1, the SHORTEST decimal that
//                        reads back as the same double
// The digits come from scaling by an exact power of ten (the doubles 1e0..1e22
// are exact) and the last digit is then corrected by trying d-1, d, d+1 and
// keeping the one whose exact reconstruction is nearest. Outside 1e-22..1e22
// the reconstruction is not exact and the shortest-repr search gives up at 17
// digits -- named in RESULTS.md, not hidden.
f64 ph_p10[23];
i64 ph_p10_done;

void ph_p10_init() {
    if (ph_p10_done) return;
    ph_p10_done = 1;
    f64 v = 1.0;
    i64 i = 0;
    loop {
        if (i > 22) break;
        stf64(ph_p10 + i * 8, v);
        v = v * 10.0;
        i = i + 1;
    }
}

f64 ph_pow10(i64 e) {
    ph_p10_init();
    i64 m = e;
    if (m < 0) m = 0 - m;
    f64 r = 1.0;
    if (m <= 22) r = ldf64(ph_p10 + m * 8);
    if (m > 22) {
        f64 b = 10.0;
        i64 k = m;
        loop {
            if (k == 0) break;
            if (k & 1) r = r * b;
            b = b * b;
            k = k >> 1;
        }
    }
    if (e < 0) return 1.0 / r;
    return r;
}

u64 ph_bits(f64 x) { u8 t[8]; stf64(t, x); return ld64(t); }

// IEEE negation, sign bit and all: `0.0 - x` gives +0 for x == 0 and php
// prints -0 for the literal -0.0.
f64 php_fneg(f64 x) { u8 t[8]; stf64(t, x); st64(t, ld64(t) ^ 0x8000000000000000); return ldf64(t); }
f64 ph_unbits(u64 b) { u8 t[8]; st64(t, b); return ldf64(t); }

i64 ph_is_nan(f64 x) {
    u64 b = ph_bits(x);
    if (((b >> 52) & 0x7ff) != 0x7ff) return 0;
    if ((b << 12) == 0) return 0;
    return 1;
}
i64 ph_is_inf(f64 x) {
    u64 b = ph_bits(x);
    if (((b >> 52) & 0x7ff) != 0x7ff) return 0;
    if ((b << 12) != 0) return 0;
    return 1;
}

// digits * 10^e, exactly rounded whenever both halves are exact (|e| <= 22 and
// digits < 2^53) -- Clinger's fast path.
f64 ph_scale(i64 digits, i64 e) {
    ph_p10_init();
    // Past 2^53 an i64 is no longer exactly a double, so split it: both halves
    // are exact and so is each power of ten, and only the final add rounds.
    if (digits >= 9007199254740992) {
        i64 hi = digits / 100000000;
        i64 lo = digits - hi * 100000000;
        return ph_scale(hi, e + 8) + ph_scale(lo, e);
    }
    f64 d = (f64) digits;
    if (e == 0) return d;
    // 10^0..10^22 are the powers of ten an IEEE double holds EXACTLY, so one
    // multiply or divide by one of them is correctly rounded and that is the
    // whole of the common case. Past 22 the power is built by SQUARING -- a
    // handful of roundings -- and applied in ONE step, because scaling the
    // value in chunks instead walks a small number through the subnormals and
    // never comes back: 1e-300 came out 2.233720368547758e-300 and 1.7E-300
    // came out 3.720368547758E-299.
    i64 m = e;
    if (m < 0) m = 0 - m;
    if (m <= 22) {
        if (e > 0) return d * ldf64(ph_p10 + e * 8);
        return d / ldf64(ph_p10 + m * 8);
    }
    // 10^309 is already infinity, so a bigger power is applied in two halves
    if (m > 300) {
        f64 h = ph_scale(digits, e / 2);
        if (e > 0) return h * ph_pow10(e - e / 2);
        return h / ph_pow10(0 - (e - e / 2));
    }
    f64 p = ph_pow10(m);
    if (e > 0) return d * p;
    return d / p;
}

// x * 10^e with no intermediate overflow: 10^316 is infinity, and a single
// multiply by it turns a perfectly good 1e-300 into garbage.
f64 ph_scale2(f64 x, i64 e) {
    if (e > 300)  return ph_scale2(x * ph_pow10(300), e - 300);
    if (e < -300) return ph_scale2(x / ph_pow10(300), e + 300);
    if (e >= 0) return x * ph_pow10(e);
    return x / ph_pow10(0 - e);
}

// decimal exponent of |x| (x > 0): the k with 10^k <= x < 10^(k+1)
i64 ph_e10(f64 x) {
    i64 k = 0;
    loop {
        if (x < ph_pow10(k + 1)) break;
        k = k + 1;
        if (k > 308) break;
    }
    loop {
        if (k <= -324) break;
        if (x >= ph_pow10(k)) break;
        k = k - 1;
    }
    return k;
}

// the `prec` significant digits of x > 0, as an integer, with the decimal
// exponent written through `pe`: x ~= digits * 10^(*pe)
i64 ph_digits(f64 x, i64 prec, uptr pe) {
    i64 k = ph_e10(x);
    i64 lim = 1;
    i64 i = 0;
    loop { if (i >= prec) break; lim = lim * 10; i = i + 1; }
    i64 tries = 0;
    i64 e = 0;
    i64 d = 0;
    loop {
        e = k - prec + 1;
        // 10^316 is infinity, so a scale that big is applied in two steps --
        // one shot made every |x| below about 1e-293 come out as the digits
        // of 2^63 (1e-300 printed 2.233720368547758e-300).
        f64 y = ph_scale2(x, 0 - e);
        // NOT (i64)(y + 0.5): once |y| >= 2^52 the spacing is 1 and y + 0.5
        // ties to even, which rounds an odd exact integer UP.
        d = (i64) y;
        f64 fr = y - (f64) d;
        if (fr > 0.5) d = d + 1;
        if (fr == 0.5) { if (d & 1) d = d + 1; }   // an exact tie rounds to even
        // the scaling above can be a ulp out: keep whichever of d-1, d, d+1
        // reconstructs nearest to x.
        i64 best = d;
        f64 bd = -1.0;
        i64 j = 0;
        loop {
            if (j > 2) break;
            i64 c = d;                       // d first, so it keeps a tie
            if (j == 1) c = d - 1;
            if (j == 2) c = d + 1;
            if (c > 0) {
                f64 r = ph_scale(c, e);
                f64 df = r - x;
                if (df < 0.0) df = 0.0 - df;
                if (bd < 0.0 || df < bd) { bd = df; best = c; }
            }
            j = j + 1;
        }
        d = best;
        if (d >= lim) { d = d / 10; e = e + 1; break; }
        // ph_e10 leans on an inexact power of ten past 1e22, so it can be one
        // too low and leave a leading zero (1e-290 printed 0.9999...e-290).
        // One retry with the next exponent is enough.
        if (d >= lim / 10) break;
        tries = tries + 1;
        if (tries > 1) break;
        k = k - 1;
    }
    st64(pe, e);
    return d;
}

// write `d` (prec digits) with decimal exponent `e` in php's %G shape
i64 ph_fmt_dig(uptr b, i64 neg, i64 d, i64 prec, i64 e, i64 trim, i64 ndig) {
    u8 t[24];
    i64 k = 0;
    i64 u = d;
    loop { st8(t + k, '0' + u % 10); u = u / 10; k = k + 1; if (u == 0) break; }
    loop { if (k >= prec) break; st8(t + k, '0'); k = k + 1; }
    // t holds the digits least-significant first, k == prec
    i64 last = prec;
    if (trim) { loop { if (last <= 1) break; if (ld8(t + prec - last) != '0') break; last = last - 1; } }
    i64 exp = e + prec - 1;                  // the value is 0.d1d2... * 10^(exp+1)
    i64 n = 0;
    if (neg) { st8(b, '-'); n = 1; }
    // zend_gcvt's own switch: with decpt = exp + 1 and ndigit the precision it
    // was called with (14 for echo, 17 for serialize_precision=-1), scientific
    // iff decpt < -3 or decpt > ndigit.
    i64 decpt = exp + 1;
    if (decpt < -3 || decpt > ndig) {
        st8(b + n, '0' + ld8(t + prec - 1) - '0'); n = n + 1;
        st8(b + n, '.'); n = n + 1;
        if (last == 1) { st8(b + n, '0'); n = n + 1; }
        i64 i = 1;
        loop { if (i >= last) break; st8(b + n, ld8(t + prec - 1 - i)); n = n + 1; i = i + 1; }
        st8(b + n, 'E'); n = n + 1;
        i64 ae = exp;
        if (ae < 0) { st8(b + n, '-'); ae = 0 - ae; } else { st8(b + n, '+'); }
        n = n + 1;
        u8 eb[8];
        i64 ek = 0;
        loop { st8(eb + ek, '0' + ae % 10); ae = ae / 10; ek = ek + 1; if (ae == 0) break; }
        loop { if (ek == 0) break; ek = ek - 1; st8(b + n, ld8(eb + ek)); n = n + 1; }
        return n;
    }
    if (exp >= 0) {
        i64 i = 0;
        loop {
            if (i > exp) break;
            if (i < last) st8(b + n, ld8(t + prec - 1 - i));
            if (i >= last) st8(b + n, '0');
            n = n + 1;
            i = i + 1;
        }
        if (last > exp + 1) {
            st8(b + n, '.'); n = n + 1;
            i = exp + 1;
            loop { if (i >= last) break; st8(b + n, ld8(t + prec - 1 - i)); n = n + 1; i = i + 1; }
        }
        return n;
    }
    st8(b + n, '0'); n = n + 1;
    st8(b + n, '.'); n = n + 1;
    i64 z = 0 - exp - 1;
    loop { if (z <= 0) break; st8(b + n, '0'); n = n + 1; z = z - 1; }
    i64 i2 = 0;
    loop { if (i2 >= last) break; st8(b + n, ld8(t + prec - 1 - i2)); n = n + 1; i2 = i2 + 1; }
    return n;
}

// prec > 0: that many significant digits. prec == 0: the shortest decimal that
// reads back as the same double (serialize_precision=-1).
i64 php_fmt_f64(uptr b, f64 x, i64 prec) {
    if (ph_is_nan(x)) { php_memcpy(b, "NAN", 3); return 3; }
    if (ph_is_inf(x)) {
        if (x < 0.0) { php_memcpy(b, "-INF", 4); return 4; }
        php_memcpy(b, "INF", 3);
        return 3;
    }
    i64 neg = 0;
    f64 a = x;
    if ((ph_bits(x) >> 63) != 0) { neg = 1; a = 0.0 - x; }
    if (a == 0.0) { if (neg) { php_memcpy(b, "-0", 2); return 2; } st8(b, '0'); return 1; }
    u8 pe[8];
    if (prec > 0) {
        i64 d = ph_digits(a, prec, pe);
        return ph_fmt_dig(b, neg, d, prec, ld64(pe), 1, prec);
    }
    i64 p = 1;
    loop {
        if (p > 17) break;
        i64 d = ph_digits(a, p, pe);
        if (ph_scale(d, ld64(pe)) == a) return ph_fmt_dig(b, neg, d, p, ld64(pe), 0, 17);
        p = p + 1;
    }
    i64 d17 = ph_digits(a, 17, pe);
    return ph_fmt_dig(b, neg, d17, 17, ld64(pe), 1, 17);
}

uptr php_ftos(f64 x) {
    u8 t[64];
    i64 n = php_fmt_f64(t, x, 14);
    return php_str_new(t, n);
}

// ---- string to number (php's leading-numeric rule) -------------------------
i64 php_stoi(uptr s) {
    i64 n = php_strlen(s);
    uptr v = s + ZS_HDR;
    i64 i = 0;
    loop { if (i >= n) break; i64 c = ld8(v + i); if (c != 32 && c != 9 && c != 10 && c != 13) break; i = i + 1; }
    i64 neg = 0;
    if (i < n) { if (ld8(v + i) == '-') { neg = 1; i = i + 1; } else { if (ld8(v + i) == '+') i = i + 1; } }
    i64 acc = 0;
    loop {
        if (i >= n) break;
        i64 c = ld8(v + i);
        if (c < '0' || c > '9') break;
        acc = acc * 10 + (c - '0');
        i = i + 1;
    }
    if (neg) return 0 - acc;
    return acc;
}

f64 php_stof(uptr s) {
    i64 n = php_strlen(s);
    uptr v = s + ZS_HDR;
    i64 i = 0;
    loop { if (i >= n) break; i64 c = ld8(v + i); if (c != 32 && c != 9 && c != 10 && c != 13) break; i = i + 1; }
    i64 neg = 0;
    if (i < n) { if (ld8(v + i) == '-') { neg = 1; i = i + 1; } else { if (ld8(v + i) == '+') i = i + 1; } }
    i64 mant = 0;
    i64 nd = 0;
    i64 e = 0;
    loop {
        if (i >= n) break;
        i64 c = ld8(v + i);
        if (c < '0' || c > '9') break;
        if (nd < 18) { mant = mant * 10 + (c - '0'); nd = nd + 1; } else { e = e + 1; }
        i = i + 1;
    }
    if (i < n) {
        if (ld8(v + i) == '.') {
            i = i + 1;
            loop {
                if (i >= n) break;
                i64 c2 = ld8(v + i);
                if (c2 < '0' || c2 > '9') break;
                if (nd < 18) { mant = mant * 10 + (c2 - '0'); nd = nd + 1; e = e - 1; }
                i = i + 1;
            }
        }
    }
    if (i < n) {
        i64 c3 = ld8(v + i);
        if (c3 == 'e' || c3 == 'E') {
            i64 j = i + 1;
            i64 es = 0;
            i64 ev = 0;
            i64 any = 0;
            if (j < n) { if (ld8(v + j) == '-') { es = 1; j = j + 1; } else { if (ld8(v + j) == '+') j = j + 1; } }
            loop {
                if (j >= n) break;
                i64 c4 = ld8(v + j);
                if (c4 < '0' || c4 > '9') break;
                ev = ev * 10 + (c4 - '0');
                any = 1;
                j = j + 1;
            }
            if (any) { if (es) e = e - ev; else e = e + ev; }
        }
    }
    f64 r = ph_scale(mant, e);
    if (neg) return 0.0 - r;
    return r;
}

// ---- echo ------------------------------------------------------------------
u8 ph_out[4096];
i64 ph_outn;

// The ONE place stdout is written. A program writes fd 1; an extension sets
// ph_osink to php's own php_output_write (lib/php_ext.mc), so what a module
// echoes goes through php's output layer and ob_start() sees it.
uptr ph_osink;
void php_out1(uptr b, i64 n) {
    if (ph_osink) { callp(ph_osink, b, n); return; }
    write(1, b, n);
}

void php_flush() { if (ph_outn) php_out1(ph_out, ph_outn); ph_outn = 0; }

// output capture: print_r($x, true), var_export($x, true) and php's own
// ob_* family, which NESTS -- so this is a stack and php_ob_start is a push.
// T8: it was one level, which made `ob_start(); print_r($x, true);` lose the
// outer buffer.
#define PH_MAXOB 16
uptr ph_obb[PH_MAXOB];
i64  ph_obn[PH_MAXOB];
i64  ph_obc[PH_MAXOB];
i64  ph_nob;

void php_ob_start() {
    if (ph_nob >= PH_MAXOB) return;
    st64(ph_obb + ph_nob * 8, 0);
    st64(ph_obn + ph_nob * 8, 0);
    st64(ph_obc + ph_nob * 8, 0);
    ph_nob = ph_nob + 1;
}

void php_ob_put(i64 lv, uptr b, i64 n) {
    i64 len = ld64(ph_obn + lv * 8);
    i64 cap = ld64(ph_obc + lv * 8);
    uptr buf = ld64(ph_obb + lv * 8);
    if (len + n > cap) {
        i64 nc = cap * 2 + n + 256;
        uptr nb = php_alloc(nc);
        php_memcpy(nb, buf, len);
        buf = nb;
        st64(ph_obb + lv * 8, nb);
        st64(ph_obc + lv * 8, nc);
    }
    php_memcpy(buf + len, b, n);
    st64(ph_obn + lv * 8, len + n);
}

void php_write(uptr b, i64 n) {
    if (ph_nob) { php_ob_put(ph_nob - 1, b, n); return; }
    if (n > 2048) { php_flush(); php_out1(b, n); return; }
    if (ph_outn + n > 4096) php_flush();
    php_memcpy(ph_out + ph_outn, b, n);
    ph_outn = ph_outn + n;
}

// pop the top buffer and answer what it caught
uptr php_ob_get() {
    if (!ph_nob) return php_str_new("", 0);
    ph_nob = ph_nob - 1;
    return php_str_new(ld64(ph_obb + ph_nob * 8), ld64(ph_obn + ph_nob * 8));
}

u8 php_f_ob_start(uptr a, uptr b, uptr c) { php_ob_start(); return 1; }

uptr php_f_ob_get_clean() {
    if (!ph_nob) return php_zbool(0);
    return php_zstr(php_ob_get());
}

uptr php_f_ob_get_contents() {
    if (!ph_nob) return php_zbool(0);
    return php_zstr(php_str_new(ld64(ph_obb + (ph_nob - 1) * 8), ld64(ph_obn + (ph_nob - 1) * 8)));
}

uptr php_f_ob_get_length() {
    if (!ph_nob) return php_zbool(0);
    return php_zlong(ld64(ph_obn + (ph_nob - 1) * 8));
}

i64 php_f_ob_get_level() { return ph_nob; }

u8 php_f_ob_end_clean() {
    if (!ph_nob) return 0;
    ph_nob = ph_nob - 1;
    return 1;
}

// the buffer goes to the level below it, or to the real output
u8 php_f_ob_end_flush() {
    if (!ph_nob) return 0;
    uptr b = ld64(ph_obb + (ph_nob - 1) * 8);
    i64 n = ld64(ph_obn + (ph_nob - 1) * 8);
    ph_nob = ph_nob - 1;
    if (n) php_write(b, n);
    return 1;
}

uptr php_f_ob_get_flush() {
    if (!ph_nob) return php_zbool(0);
    uptr s = php_str_new(ld64(ph_obb + (ph_nob - 1) * 8), ld64(ph_obn + (ph_nob - 1) * 8));
    php_f_ob_end_flush();
    return php_zstr(s);
}

u8 php_f_ob_flush() {
    if (!ph_nob) return 0;
    uptr b = ld64(ph_obb + (ph_nob - 1) * 8);
    i64 n = ld64(ph_obn + (ph_nob - 1) * 8);
    st64(ph_obn + (ph_nob - 1) * 8, 0);
    if (n) {
        if (ph_nob > 1) php_ob_put(ph_nob - 2, b, n);
        if (ph_nob < 2) { php_flush(); php_out1(b, n); }
    }
    return 1;
}

u8 php_f_flush() { php_flush(); return 1; }
u8 php_f_ob_implicit_flush(uptr a) { return 1; }

i64 php_echo_str(uptr s) { php_write(s + ZS_HDR, php_strlen(s)); return 0; }
i64 php_echo_int(i64 v) { php_echo_str(php_itos(v)); return 0; }
i64 php_echo_bool(u8 b) { if (b) php_write("1", 1); return 0; }
i64 php_echo_float(f64 x) { u8 t[64]; i64 n = php_fmt_f64(t, x, 14); php_write(t, n); return 0; }
i64 php_echo_null() { return 0; }

// ---- php's diagnostic channel ---------------------------------------------
// 21.8% of the corpus asserts a Warning:/Deprecated:/Notice:/Fatal error: line
// (T6's RESULTS.md section "Where a decision met reality" 5), so a compiled
// binary has to produce them, with the file and the line.
//
// The POSITION is two globals the compiler stores into once per statement
// (php.mc's ph_stmt wrapper): a call per warning site would mean threading a
// file and a line through all 173 library rows. The cost is one store of a
// literal per statement and the known inexactness is written down in
// RESULTS.md: a warning raised AFTER a user function returned, in the same
// statement, reports the line the callee last set.
//
// The cli sapi writes the text to stdout when display_errors is on, and the
// `PHP Warning:  ` form to stderr when log_errors is on with no error_log.
// The phpt runner sets log_errors=0, so only the stdout form is graded; the
// stderr form is what makes probes/t8/g/*.php agree with a default php.
uptr ph_dfile;
i64  ph_dline;
i64  ph_erep;                    // error_reporting(); E_ALL is 30719 on 8.5
i64  ph_disp;                    // display_errors
i64  ph_log;                     // log_errors
i64  ph_quiet;                   // the @ operator's depth, and ob-internal use

#define PHE_ERROR       1
#define PHE_WARNING     2
#define PHE_NOTICE      8
#define PHE_USER_ERROR  256
#define PHE_USER_WARN   512
#define PHE_USER_NOTICE 1024
#define PHE_DEPRECATED  8192
#define PHE_USER_DEPR   16384

i64 php_cstrlen(uptr s) {
    i64 n = 0;
    loop { if (!ld8(s + n)) break; n = n + 1; }
    return n;
}

// the label php prints for a level
uptr php_elabel(i64 lv) {
    if (lv == PHE_WARNING) return "Warning";
    if (lv == PHE_USER_WARN) return "Warning";
    if (lv == PHE_NOTICE) return "Notice";
    if (lv == PHE_USER_NOTICE) return "Notice";
    if (lv == PHE_DEPRECATED) return "Deprecated";
    if (lv == PHE_USER_DEPR) return "Deprecated";
    if (lv == PHE_USER_ERROR) return "Fatal error";
    return "Fatal error";
}

void php_ecs(uptr s) { write(2, s, php_cstrlen(s)); }

// msg is a NUL-terminated C string already assembled by the caller.
uptr php_call_zv(uptr z, i64 n, uptr a1, uptr a2, uptr a3, uptr a4, uptr a5);
uptr php_zstr(uptr s);
uptr php_zlong(i64 v);
uptr php_str_new(uptr b, i64 n);
i64  php_zv_type(uptr z);

// set_error_handler(): the callable, and the one the previous call replaced.
// A handler that returns anything but `false` suppresses php's own output,
// which is what most tests that install one are checking.
uptr ph_ehz;                                  // the current handler, 0 = none
uptr ph_ehprev;
i64  ph_ehmask;
i64  ph_ehin;                                 // 1 while it is running

void php_raise(i64 lv, uptr msg) {
    if (ph_quiet && lv != PHE_USER_ERROR) return;
    if (ph_ehz && !ph_ehin && (ph_ehmask & lv)) {
        uptr fn = ph_dfile;
        if (!fn) fn = "";
        ph_ehin = 1;
        uptr r = php_call_zv(ph_ehz, 4, php_zlong(lv),
                             php_zstr(php_str_new(msg, php_cstrlen(msg))),
                             php_zstr(php_str_new(fn, php_cstrlen(fn))),
                             php_zlong(ph_dline), 0);
        ph_ehin = 0;
        // IS_FALSE is 2, and its #define is below this point in the file
        if (php_zv_type(r) != 2) {
            if (lv == PHE_USER_ERROR) { php_flush(); exit(255); }
            return;
        }
    }
    if (!(ph_erep & lv)) return;
    uptr lb = php_elabel(lv);
    i64 ml = php_cstrlen(msg);
    uptr fn = ph_dfile;                       // a C string the compiler emitted
    uptr ln = php_itos(ph_dline);
    if (ph_log) {
        php_flush();
        php_ecs("PHP ");
        php_ecs(lb);
        php_ecs(":  ");
        write(2, msg, ml);
        php_ecs(" in ");
        if (fn) php_ecs(fn);
        php_ecs(" on line ");
        write(2, ln + ZS_HDR, php_strlen(ln));
        php_ecs("\n");
    }
    if (ph_disp) {
        php_write("\n", 1);
        php_write(lb, php_cstrlen(lb));
        php_write(": ", 2);
        php_write(msg, ml);
        php_write(" in ", 4);
        if (fn) php_write(fn, php_cstrlen(fn));
        php_write(" on line ", 9);
        php_write(ln + ZS_HDR, php_strlen(ln));
        php_write("\n", 1);
    }
    if (lv == PHE_USER_ERROR) { php_flush(); exit(255); }
}

// the message assembler: a fixed buffer, because a warning inside a loop must
// not eat the arena D7 never frees.
u8  ph_msg[1024];
i64 ph_msgn;

void php_mreset() { ph_msgn = 0; }

void php_mput(uptr b, i64 n) {
    i64 i = 0;
    loop {
        if (i >= n) break;
        if (ph_msgn >= 1023) break;
        st8(ph_msg + ph_msgn, ld8(b + i));
        ph_msgn = ph_msgn + 1;
        i = i + 1;
    }
    st8(ph_msg + ph_msgn, 0);
}

void php_mc(uptr s) { php_mput(s, php_cstrlen(s)); }
void php_ms(uptr s) { php_mput(s + ZS_HDR, php_strlen(s)); }
void php_mi(i64 v) { php_ms(php_itos(v)); }

void php_raise_m(i64 lv) { php_raise(lv, ph_msg); }

// the two shapes almost every call site wants
void php_warn1(uptr a) { php_mreset(); php_mc(a); php_raise_m(PHE_WARNING); }
void php_warn2(uptr a, uptr b) { php_mreset(); php_mc(a); php_mc(b); php_raise_m(PHE_WARNING); }
void php_depr1(uptr a) { php_mreset(); php_mc(a); php_raise_m(PHE_DEPRECATED); }

// the compiler's per-statement position store goes through these, so the
// generated code names two functions and not two globals.
void php_pos(uptr f, i64 l) { ph_dfile = f; ph_dline = l; }

// the @ operator: php suppresses the diagnostic and keeps the value
void php_quiet_on() { ph_quiet = ph_quiet + 1; }
void php_quiet_off() { if (ph_quiet) ph_quiet = ph_quiet - 1; }
void php_ln(i64 l) { ph_dline = l; }

// ---- the named diagnostics -------------------------------------------------
// Each one is php-src's own text, checked against php 8.5.10 on this host.
uptr php_znull();
uptr php_zundef();

uptr php_undef_var(uptr name) {
    php_mreset();
    php_mc("Undefined variable $");
    php_mc(name);
    php_raise_m(PHE_WARNING);
    return php_znull();
}

void php_undef_ikey(i64 k) {
    php_mreset();
    php_mc("Undefined array key ");
    php_mi(k);
    php_raise_m(PHE_WARNING);
}

uptr php_ftos(f64 x);

// php's "Implicit conversion from float %s to int loses precision": raised
// wherever a float reaches an int CONTEXT the program did not spell, an array
// offset above all. An explicit (int) cast is silent, and so is an integral
// float.
i64 php_dtoi_chk(f64 d) {
    i64 v = (i64) d;
    if ((f64) v != d) {
        php_mreset();
        php_mc("Implicit conversion from float ");
        php_ms(php_ftos(d));
        php_mc(" to int loses precision");
        php_raise_m(PHE_DEPRECATED);
    }
    return v;
}

void php_undef_skey(uptr k) {
    php_mreset();
    php_mc("Undefined array key \"");
    php_ms(k);
    php_mc("\"");
    php_raise_m(PHE_WARNING);
}

// forward declarations: these live further down the file and mc is one pass
i64 php_truthy_s(uptr s);
i64 php_cmp_i(i64 a, i64 b);
i64 php_cmp_f(f64 a, f64 b);
i64 php_mod(i64 a, i64 b);
i64 php_div_i(i64 a, i64 b);
f64 php_pow_f(f64 a, i64 e);
i64 php_pow_i(i64 a, i64 e);

// ---- zval: PHP's own 16-byte shape ----------------------------------------
// 0 value (i64 | f64 bits | uptr) | 8 u1.type u8, u1.type_flags u8 | 12 u2 u32
// The u2 word is the hash collision link when the zval lives inside a Bucket,
// which is why a value copy is ld64 + ld32 and never a 16-byte memcpy.
#define ZV_SIZE   16
#define IS_UNDEF   0
#define IS_NULL    1
#define IS_FALSE   2
#define IS_TRUE    3
#define IS_LONG    4
#define IS_DOUBLE  5
#define IS_STRING  6
#define IS_ARRAY   7
#define IS_OBJECT  8
#define IS_RESOURCE 9

uptr php_zv_str(uptr z);
i64  php_zv_bool(uptr z);
i64  php_zv_long(uptr z);
f64  php_zv_double(uptr z);
i64  php_zv_cmp(uptr a, uptr b);
void php_vd_zv(uptr z, i64 depth);
uptr php_obj_tostr(uptr o);
uptr php_obj_cname(uptr o);
uptr php_obj_props(uptr o);
uptr php_obj_romarks(uptr o);
i64  php_obj_id(uptr o);
void php_pr_zv(uptr z, i64 depth);
void php_ex_zv(uptr z, i64 depth);
i64  php_zv_identical(uptr a, uptr b);
uptr php_arr_copy(uptr src);
i64  php_throw_str(uptr cls, uptr msg);

i64  php_zv_type(uptr z) { return ld8(z + 8); }
void php_zv_settype(uptr z, i64 t) { st8(z + 8, t); st8(z + 9, 0); }

uptr php_zv_alloc() {
    uptr z = php_alloc(ZV_SIZE);
    st64(z, 0);
    st64(z + 8, 0);
    return z;
}

// a value copy that leaves the destination's collision link alone
void php_zv_cp(uptr d, uptr s) { st64(d, ld64(s)); st32(d + 8, ld32(s + 8)); }

uptr php_zv_dup(uptr s) { uptr z = php_zv_alloc(); php_zv_cp(z, s); return z; }

uptr php_znull() { uptr z = php_zv_alloc(); php_zv_settype(z, IS_NULL); return z; }
// "this argument was not passed", which a null that WAS passed is not
uptr php_zundef() { uptr z = php_zv_alloc(); php_zv_settype(z, IS_UNDEF); return z; }
uptr php_zlong(i64 v) { uptr z = php_zv_alloc(); st64(z, v); php_zv_settype(z, IS_LONG); return z; }
uptr php_zbool(u8 b) { uptr z = php_zv_alloc(); if (b) php_zv_settype(z, IS_TRUE); if (!b) php_zv_settype(z, IS_FALSE); return z; }
uptr php_zdouble(f64 x) { uptr z = php_zv_alloc(); stf64(z, x); php_zv_settype(z, IS_DOUBLE); return z; }
uptr php_zstr(uptr s) { uptr z = php_zv_alloc(); st64(z, s); php_zv_settype(z, IS_STRING); return z; }
uptr php_zarr(uptr a) { uptr z = php_zv_alloc(); st64(z, a); php_zv_settype(z, IS_ARRAY); return z; }
uptr php_zobj(uptr o) { uptr z = php_zv_alloc(); st64(z, o); php_zv_settype(z, IS_OBJECT); return z; }

// ---- the ordered hash: PHP's zend_array, field for field -------------------
//  0 gc      refcount u32, type_info u32
//  8 flags   u32
// 12 nTableMask i32  (informational -- the slot index is computed, see below)
// 16 arData  uptr    -- the Buckets; the u32 hash slots sit BEFORE it
// 24 nNumUsed u32    -- buckets ever used, including the deleted ones
// 28 nNumOfElements u32
// 32 nTableSize u32  -- a power of two
// 36 nInternalPointer u32
// 40 nNextFreeElement i64
// 48 pDestructor uptr
// A Bucket is 32 bytes: zval val (16) | zend_ulong h (8) | zend_string *key (8),
// and the zval's u2 word at +12 is the collision link, exactly as in php-src.
//
// Deviation on record: php derives the slot index from nTableMask with a
// negative index; this computes it from nTableSize. The FIELD layout is php's
// (which is what D2(b)'s shim reads); the indexing arithmetic is not.
#define HT_HDR    56
#define BKT       32
#define HT_INVAL  4294967295

i64  php_count(uptr a) { return ld32(a + 28); }
i64  php_ht_used(uptr a) { return ld32(a + 24); }
uptr php_ht_bkt(uptr a, i64 i) { return ld64(a + 16) + i * BKT; }
i64  php_ht_slot(uptr a, u64 h) { i64 n = ld32(a + 32); return (h & (n - 1)) - n; }
i64  php_ht_hget(uptr a, i64 si) { return ld32(ld64(a + 16) + si * 4); }
void php_ht_hset(uptr a, i64 si, i64 v) { st32(ld64(a + 16) + si * 4, v); }

void php_ht_slots_clear(uptr a) {
    i64 n = ld32(a + 32);
    i64 i = 1;
    loop { if (i > n) break; php_ht_hset(a, 0 - i, HT_INVAL); i = i + 1; }
}

uptr php_arr_new(i64 want) {
    i64 n = 8;
    loop { if (n >= want) break; n = n * 2; }
    uptr a = php_alloc(HT_HDR);
    uptr blk = php_alloc(n * 4 + n * BKT);
    st32(a, 1);
    st32(a + 4, IS_ARRAY);
    st32(a + 8, 0);
    st32(a + 12, 0 - n);
    st64(a + 16, blk + n * 4);
    st32(a + 24, 0);
    st32(a + 28, 0);
    st32(a + 32, n);
    st32(a + 36, 0);
    st64(a + 40, 0);
    st64(a + 48, 0);
    php_ht_slots_clear(a);
    return a;
}

// php's DJBX33A with the top bit set, so a hash of 0 means "not computed"
u64 php_str_hash(uptr s) {
    u64 h = ld64(s + 8);
    if (h) return h;
    h = 5381;
    i64 n = php_strlen(s);
    i64 i = 0;
    loop {
        if (i >= n) break;
        h = (h << 5) + h + ld8(s + ZS_HDR + i);
        i = i + 1;
    }
    h = h | 0x8000000000000000;
    st64(s + 8, h);
    return h;
}

// php's ZEND_HANDLE_NUMERIC: "123" is the integer key 123, but "0123", "1.0",
// " 1" and "+1" are not, and neither is anything past the i64 range.
i64 php_key_numeric(uptr s, uptr pout) {
    i64 n = php_strlen(s);
    if (n == 0 || n > 20) return 0;
    uptr v = s + ZS_HDR;
    i64 i = 0;
    i64 neg = 0;
    if (ld8(v) == '-') { neg = 1; i = 1; if (n == 1) return 0; }
    if (ld8(v + i) == '0' && n - i > 1) return 0;
    u64 acc = 0;
    loop {
        if (i >= n) break;
        i64 c = ld8(v + i);
        if (c < '0' || c > '9') return 0;
        acc = acc * 10 + (c - '0');
        i = i + 1;
    }
    if (!neg && acc > 9223372036854775807) return 0;
    if (neg && acc > 9223372036854775808) return 0;
    i64 r = acc;
    if (neg) r = 0 - acc;
    st64(pout, r);
    return 1;
}

void php_ht_grow(uptr a) {
    i64 old = ld32(a + 32);
    i64 n = old * 2;
    uptr blk = php_alloc(n * 4 + n * BKT);
    uptr nd = blk + n * 4;
    uptr od = ld64(a + 16);
    i64 used = ld32(a + 24);
    i64 w = 0;
    i64 i = 0;
    loop {
        if (i >= used) break;
        uptr b = od + i * BKT;
        if (ld8(b + 8) != IS_UNDEF) {
            uptr t = nd + w * BKT;
            st64(t, ld64(b));
            st32(t + 8, ld32(b + 8));
            st64(t + 16, ld64(b + 16));
            st64(t + 24, ld64(b + 24));
            w = w + 1;
        }
        i = i + 1;
    }
    st32(a + 12, 0 - n);
    st64(a + 16, nd);
    st32(a + 24, w);
    st32(a + 32, n);
    php_ht_slots_clear(a);
    i = 0;
    loop {
        if (i >= w) break;
        uptr b2 = nd + i * BKT;
        i64 si = php_ht_slot(a, ld64(b2 + 16));
        st32(b2 + 12, php_ht_hget(a, si));
        php_ht_hset(a, si, i);
        i = i + 1;
    }
}

uptr php_ht_find(uptr a, u64 h, uptr key) {
    i64 idx = php_ht_hget(a, php_ht_slot(a, h));
    loop {
        if (idx == HT_INVAL) break;
        uptr b = php_ht_bkt(a, idx);
        if (ld64(b + 16) == h && ld8(b + 8) != IS_UNDEF) {
            uptr k = ld64(b + 24);
            if (!key && !k) return b;
            if (key && k && php_str_eq(k, key)) return b;
        }
        idx = ld32(b + 12);
    }
    return 0;
}

// the bucket for (h, key), created empty (IS_NULL) when it was not there
uptr php_ht_slotfor(uptr a, u64 h, uptr key) {
    uptr b = php_ht_find(a, h, key);
    if (b) return b;
    if (ld32(a + 24) >= ld32(a + 32)) php_ht_grow(a);
    i64 i = ld32(a + 24);
    b = php_ht_bkt(a, i);
    st64(b, 0);
    php_zv_settype(b, IS_NULL);
    st64(b + 16, h);
    st64(b + 24, key);
    i64 si = php_ht_slot(a, h);
    st32(b + 12, php_ht_hget(a, si));
    php_ht_hset(a, si, i);
    st32(a + 24, i + 1);
    st32(a + 28, ld32(a + 28) + 1);
    return b;
}

void php_ht_bump_next(uptr a, i64 k) {
    if (k >= ld64(a + 40)) {
        i64 nx = k + 1;
        if (nx < k) nx = k;                     // php leaves it at INT_MAX
        st64(a + 40, nx);
    }
}

uptr php_arr_islot(uptr a, i64 k) {
    uptr b = php_ht_slotfor(a, k, 0);
    php_ht_bump_next(a, k);
    return b;
}

uptr php_arr_sslot(uptr a, uptr key) {
    u8 nb[8];
    if (php_key_numeric(key, nb)) return php_arr_islot(a, ld64(nb));
    return php_ht_slotfor(a, php_str_hash(key), key);
}

uptr php_arr_nextslot(uptr a) { return php_arr_islot(a, ld64(a + 40)); }

// the reads: a missing key is php's "Warning: Undefined array key" + null, and
// this returns a fresh IS_NULL zval for it (the warning is php_notice's job).
uptr php_arr_iget(uptr a, i64 k) {
    uptr b = php_ht_find(a, k, 0);
    if (b) return b;
    return php_znull();
}

uptr php_arr_sget(uptr a, uptr key) {
    u8 nb[8];
    if (php_key_numeric(key, nb)) return php_arr_iget(a, ld64(nb));
    uptr b = php_ht_find(a, php_str_hash(key), key);
    if (b) return b;
    return php_znull();
}

uptr php_arr_zget(uptr a, uptr k) {
    i64 t = php_zv_type(k);
    if (t == IS_STRING) return php_arr_sget(a, ld64(k));
    if (t == IS_DOUBLE) return php_arr_iget(a, php_dtoi_chk(ldf64(k)));
    if (t == IS_NULL)   return php_arr_sget(a, php_str_new("", 0));
    return php_arr_iget(a, php_zv_long(k));
}

// The same read, but php's: a key that is not there is
// `Warning: Undefined array key ...` and null. The quiet form above is what
// isset/empty/?? and the runtime's own internal reads use -- php does not
// warn for any of those either.
uptr php_arr_zget_w(uptr a, uptr k) {
    i64 t = php_zv_type(k);
    uptr b = 0;
    if (t == IS_STRING) {
        u8 nb[8];
        uptr s = ld64(k);
        if (php_key_numeric(s, nb)) {
            b = php_ht_find(a, ld64(nb), 0);
            if (!b) { php_undef_ikey(ld64(nb)); return php_znull(); }
            return b;
        }
        b = php_ht_find(a, php_str_hash(s), s);
        if (!b) { php_undef_skey(s); return php_znull(); }
        return b;
    }
    i64 ik = php_zv_long(k);
    if (t == IS_DOUBLE) ik = php_dtoi_chk(ldf64(k));
    if (t == IS_NULL) {
        php_depr1("Using null as an array offset is deprecated, use an empty string instead");
        uptr e = php_str_new("", 0);
        b = php_ht_find(a, php_str_hash(e), e);
        if (!b) { php_undef_skey(e); return php_znull(); }
        return b;
    }
    b = php_ht_find(a, ik, 0);
    if (!b) { php_undef_ikey(ik); return php_znull(); }
    return b;
}

uptr php_arr_zslot(uptr a, uptr k) {
    i64 t = php_zv_type(k);
    if (t == IS_STRING) return php_arr_sslot(a, ld64(k));
    if (t == IS_DOUBLE) return php_arr_islot(a, php_dtoi_chk(ldf64(k)));
    if (t == IS_NULL) {
        php_depr1("Using null as an array offset is deprecated, use an empty string instead");
        return php_arr_sslot(a, php_str_new("", 0));
    }
    return php_arr_islot(a, php_zv_long(k));
}

i64 php_arr_has(uptr a, uptr k) {
    i64 t = php_zv_type(k);
    uptr b = 0;
    if (t == IS_STRING) {
        uptr key = ld64(k);
        u8 nb[8];
        if (php_key_numeric(key, nb)) b = php_ht_find(a, ld64(nb), 0);
        if (!b) b = php_ht_find(a, php_str_hash(key), key);
    }
    if (t != IS_STRING) b = php_ht_find(a, php_zv_long(k), 0);
    if (!b) return 0;
    return 1;
}

void php_arr_unset(uptr a, uptr k) {
    i64 t = php_zv_type(k);
    uptr b = 0;
    if (t == IS_STRING) {
        uptr key = ld64(k);
        u8 nb[8];
        if (php_key_numeric(key, nb)) b = php_ht_find(a, ld64(nb), 0);
        if (!b) b = php_ht_find(a, php_str_hash(key), key);
    }
    if (t != IS_STRING) b = php_ht_find(a, php_zv_long(k), 0);
    if (!b) return;
    php_zv_settype(b, IS_UNDEF);
    st32(a + 28, ld32(a + 28) - 1);
}

// append: $a[] = v
// A php array is a VALUE, so appending one to another array must copy it:
// php_zv_cp copies the 16-byte header and left the two sharing the same
// hash table, which is what made `array_values($a)[0][] = 9` reach into $a
// (docs/review-backlog.md section 2; array_merge, array_slice, array_filter
// and every other row that carries elements out of an array had it too).
// php_zv_cpv is the copy an assignment makes, and it costs nothing at all
// for a value that is not an array.
void php_arr_push(uptr a, uptr v) { php_zv_cpv(php_arr_nextslot(a), v); }
void php_arr_set(uptr a, uptr k, uptr v) { php_zv_cp(php_arr_zslot(a, k), v); }
void php_arr_iset(uptr a, i64 k, uptr v) { php_zv_cp(php_arr_islot(a, k), v); }

// php arrays are VALUES: an assignment makes an independent array. There is no
// free (D7), so the separation is eager when the refcount says it is shared.
uptr php_arr_copy(uptr src) {
    uptr a = php_arr_new(ld32(src + 32));
    i64 used = php_ht_used(src);
    i64 i = 0;
    loop {
        if (i >= used) break;
        uptr b = php_ht_bkt(src, i);
        if (ld8(b + 8) != IS_UNDEF) {
            uptr k = ld64(b + 24);
            uptr t = 0;
            if (k) t = php_ht_slotfor(a, php_str_hash(k), k);
            if (!k) t = php_arr_islot(a, ld64(b + 16));
            php_zv_cp(t, b);
            if (php_zv_type(b) == IS_ARRAY) st64(t, php_arr_copy(ld64(b)));
        }
        i = i + 1;
    }
    st64(a + 40, ld64(src + 40));
    return a;
}

// ---- the zval conversions, php's own rules ---------------------------------
i64 php_zv_bool(uptr z) {
    i64 t = php_zv_type(z);
    if (t == IS_TRUE) return 1;
    if (t == IS_LONG) { if (ld64(z)) return 1; return 0; }
    if (t == IS_DOUBLE) { if (ldf64(z) != 0.0) return 1; return 0; }
    if (t == IS_STRING) return php_truthy_s(ld64(z));
    if (t == IS_ARRAY) { if (php_count(ld64(z))) return 1; return 0; }
    if (t == IS_OBJECT) return 1;
    if (t == IS_RESOURCE) return 1;
    return 0;
}

i64 php_zv_long(uptr z) {
    i64 t = php_zv_type(z);
    if (t == IS_LONG) return ld64(z);
    if (t == IS_TRUE) return 1;
    if (t == IS_DOUBLE) return (i64) ldf64(z);
    if (t == IS_STRING) return php_stoi(ld64(z));
    if (t == IS_ARRAY) { if (php_count(ld64(z))) return 1; return 0; }
    return 0;
}

f64 php_zv_double(uptr z) {
    i64 t = php_zv_type(z);
    if (t == IS_DOUBLE) return ldf64(z);
    if (t == IS_STRING) return php_stof(ld64(z));
    return (f64) php_zv_long(z);
}

uptr php_zv_str(uptr z) {
    i64 t = php_zv_type(z);
    if (t == IS_STRING) return ld64(z);
    if (t == IS_LONG)   return php_itos(ld64(z));
    if (t == IS_DOUBLE) return php_ftos(ldf64(z));
    if (t == IS_TRUE)   return php_str_new("1", 1);
    if (t == IS_ARRAY)  { php_warn1("Array to string conversion"); return php_str_new("Array", 5); }
    if (t == IS_OBJECT) return php_obj_tostr(ld64(z));
    return php_str_new("", 0);
}

// is this string a php NUMERIC string (the whole of it, leading space allowed)?
// 0 no, 1 integer (through pl), 2 float (through pd)
i64 php_str_isnum(uptr s, uptr pl, uptr pd) {
    i64 n = php_strlen(s);
    uptr v = s + ZS_HDR;
    i64 i = 0;
    loop { if (i >= n) break; i64 c = ld8(v + i); if (c != 32 && c != 9 && c != 10 && c != 13 && c != 11 && c != 12) break; i = i + 1; }
    i64 st = i;
    if (i < n && (ld8(v + i) == '-' || ld8(v + i) == '+')) i = i + 1;
    i64 nd = 0;
    loop { if (i >= n) break; i64 c = ld8(v + i); if (c < '0' || c > '9') break; nd = nd + 1; i = i + 1; }
    i64 isf = 0;
    if (i < n && ld8(v + i) == '.') {
        isf = 1;
        i = i + 1;
        loop { if (i >= n) break; i64 c = ld8(v + i); if (c < '0' || c > '9') break; nd = nd + 1; i = i + 1; }
    }
    if (!nd) return 0;
    if (i < n && (ld8(v + i) == 'e' || ld8(v + i) == 'E')) {
        i64 j = i + 1;
        if (j < n && (ld8(v + j) == '-' || ld8(v + j) == '+')) j = j + 1;
        i64 ne = 0;
        loop { if (j >= n) break; i64 c = ld8(v + j); if (c < '0' || c > '9') break; ne = ne + 1; j = j + 1; }
        if (ne) { isf = 1; i = j; }
    }
    loop { if (i >= n) break; i64 c = ld8(v + i); if (c != 32 && c != 9 && c != 10 && c != 13 && c != 11 && c != 12) break; i = i + 1; }
    if (i != n) return 0;
    if (isf) { stf64(pd, php_stof(s)); return 2; }
    // an integer that overflows i64 is a float in php
    i64 digits = 0;
    i64 k = st;
    if (k < n && (ld8(v + k) == '-' || ld8(v + k) == '+')) k = k + 1;
    loop { if (k >= n) break; i64 c = ld8(v + k); if (c < '0' || c > '9') break; digits = digits + 1; k = k + 1; }
    if (digits > 19) { stf64(pd, php_stof(s)); return 2; }
    st64(pl, php_stoi(s));
    return 1;
}

// ---- the zval arithmetic ---------------------------------------------------
// php 8: a numeric string is a number, a non-numeric string in an arithmetic
// context is a TypeError. T6 follows the numeric-string half and treats the
// rest as 0, which is php 7's rule -- named in RESULTS.md, not hidden.
i64 php_zv_isdouble(uptr z) {
    i64 t = php_zv_type(z);
    if (t == IS_DOUBLE) return 1;
    if (t == IS_STRING) {
        u8 lb[8];
        u8 db[8];
        if (php_str_isnum(ld64(z), lb, db) == 2) return 1;
    }
    return 0;
}

// php 8 refuses arithmetic on a value that is not a number and not a numeric
// string: "abc" + 1 is a TypeError, not 1. A LEADING-numeric string ("5x") is
// a warning and the number, which this takes without the warning.
uptr php_f_get_debug_type(uptr z);

i64 php_num_ok(uptr z) {
    i64 t = php_zv_type(z);
    if (t == IS_LONG || t == IS_DOUBLE || t == IS_NULL || t == IS_TRUE || t == IS_FALSE) return 1;
    if (t == IS_STRING) {
        u8 lb[8];
        u8 db[8];
        if (php_str_isnum(ld64(z), lb, db)) return 1;
        uptr v = ld64(z);
        i64 n = php_strlen(v);
        i64 i = 0;
        loop { if (i >= n) break; i64 c = ld8(v + ZS_HDR + i); if (c != 32 && c != 9 && c != 10 && c != 13) break; i = i + 1; }
        if (i < n && (ld8(v + ZS_HDR + i) == 45 || ld8(v + ZS_HDR + i) == 43)) i = i + 1;
        if (i < n && ld8(v + ZS_HDR + i) >= 48 && ld8(v + ZS_HDR + i) <= 57) return 2;
        return 0;
    }
    return 0;
}

void php_arith_die(uptr a, uptr b, uptr op) {
    uptr m = php_str_concat(php_str_new("Unsupported operand types: ", 27), php_f_get_debug_type(a));
    m = php_str_concat(m, php_str_new(" ", 1));
    m = php_str_concat(m, op);
    m = php_str_concat(m, php_str_new(" ", 1));
    m = php_str_concat(m, php_f_get_debug_type(b));
    php_throw_cls(php_str_new("TypeError", 9), m);
}

i64 php_arith_ok(uptr a, uptr b, uptr op) {
    i64 ka = php_num_ok(a);
    i64 kb = php_num_ok(b);
    // a LEADING-numeric string ("5 apples") is php's
    // "Warning: A non-numeric value encountered" and the number it starts with
    if (ka == 2 || kb == 2) php_warn1("A non-numeric value encountered");
    if (ka && kb) return 1;
    if (php_zv_type(a) == IS_STRING && php_num_ok(a) == 0) {
        uptr m = php_str_concat(php_str_new("Unsupported operand types: string ", 34), op);
        m = php_str_concat(m, php_str_new(" ", 1));
        m = php_str_concat(m, php_f_get_debug_type(b));
        php_throw_cls(php_str_new("TypeError", 9), m);
        return 0;
    }
    php_arith_die(a, b, op);
    return 0;
}

uptr php_zv_add(uptr a, uptr b) {
    if (php_zv_type(a) == IS_ARRAY && php_zv_type(b) == IS_ARRAY) {
        uptr r = php_arr_copy(ld64(a));
        uptr s = ld64(b);
        i64 used = php_ht_used(s);
        i64 i = 0;
        loop {
            if (i >= used) break;
            uptr bk = php_ht_bkt(s, i);
            if (ld8(bk + 8) != IS_UNDEF) {
                uptr k = ld64(bk + 24);
                uptr ex = 0;
                if (k) ex = php_ht_find(r, php_str_hash(k), k);
                if (!k) ex = php_ht_find(r, ld64(bk + 16), 0);
                if (!ex) {
                    uptr t = 0;
                    if (k) t = php_ht_slotfor(r, php_str_hash(k), k);
                    if (!k) t = php_arr_islot(r, ld64(bk + 16));
                    php_zv_cp(t, bk);
                }
            }
            i = i + 1;
        }
        return php_zarr(r);
    }
    if (!php_arith_ok(a, b, php_str_new("+", 1))) return php_znull();
    if (php_zv_isdouble(a) || php_zv_isdouble(b)) return php_zdouble(php_zv_double(a) + php_zv_double(b));
    i64 x = php_zv_long(a);
    i64 y = php_zv_long(b);
    i64 r2 = x + y;
    // php promotes an overflowing int to float
    if (((x ^ r2) & (y ^ r2)) < 0) return php_zdouble(php_zv_double(a) + php_zv_double(b));
    return php_zlong(r2);
}

uptr php_zv_sub(uptr a, uptr b) {
    if (!php_arith_ok(a, b, php_str_new("-", 1))) return php_znull();
    if (php_zv_isdouble(a) || php_zv_isdouble(b)) return php_zdouble(php_zv_double(a) - php_zv_double(b));
    i64 x = php_zv_long(a);
    i64 y = php_zv_long(b);
    i64 r = x - y;
    if (((x ^ y) & (x ^ r)) < 0) return php_zdouble(php_zv_double(a) - php_zv_double(b));
    return php_zlong(r);
}

uptr php_zv_mul(uptr a, uptr b) {
    if (!php_arith_ok(a, b, php_str_new("*", 1))) return php_znull();
    if (php_zv_isdouble(a) || php_zv_isdouble(b)) return php_zdouble(php_zv_double(a) * php_zv_double(b));
    i64 x = php_zv_long(a);
    i64 y = php_zv_long(b);
    i64 r = x * y;
    if (x != 0) { if (r / x != y) return php_zdouble(php_zv_double(a) * php_zv_double(b)); }
    return php_zlong(r);
}

uptr php_zv_div(uptr a, uptr b) {
    if (!php_arith_ok(a, b, php_str_new("/", 1))) return php_znull();
    if (php_zv_isdouble(a) || php_zv_isdouble(b)) {
        f64 d = php_zv_double(b);
        if (d == 0.0) { php_throw_str(php_str_new("DivisionByZeroError", 19), php_str_new("Division by zero", 16)); return php_znull(); }
        return php_zdouble(php_zv_double(a) / d);
    }
    i64 y = php_zv_long(b);
    if (y == 0) { php_throw_str(php_str_new("DivisionByZeroError", 19), php_str_new("Division by zero", 16)); return php_znull(); }
    i64 x = php_zv_long(a);
    // PHP_INT_MIN / -1 is exact in arithmetic and not representable as an
    // i64, so php answers the float; the `x % y` below is itself the #DE on
    // x86-64 and has to be jumped over, not just its result corrected.
    if (x == -9223372036854775807 - 1 && y == -1) return php_zdouble(9223372036854775808.0);
    if (x % y == 0) return php_zlong(php_div_i(x, y));
    return php_zdouble((f64) x / (f64) y);
}

uptr php_zv_mod(uptr a, uptr b) {
    i64 y = php_zv_ilong(b);
    if (y == 0) { php_throw_str(php_str_new("DivisionByZeroError", 19), php_str_new("Modulo by zero", 14)); return php_znull(); }
    return php_zlong(php_mod(php_zv_ilong(a), y));
}

uptr php_zv_pow(uptr a, uptr b) {
    if (!php_arith_ok(a, b, php_str_new("**", 2))) return php_znull();
    if (php_zv_isdouble(a) || php_zv_isdouble(b) || php_zv_long(b) < 0)
        return php_zdouble(php_pow_f(php_zv_double(a), php_zv_long(b)));
    return php_zlong(php_pow_i(php_zv_long(a), php_zv_long(b)));
}

uptr php_zv_neg(uptr a) {
    if (!php_arith_ok(a, php_zlong(0), php_str_new("*", 1))) return php_znull();
    if (php_zv_isdouble(a)) return php_zdouble(0.0 - php_zv_double(a));
    i64 v = php_zv_long(a);
    if (v == -9223372036854775807 - 1) return php_zdouble(9223372036854775808.0);
    return php_zlong(0 - v);
}

uptr php_zv_concat(uptr a, uptr b) { return php_zstr(php_str_concat(php_zv_str(a), php_zv_str(b))); }

// an INT context the program did not spell: php deprecates a float and a
// float-string that lose precision there. An explicit (int) cast does not go
// through this, which is why it is a second function and not php_zv_long.
i64 php_zv_ilong(uptr z) {
    i64 t = php_zv_type(z);
    if (t == IS_DOUBLE) return php_dtoi_chk(ldf64(z));
    if (t == IS_STRING) {
        u8 lb[8];
        u8 db[8];
        if (php_str_isnum(ld64(z), lb, db) == 2) {
            f64 d = ldf64(db);
            i64 v = (i64) d;
            if ((f64) v != d) {
                php_mreset();
                php_mc("Implicit conversion from float-string \"");
                php_ms(ld64(z));
                php_mc("\" to int loses precision");
                php_raise_m(PHE_DEPRECATED);
            }
            return v;
        }
    }
    return php_zv_long(z);
}

// php: & | ^ between TWO strings are BYTEWISE, not numeric. & and ^ answer
// min(len) bytes, | answers max(len) with the longer operand's tail kept.
// One string and one number is the numeric road, as php has it.
uptr php_str_bitop(uptr a, uptr b, i64 op) {
    i64 la = php_strlen(a);
    i64 lb = php_strlen(b);
    i64 n = la;
    if (lb < n) n = lb;
    i64 out = n;
    if (op == 1) { out = la; if (lb > out) out = lb; }
    uptr s = php_str_alloc(out);
    i64 i = 0;
    loop {
        if (i >= n) break;
        i64 x = ld8(a + ZS_HDR + i);
        i64 y = ld8(b + ZS_HDR + i);
        i64 r = x & y;
        if (op == 1) r = x | y;
        if (op == 2) r = x ^ y;
        st8(s + ZS_HDR + i, r);
        i = i + 1;
    }
    loop {
        if (i >= out) break;
        i64 c = 0;
        if (i < la) c = ld8(a + ZS_HDR + i);
        if (i < lb) c = ld8(b + ZS_HDR + i);
        st8(s + ZS_HDR + i, c);
        i = i + 1;
    }
    return s;
}

i64 php_both_str(uptr a, uptr b) {
    if (php_zv_type(a) != IS_STRING) return 0;
    if (php_zv_type(b) != IS_STRING) return 0;
    return 1;
}

uptr php_zv_band(uptr a, uptr b) {
    if (php_both_str(a, b)) return php_zstr(php_str_bitop(ld64(a), ld64(b), 0));
    return php_zlong(php_zv_ilong(a) & php_zv_ilong(b));
}
uptr php_zv_bor(uptr a, uptr b) {
    if (php_both_str(a, b)) return php_zstr(php_str_bitop(ld64(a), ld64(b), 1));
    return php_zlong(php_zv_ilong(a) | php_zv_ilong(b));
}
uptr php_zv_bxor(uptr a, uptr b) {
    if (php_both_str(a, b)) return php_zstr(php_str_bitop(ld64(a), ld64(b), 2));
    return php_zlong(php_zv_ilong(a) ^ php_zv_ilong(b));
}
// php: a negative shift is an ArithmeticError, and a shift of 64 or more is
// 0 (or -1 for a right shift of a negative value), never the hardware's
// modulo-64 answer.
i64 php_shift_ok(i64 s) {
    if (s < 0) {
        php_throw_str(php_str_new("ArithmeticError", 15),
                      php_str_new("Bit shift by negative number", 28));
        return 0;
    }
    return 1;
}

uptr php_zv_shl(uptr a, uptr b) {
    if (!php_arith_ok(a, b, php_str_new("<<", 2))) return php_znull();
    i64 x = php_zv_ilong(a);
    i64 s = php_zv_ilong(b);
    if (!php_shift_ok(s)) return php_znull();
    if (s >= 64) return php_zlong(0);
    return php_zlong(x << s);
}

uptr php_zv_shr(uptr a, uptr b) {
    if (!php_arith_ok(a, b, php_str_new(">>", 2))) return php_znull();
    i64 x = php_zv_ilong(a);
    i64 s = php_zv_ilong(b);
    if (!php_shift_ok(s)) return php_znull();
    if (s >= 64) { if (x < 0) return php_zlong(-1); return php_zlong(0); }
    return php_zlong(x >> s);
}

i64 php_shl_i(i64 x, i64 s) {
    if (!php_shift_ok(s)) return 0;
    if (s >= 64) return 0;
    return x << s;
}

i64 php_shr_i(i64 x, i64 s) {
    if (!php_shift_ok(s)) return 0;
    if (s >= 64) { if (x < 0) return -1; return 0; }
    return x >> s;
}
uptr php_zv_bnot(uptr a) {
    if (php_zv_type(a) == IS_STRING) {
        uptr s = ld64(a);
        i64 n = php_strlen(s);
        uptr o = php_str_alloc(n);
        i64 i = 0;
        loop { if (i >= n) break; st8(o + ZS_HDR + i, 255 - ld8(s + ZS_HDR + i)); i = i + 1; }
        return php_zstr(o);
    }
    return php_zlong(0 - php_zv_long(a) - 1);
}

// php 8's loose comparison
i64 php_zv_cmp(uptr a, uptr b) {
    i64 ta = php_zv_type(a);
    i64 tb = php_zv_type(b);
    if (ta == IS_ARRAY && tb == IS_ARRAY) {
        i64 na = php_count(ld64(a));
        i64 nb = php_count(ld64(b));
        if (na < nb) return -1;
        if (na > nb) return 1;
        uptr x = ld64(a);
        uptr y = ld64(b);
        i64 used = php_ht_used(x);
        i64 i = 0;
        loop {
            if (i >= used) break;
            uptr bk = php_ht_bkt(x, i);
            if (ld8(bk + 8) != IS_UNDEF) {
                uptr k = ld64(bk + 24);
                uptr o = 0;
                if (k) o = php_ht_find(y, php_str_hash(k), k);
                if (!k) o = php_ht_find(y, ld64(bk + 16), 0);
                if (!o) return 1;
                i64 c = php_zv_cmp(bk, o);
                if (c) return c;
            }
            i = i + 1;
        }
        return 0;
    }
    if (ta == IS_NULL && tb == IS_STRING) return php_str_cmp(php_str_new("", 0), ld64(b));
    if (tb == IS_NULL && ta == IS_STRING) return php_str_cmp(ld64(a), php_str_new("", 0));
    if (ta == IS_NULL || tb == IS_NULL || ta == IS_TRUE || ta == IS_FALSE || tb == IS_TRUE || tb == IS_FALSE)
        return php_cmp_i(php_zv_bool(a), php_zv_bool(b));
    if (ta == IS_STRING && tb == IS_STRING) {
        u8 la[8];
        u8 da[8];
        u8 lb[8];
        u8 db[8];
        i64 ka = php_str_isnum(ld64(a), la, da);
        i64 kb = php_str_isnum(ld64(b), lb, db);
        if (ka && kb) {
            if (ka == 1 && kb == 1) return php_cmp_i(ld64(la), ld64(lb));
            f64 fa = ldf64(da);
            f64 fb = ldf64(db);
            if (ka == 1) fa = (f64) ld64(la);
            if (kb == 1) fb = (f64) ld64(lb);
            return php_cmp_f(fa, fb);
        }
        return php_cmp_i(php_str_cmp(ld64(a), ld64(b)), 0);
    }
    // php 8: a number compared with a NON-numeric string compares as strings
    if (ta == IS_STRING || tb == IS_STRING) {
        uptr s = a;
        if (tb == IS_STRING) s = b;
        u8 ls[8];
        u8 ds[8];
        if (!php_str_isnum(ld64(s), ls, ds))
            return php_cmp_i(php_str_cmp(php_zv_str(a), php_zv_str(b)), 0);
    }
    if (php_zv_isdouble(a) || php_zv_isdouble(b)) return php_cmp_f(php_zv_double(a), php_zv_double(b));
    return php_cmp_i(php_zv_long(a), php_zv_long(b));
}

i64 php_zv_identical(uptr a, uptr b) {
    i64 ta = php_zv_type(a);
    i64 tb = php_zv_type(b);
    if (ta != tb) return 0;
    if (ta == IS_NULL || ta == IS_TRUE || ta == IS_FALSE) return 1;
    if (ta == IS_LONG) { if (ld64(a) == ld64(b)) return 1; return 0; }
    if (ta == IS_DOUBLE) { if (ldf64(a) == ldf64(b)) return 1; return 0; }
    if (ta == IS_STRING) return php_str_eq(ld64(a), ld64(b));
    if (ta == IS_OBJECT) { if (ld64(a) == ld64(b)) return 1; return 0; }
    if (ta == IS_ARRAY) {
        uptr x = ld64(a);
        uptr y = ld64(b);
        if (php_count(x) != php_count(y)) return 0;
        i64 ux = php_ht_used(x);
        i64 uy = php_ht_used(y);
        i64 i = 0;
        i64 j = 0;
        loop {
            loop { if (i >= ux) break; if (ld8(php_ht_bkt(x, i) + 8) != IS_UNDEF) break; i = i + 1; }
            loop { if (j >= uy) break; if (ld8(php_ht_bkt(y, j) + 8) != IS_UNDEF) break; j = j + 1; }
            if (i >= ux || j >= uy) break;
            uptr bx = php_ht_bkt(x, i);
            uptr by = php_ht_bkt(y, j);
            if (ld64(bx + 16) != ld64(by + 16)) return 0;
            uptr kx = ld64(bx + 24);
            uptr ky = ld64(by + 24);
            if ((kx && !ky) || (ky && !kx)) return 0;
            if (kx && ky && !php_str_eq(kx, ky)) return 0;
            if (!php_zv_identical(bx, by)) return 0;
            i = i + 1;
            j = j + 1;
        }
        return 1;
    }
    return 0;
}

// ---- output of a zval ------------------------------------------------------
i64 php_echo_zv(uptr z) { php_echo_str(php_zv_str(z)); return 0; }

void php_ind(i64 d) { i64 i = 0; loop { if (i >= d) break; php_write("  ", 2); i = i + 1; } }
void php_sp(i64 d) { i64 i = 0; loop { if (i >= d) break; php_write(" ", 1); i = i + 1; } }

void php_vd_int(i64 v) { php_write("int(", 4); php_echo_int(v); php_write(")\n", 2); }
void php_vd_bool(u8 b) {
    php_write("bool(", 5);
    if (b) php_write("true", 4);
    if (!b) php_write("false", 5);
    php_write(")\n", 2);
}
void php_vd_null() { php_write("NULL\n", 5); }
void php_vd_float(f64 x) {
    php_write("float(", 6);
    u8 t[64];
    i64 n = php_fmt_f64(t, x, 0);
    php_write(t, n);
    php_write(")\n", 2);
}
void php_vd_str(uptr s) {
    php_write("string(", 7);
    php_echo_int(php_strlen(s));
    php_write(") \"", 3);
    php_echo_str(s);
    php_write("\"\n", 2);
}
// int|false: the union strpos has, with -1 as the false
void php_vd_ifalse(i64 v) { if (v < 0) { php_vd_bool(0); return; } php_vd_int(v); }

uptr php_ce_lookup(uptr ce, i64 tab, uptr name);
uptr php_ce_owner(uptr ce, i64 tab, uptr name);
uptr php_obj_ce(uptr o);
void php_vd_key_ce(uptr b, uptr ce);
void php_vd_ht_ce(uptr a, i64 depth, uptr ce);
void php_pr_ht_ce(uptr a, i64 depth, i64 isobj, uptr ce);

#define V_PUBLIC    0
#define V_PROTECTED 1
#define V_PRIVATE   2

// php marks a non-public property where it prints one: `["b":protected]` and
// `["c":"P":private]` in var_dump, `[b:protected]` and `[c:P:private]` in
// print_r. `ce` is 0 for a plain array, which is what makes it safe to call
// from the array printer too.
i64 php_prop_vis(uptr ce, uptr name) {
    if (!ce) return V_PUBLIC;
    uptr b = php_ce_lookup(ce, 72, name);
    if (!b) return V_PUBLIC;
    return ld64(b) / 8;
}

void php_vd_key(uptr b) { php_vd_key_ce(b, 0); }

void php_vd_key_ce(uptr b, uptr ce) {
    uptr k = ld64(b + 24);
    php_write("[", 1);
    if (k) { php_write("\"", 1); php_echo_str(k); php_write("\"", 1); }
    if (!k) php_echo_int(ld64(b + 16));
    if (k) {
        i64 v = php_prop_vis(ce, k);
        if (v == V_PROTECTED) php_write(":protected", 10);
        if (v == V_PRIVATE) {
            php_write(":\"", 2);
            uptr ow = php_ce_owner(ce, 72, k);
            if (ow) php_echo_str(ld64(ow));
            php_write("\":private", 9);
        }
    }
    php_write("]=>\n", 4);
}

void php_vd_ht(uptr a, i64 depth) { php_vd_ht_ce(a, depth, 0); }

void php_vd_ht_ce(uptr a, i64 depth, uptr ce) {
    i64 used = php_ht_used(a);
    i64 i = 0;
    loop {
        if (i >= used) break;
        uptr b = php_ht_bkt(a, i);
        if (ld8(b + 8) != IS_UNDEF) {
            php_ind(depth + 1);
            php_vd_key_ce(b, ce);
            php_ind(depth + 1);
            php_vd_zv(b, depth + 1);
        }
        i = i + 1;
    }
}

void php_vd_arr(uptr a, i64 depth) {
    php_write("array(", 6);
    php_echo_int(php_count(a));
    php_write(") {\n", 4);
    php_vd_ht(a, depth);
    php_ind(depth);
    php_write("}\n", 2);
}

void php_vd_obj(uptr o, i64 depth) {
    uptr p = php_obj_props(o);
    php_write("object(", 7);
    php_echo_str(php_obj_cname(o));
    php_write(")#", 2);
    php_echo_int(php_obj_id(o));
    php_write(" (", 2);
    php_echo_int(php_count(p));
    php_write(") {\n", 4);
    php_vd_ht_ce(p, depth, php_obj_ce(o));
    php_ind(depth);
    php_write("}\n", 2);
}

void php_vd_zv(uptr z, i64 depth) {
    i64 t = php_zv_type(z);
    if (t == IS_LONG)   { php_vd_int(ld64(z)); return; }
    if (t == IS_DOUBLE) { php_vd_float(ldf64(z)); return; }
    if (t == IS_STRING) { php_vd_str(ld64(z)); return; }
    if (t == IS_TRUE)   { php_vd_bool(1); return; }
    if (t == IS_FALSE)  { php_vd_bool(0); return; }
    if (t == IS_ARRAY)  { php_vd_arr(ld64(z), depth); return; }
    if (t == IS_OBJECT) { php_vd_obj(ld64(z), depth); return; }
    if (t == IS_RESOURCE) {
        php_write("resource(", 9);
        php_echo_int(ld64(z));
        php_write(") of type (stream)\n", 19);
        return;
    }
    php_vd_null();
}

// print_r: php's own indentation -- a nested level is 8 more spaces, and the
// value of a nested array is followed by a blank line.
void php_pr_ht(uptr a, i64 depth, i64 isobj) { php_pr_ht_ce(a, depth, isobj, 0); }

void php_pr_ht_ce(uptr a, i64 depth, i64 isobj, uptr ce) {
    if (isobj) php_write(" Object\n", 8);
    if (!isobj) php_write("Array\n", 6);
    php_sp(depth);
    php_write("(\n", 2);
    i64 used = php_ht_used(a);
    i64 i = 0;
    loop {
        if (i >= used) break;
        uptr b = php_ht_bkt(a, i);
        if (ld8(b + 8) != IS_UNDEF) {
            php_sp(depth + 4);
            php_write("[", 1);
            uptr k = ld64(b + 24);
            if (k) php_echo_str(k);
            if (!k) php_echo_int(ld64(b + 16));
            if (k) {
                i64 v = php_prop_vis(ce, k);
                if (v == V_PROTECTED) php_write(":protected", 10);
                if (v == V_PRIVATE) {
                    php_write(":", 1);
                    uptr ow = php_ce_owner(ce, 72, k);
                    if (ow) php_echo_str(ld64(ow));
                    php_write(":private", 8);
                }
            }
            php_write("] => ", 5);
            php_pr_zv(b, depth + 8);
            php_write("\n", 1);
        }
        i = i + 1;
    }
    php_sp(depth);
    php_write(")\n", 2);
}

void php_pr_zv(uptr z, i64 depth) {
    i64 t = php_zv_type(z);
    if (t == IS_ARRAY) { php_pr_ht(ld64(z), depth, 0); return; }
    if (t == IS_OBJECT) {
        php_echo_str(php_obj_cname(ld64(z)));
        php_pr_ht_ce(php_obj_props(ld64(z)), depth, 1, php_obj_ce(ld64(z)));
        return;
    }
    php_echo_str(php_zv_str(z));
}

void php_print_r(uptr z) { php_pr_zv(z, 0); }

// var_export
void php_ex_str(uptr s) {
    php_write("'", 1);
    i64 n = php_strlen(s);
    i64 i = 0;
    loop {
        if (i >= n) break;
        i64 c = ld8(s + ZS_HDR + i);
        if (c == 39 || c == 92) php_write("\\", 1);
        u8 t[1];
        st8(t, c);
        php_write(t, 1);
        i = i + 1;
    }
    php_write("'", 1);
}

void php_ex_zv(uptr z, i64 depth) {
    i64 t = php_zv_type(z);
    if (t == IS_LONG)   { php_echo_int(ld64(z)); return; }
    if (t == IS_TRUE)   { php_write("true", 4); return; }
    if (t == IS_FALSE)  { php_write("false", 5); return; }
    if (t == IS_NULL)   { php_write("NULL", 4); return; }
    if (t == IS_STRING) { php_ex_str(ld64(z)); return; }
    if (t == IS_DOUBLE) {
        u8 b[64];
        i64 n = php_fmt_f64(b, ldf64(z), 0);
        php_write(b, n);
        i64 i = 0;
        i64 dot = 0;
        loop { if (i >= n) break; i64 c = ld8(b + i); if (c == '.' || c == 'E' || c == 'N' || c == 'I') dot = 1; i = i + 1; }
        if (!dot) php_write(".0", 2);
        return;
    }
    if (t == IS_ARRAY) {
        uptr a = ld64(z);
        php_write("array (\n", 8);
        i64 used = php_ht_used(a);
        i64 i = 0;
        loop {
            if (i >= used) break;
            uptr b = php_ht_bkt(a, i);
            if (ld8(b + 8) != IS_UNDEF) {
                php_sp(depth + 2);
                uptr k = ld64(b + 24);
                if (k) php_ex_str(k);
                if (!k) php_echo_int(ld64(b + 16));
                php_write(" => ", 4);
                if (php_zv_type(b) == IS_ARRAY) { php_write("\n", 1); php_sp(depth + 2); }
                php_ex_zv(b, depth + 2);
                php_write(",\n", 2);
            }
            i = i + 1;
        }
        php_sp(depth);
        php_write(")", 1);
        return;
    }
    if (t == IS_OBJECT) {
        // php writes \Foo::__set_state(array( ... )) for a class and
        // (object) array( ... ) for stdClass; the indent is 3 per level, not 2
        uptr o = ld64(z);
        uptr cn = php_obj_cname(o);
        i64 std = php_str_eq(cn, php_str_new("stdClass", 8));
        if (std) php_write("(object) array(\n", 16);
        if (!std) {
            php_write("\\", 1);
            php_echo_str(cn);
            php_write("::__set_state(array(\n", 21);
        }
        uptr a = php_obj_props(o);
        i64 used = php_ht_used(a);
        i64 i = 0;
        loop {
            if (i >= used) break;
            uptr b = php_ht_bkt(a, i);
            if (ld8(b + 8) != IS_UNDEF) {
                php_sp(depth + 3);
                uptr k = ld64(b + 24);
                php_write("'", 1);
                if (k) php_echo_str(k);
                if (!k) php_echo_int(ld64(b + 16));
                php_write("' => ", 5);
                if (php_zv_type(b) == IS_ARRAY) { php_write("\n", 1); php_sp(depth + 2); }
                php_ex_zv(b, depth + 2);
                php_write(",\n", 2);
            }
            i = i + 1;
        }
        php_sp(depth);
        if (std) php_write(")", 1);
        if (!std) php_write("))", 2);
        return;
    }
    php_write("NULL", 4);
}

void php_var_export(uptr z) { php_ex_zv(z, 0); php_write("\n", 1); }

// ---- the string functions T5 implements ------------------------------------
uptr php_substr(uptr s, i64 start, i64 len, i64 haslen) {
    i64 n = php_strlen(s);
    if (start < 0) { start = n + start; if (start < 0) start = 0; }
    if (start > n) return php_str_new("", 0);
    i64 want = n - start;
    if (haslen) {
        if (len < 0) { want = n - start + len; } else { want = len; }
    }
    if (want < 0) want = 0;
    if (start + want > n) want = n - start;
    return php_str_new(s + ZS_HDR + start, want);
}

i64 php_strpos(uptr h, uptr nd, i64 off) {
    i64 hn = php_strlen(h);
    i64 nn = php_strlen(nd);
    if (off < 0) { off = hn + off; if (off < 0) off = 0; }
    if (off > hn) return -1;
    i64 i = off;
    loop {
        if (i + nn > hn) break;
        i64 j = 0;
        i64 ok = 1;
        loop {
            if (j >= nn) break;
            if (ld8(h + ZS_HDR + i + j) != ld8(nd + ZS_HDR + j)) { ok = 0; break; }
            j = j + 1;
        }
        if (ok) return i;
        i = i + 1;
    }
    return -1;
}

uptr php_str_repeat(uptr s, i64 times) {
    if (times <= 0) return php_str_new("", 0);
    i64 n = php_strlen(s);
    uptr o = php_str_alloc(n * times);
    i64 i = 0;
    loop { if (i >= times) break; php_memcpy(o + ZS_HDR + i * n, s + ZS_HDR, n); i = i + 1; }
    return o;
}

uptr php_str_replace(uptr search, uptr repl, uptr subj) {
    i64 sn = php_strlen(search);
    if (sn == 0) return subj;
    i64 hn = php_strlen(subj);
    i64 rn = php_strlen(repl);
    i64 cnt = 0;
    i64 i = 0;
    loop {
        i64 p = php_strpos(subj, search, i);
        if (p < 0) break;
        cnt = cnt + 1;
        i = p + sn;
    }
    if (cnt == 0) return subj;
    uptr o = php_str_alloc(hn + cnt * (rn - sn));
    i64 w = 0;
    i = 0;
    loop {
        i64 p = php_strpos(subj, search, i);
        if (p < 0) break;
        php_memcpy(o + ZS_HDR + w, subj + ZS_HDR + i, p - i);
        w = w + (p - i);
        php_memcpy(o + ZS_HDR + w, repl + ZS_HDR, rn);
        w = w + rn;
        i = p + sn;
    }
    php_memcpy(o + ZS_HDR + w, subj + ZS_HDR + i, hn - i);
    return o;
}

uptr php_implode(uptr sep, uptr a) {
    i64 n = php_count(a);
    if (n == 0) return php_str_new("", 0);
    i64 sl = php_strlen(sep);
    i64 total = sl * (n - 1);
    i64 used = php_ht_used(a);
    i64 i = 0;
    loop {
        if (i >= used) break;
        uptr b = php_ht_bkt(a, i);
        if (ld8(b + 8) != IS_UNDEF) total = total + php_strlen(php_zv_str(b));
        i = i + 1;
    }
    uptr o = php_str_alloc(total);
    i64 w = 0;
    i64 k = 0;
    i = 0;
    loop {
        if (i >= used) break;
        uptr b = php_ht_bkt(a, i);
        if (ld8(b + 8) != IS_UNDEF) {
            if (k) { php_memcpy(o + ZS_HDR + w, sep + ZS_HDR, sl); w = w + sl; }
            uptr e = php_zv_str(b);
            i64 el = php_strlen(e);
            php_memcpy(o + ZS_HDR + w, e + ZS_HDR, el);
            w = w + el;
            k = k + 1;
        }
        i = i + 1;
    }
    return o;
}

uptr php_explode(uptr sep, uptr s) {
    uptr a = php_arr_new(8);
    i64 sl = php_strlen(sep);
    if (sl == 0) { php_arr_push(a, php_zstr(s)); return a; }
    i64 i = 0;
    loop {
        i64 p = php_strpos(s, sep, i);
        if (p < 0) break;
        php_arr_push(a, php_zstr(php_str_new(s + ZS_HDR + i, p - i)));
        i = p + sl;
    }
    php_arr_push(a, php_zstr(php_str_new(s + ZS_HDR + i, php_strlen(s) - i)));
    return a;
}

i64 php_intdiv(i64 a, i64 b) {
    if (b == 0) { php_throw_cls(php_str_new("DivisionByZeroError", 19), php_str_new("Division by zero", 16)); return 0; }
    // php's own message, and php's own class: the quotient is not an integer,
    // which is a throw and not a trap
    if (a == -9223372036854775807 - 1 && b == -1) {
        php_throw_cls(php_str_new("ArithmeticError", 15),
                      php_str_new("Division of PHP_INT_MIN by -1 is not an integer", 47));
        return 0;
    }
    return a / b;
}
i64 php_abs_i(i64 v) { if (v < 0) return 0 - v; return v; }
f64 php_abs_f(f64 v) { if (v < 0.0) return 0.0 - v; return v; }
i64 php_max_i(i64 a, i64 b) { if (a >= b) return a; return b; }
i64 php_min_i(i64 a, i64 b) { if (a <= b) return a; return b; }
f64 php_max_f(f64 a, f64 b) { if (a >= b) return a; return b; }
f64 php_min_f(f64 a, f64 b) { if (a <= b) return a; return b; }
i64 php_mod(i64 a, i64 b) {
    if (b == 0) { php_throw_cls(php_str_new("DivisionByZeroError", 19), php_str_new("Modulo by zero", 14)); return 0; }
    // `x % -1` is 0 for every x, and this is not a shortcut: on x86-64 `idiv`
    // raises #DE for PHP_INT_MIN / -1 because the quotient is not
    // representable, so `a / b` below killed the process with SIGFPE where
    // php answers 0. AArch64's sdiv wraps instead and said 0 all along, which
    // is why it took a cross-host fixture to find.
    if (b == -1) return 0;
    return a - (a / b) * b;
}
i64 php_div_i(i64 a, i64 b) {
    if (b == 0) { php_throw_cls(php_str_new("DivisionByZeroError", 19), php_str_new("Division by zero", 16)); return 0; }
    // the same #DE as php_mod: the one quotient an i64 cannot hold. Its
    // caller has already established that the division is exact, so this is
    // unreachable from php_zv_div -- which sends the pair to the float road
    // before it gets here -- and the guard is what makes that a guarantee
    // rather than a reading of the caller.
    if (a == -9223372036854775807 - 1 && b == -1) return a;
    return a / b;
}
f64 php_pow_f(f64 a, i64 e) {
    f64 r = 1.0;
    i64 n = e;
    i64 inv = 0;
    if (n < 0) { inv = 1; n = 0 - n; }
    loop { if (n <= 0) break; r = r * a; n = n - 1; }
    if (inv) return 1.0 / r;
    return r;
}
i64 php_pow_i(i64 a, i64 e) {
    i64 r = 1;
    i64 n = e;
    loop { if (n <= 0) break; r = r * a; n = n - 1; }
    return r;
}

// the program's exit path: the buffer must reach fd 1 before _exit
i64 php_end() { php_flush(); return 0; }

uptr php_mcall(uptr o, uptr name, uptr scope, i64 n, uptr a1, uptr a2, uptr a3,
               uptr a4, uptr a5, uptr a6);

i64 ph_dt_ran;

uptr php_call_zv(uptr z, i64 n, uptr a1, uptr a2, uptr a3, uptr a4, uptr a5);

void php_shutdown() {
    if (ph_dt_ran) return;
    ph_dt_ran = 1;
    // php runs register_shutdown_function() callbacks first, then destructors
    if (ph_sdfn) {
        i64 used = php_ht_used(ph_sdfn);
        i64 i = 0;
        loop {
            if (i >= used) break;
            uptr bk = php_ht_bkt(ph_sdfn, i);
            if (ld8(bk + 8) != IS_UNDEF) {
                uptr row = ld64(bk);
                i64 nsa = php_zv_long(php_arr_iget(row, 4));
                php_call_zv(php_arr_iget(row, 0), nsa, php_arr_iget(row, 1),
                            php_arr_iget(row, 2), php_arr_iget(row, 3), 0, 0);
                ph_exc = 0;
            }
            i = i + 1;
        }
    }
    uptr n = ph_dt_head;
    loop {
        if (!n) break;
        uptr o = ld64(n);
        n = ld64(n + 8);
        php_mcall(o, php_str_new("__destruct", 10), 0, 0, 0, 0, 0, 0, 0, 0);
        ph_exc = 0;
    }
}

// ---- what the compiler needs beside the named php functions ---------------
i64 php_truthy_s(uptr s) {
    i64 n = php_strlen(s);
    if (n == 0) return 0;
    if (n == 1 && ld8(s + ZS_HDR) == '0') return 0;
    return 1;
}
i64 php_truthy_f(f64 x) { if (x == 0.0) return 0; return 1; }
f64 php_fzero(i64 ignored) { return 0.0; }
i64 php_cmp_i(i64 a, i64 b) { if (a < b) return -1; if (a > b) return 1; return 0; }
i64 php_cmp_f(f64 a, f64 b) { if (a < b) return -1; if (a > b) return 1; return 0; }
f64 php_div_f(f64 a, f64 b) {
    if (b == 0.0) { php_throw_cls(php_str_new("DivisionByZeroError", 19), php_str_new("Division by zero", 16)); return 0.0; }
    return a / b;
}
i64 php_seq_i(i64 ignored, i64 v) { return v; }
void php_shutdown();
void php_exit(i64 code) { php_shutdown(); php_flush(); exit(code); }
// printf's %f is php's: six digits after the point, always
uptr php_ftos6(f64 x) {
    u8 t[64];
    i64 n = 0;
    f64 a = x;
    if ((ph_bits(x) >> 63) != 0) { st8(t, '-'); n = 1; a = 0.0 - x; }
    i64 ip = (i64) a;
    f64 fr = a - (f64) ip;
    i64 frac = (i64) (fr * 1000000.0 + 0.5);
    if (frac >= 1000000) { frac = frac - 1000000; ip = ip + 1; }
    uptr is = php_itos(ip);
    php_memcpy(t + n, is + ZS_HDR, php_strlen(is));
    n = n + php_strlen(is);
    st8(t + n, '.');
    n = n + 1;
    i64 d = 100000;
    loop {
        if (d == 0) break;
        st8(t + n, '0' + (frac / d) % 10);
        n = n + 1;
        d = d / 10;
    }
    return php_str_new(t, n);
}

// ---- the rest of the string set T5 implements -----------------------------
uptr php_chr(i64 c) {
    i64 b = c % 256;
    if (b < 0) b = b + 256;
    u8 t[1];
    st8(t, b);
    return php_str_new(t, 1);
}
i64 php_ord(uptr s) { if (php_strlen(s) == 0) return 0; return ld8(s + ZS_HDR); }

uptr php_case(uptr s, i64 up) {
    i64 n = php_strlen(s);
    uptr o = php_str_alloc(n);
    i64 i = 0;
    loop {
        if (i >= n) break;
        i64 c = ld8(s + ZS_HDR + i);
        if (up && c >= 'a' && c <= 'z') c = c - 32;
        if (!up && c >= 'A' && c <= 'Z') c = c + 32;
        st8(o + ZS_HDR + i, c);
        i = i + 1;
    }
    return o;
}
uptr php_strtoupper(uptr s) { return php_case(s, 1); }
uptr php_strtolower(uptr s) { return php_case(s, 0); }

uptr php_ucfirst(uptr s) {
    i64 n = php_strlen(s);
    if (n == 0) return s;
    uptr o = php_str_new(s + ZS_HDR, n);
    i64 c = ld8(o + ZS_HDR);
    if (c >= 'a' && c <= 'z') st8(o + ZS_HDR, c - 32);
    return o;
}
uptr php_lcfirst(uptr s) {
    i64 n = php_strlen(s);
    if (n == 0) return s;
    uptr o = php_str_new(s + ZS_HDR, n);
    i64 c = ld8(o + ZS_HDR);
    if (c >= 'A' && c <= 'Z') st8(o + ZS_HDR, c + 32);
    return o;
}

// php's default charlist for trim: " \t\n\r\0\x0B"
i64 php_trimset(i64 c) {
    if (c == 32 || c == 9 || c == 10 || c == 13 || c == 0 || c == 11) return 1;
    return 0;
}
uptr php_trim(uptr s, i64 mode) {         // 0 both, 1 left, 2 right
    i64 n = php_strlen(s);
    i64 a = 0;
    i64 b = n;
    if (mode != 2) { loop { if (a >= b) break; if (!php_trimset(ld8(s + ZS_HDR + a))) break; a = a + 1; } }
    if (mode != 1) { loop { if (b <= a) break; if (!php_trimset(ld8(s + ZS_HDR + b - 1))) break; b = b - 1; } }
    return php_str_new(s + ZS_HDR + a, b - a);
}

uptr php_strrev(uptr s) {
    i64 n = php_strlen(s);
    uptr o = php_str_alloc(n);
    i64 i = 0;
    loop { if (i >= n) break; st8(o + ZS_HDR + i, ld8(s + ZS_HDR + n - 1 - i)); i = i + 1; }
    return o;
}

uptr php_str_pad(uptr s, i64 len, uptr pad, i64 type) {    // php: 0 left, 1 right, 2 both
    i64 n = php_strlen(s);
    i64 pl = php_strlen(pad);
    if (len <= n || pl == 0) return s;
    i64 need = len - n;
    i64 left = 0;
    if (type == 0) left = need;
    if (type == 2) left = need / 2;
    i64 right = need - left;
    uptr o = php_str_alloc(len);
    i64 w = 0;
    i64 i = 0;
    loop { if (i >= left) break; st8(o + ZS_HDR + w, ld8(pad + ZS_HDR + i % pl)); w = w + 1; i = i + 1; }
    php_memcpy(o + ZS_HDR + w, s + ZS_HDR, n);
    w = w + n;
    i = 0;
    loop { if (i >= right) break; st8(o + ZS_HDR + w, ld8(pad + ZS_HDR + i % pl)); w = w + 1; i = i + 1; }
    return o;
}

u8 php_str_contains(uptr h, uptr n) { if (php_strlen(n) == 0) return 1; if (php_strpos(h, n, 0) >= 0) return 1; return 0; }
u8 php_str_starts(uptr h, uptr n) {
    i64 ln = php_strlen(n);
    if (ln > php_strlen(h)) return 0;
    i64 i = 0;
    loop { if (i >= ln) break; if (ld8(h + ZS_HDR + i) != ld8(n + ZS_HDR + i)) return 0; i = i + 1; }
    return 1;
}
u8 php_str_ends(uptr h, uptr n) {
    i64 ln = php_strlen(n);
    i64 lh = php_strlen(h);
    if (ln > lh) return 0;
    i64 i = 0;
    loop { if (i >= ln) break; if (ld8(h + ZS_HDR + lh - ln + i) != ld8(n + ZS_HDR + i)) return 0; i = i + 1; }
    return 1;
}
i64 php_strcasecmp(uptr a, uptr b) { return php_str_cmp(php_case(a, 0), php_case(b, 0)); }

// ---- objects ---------------------------------------------------------------
// zend_object's shape as far as this runtime needs it:
//   0 gc (refcount u32, type_info u32) | 8 handle u32 | 16 ce | 24 properties
// A class entry is the compiler's own record; its first field is the name, so
// php_obj_cname is one indirection.
// 0 refcount u32 | 4 type u32 | 8 id u32 | 16 ce | 24 props | 32 the
// readonly marks -- a table of its own, and NOT the property table: a mark
// kept beside the properties is an observable extra property to var_dump,
// print_r, var_export, get_object_vars, a clone and a dynamic read.
#define OBJ_HDR 40

i64 ph_objid;

// ---- __destruct (docs/plan.md D7) -----------------------------------------
// php runs a destructor when the last reference goes away. D7 has no refcount
// and no free, so that moment does not exist here; what does exist is the END
// OF THE PROGRAM, and php runs every surviving destructor there too, in
// REVERSE creation order (measured on 8.5.10: three globals created 1, 2, 6
// come out d6, d2, d1). Every object whose class has a __destruct joins a
// list newest-first, so walking it IS that order. What is NOT implemented,
// and what RESULTS.md counts: the destructor of an object that dies early --
// a function local, an `unset`, a reassignment, a temporary.
uptr ph_dt_head;

uptr php_ce_lookup(uptr ce, i64 tab, uptr name);

uptr php_obj_new(uptr ce) {
    uptr o = php_alloc(OBJ_HDR);
    st32(o, 1);
    st32(o + 4, IS_OBJECT);
    ph_objid = ph_objid + 1;
    st32(o + 8, ph_objid);
    st64(o + 16, ce);
    st64(o + 24, php_arr_new(8));
    st64(o + 32, 0);                 // the readonly marks, made on first use
    return o;
}

// An object joins the destructor list when it is fully CREATED, which is
// after its constructor returns normally -- php does not destruct one whose
// constructor threw, and does not create one at all when an ARGUMENT to
// `new` threw first (Zend/tests/try/catch_00{2,3,4}, exceptions/bug47771).
void php_dt_arm(uptr o) {
    uptr ce = php_obj_ce(o);
    if (!ce) return;
    if (!php_ce_lookup(ce, 24, php_str_new("__destruct", 10))) return;
    uptr n = php_alloc(16);
    st64(n, o);
    st64(n + 8, ph_dt_head);
    ph_dt_head = n;
}

i64  php_obj_id(uptr o) { return ld32(o + 8); }
// the class entry: 0 name | 8 parent | 16 __toString | 24 methods | 32 statics
//                 40 property defaults | 48 interfaces | 56 constants
uptr php_obj_tostr(uptr o) {
    uptr ce = ld64(o + 16);
    uptr f = 0;
    uptr c = ce;
    loop { if (!c) break; if (ld64(c + 16)) { f = ld64(c + 16); break; } c = ld64(c + 8); }
    // __toString answers a zval; every caller here wants the zend_string
    if (f) return php_zv_str(callp(f, o));
    uptr m = php_str_concat(php_str_new("Object of class ", 16), ld64(ce));
    m = php_str_concat(m, php_str_new(" could not be converted to string", 33));
    php_throw_str(php_str_new("Error", 5), m);
    return php_str_new("", 0);
}
uptr php_obj_ce(uptr o) { return ld64(o + 16); }
uptr php_obj_props(uptr o) { return ld64(o + 24); }

// The per-object "this readonly property has been written" set. It is its
// OWN table: D7 has no bitmap, and the value cannot stand in for it (a
// property deliberately initialised to null has been written), but a mark
// in php_obj_props(o) would be visible to every property API there is.
uptr php_obj_romarks(uptr o) {
    if (!ld64(o + 32)) st64(o + 32, php_arr_new(4));
    return ld64(o + 32);
}
uptr php_obj_cname(uptr o) { return ld64(ld64(o + 16)); }

// ---- errors ----------------------------------------------------------------
// php's uncaught-throwable text, on stdout as the cli sapi prints it.
// php's cli writes the diagnostic to BOTH streams: "PHP Fatal error:  ..." on
// stderr and "\nFatal error: ..." on stdout. The grid reads stdout.
void php_fatal(uptr s) {
    php_write("\nFatal error: ", 14);
    php_echo_str(s);
    php_write("\n", 1);
    php_flush();
    write(2, "PHP Fatal error:  ", 18);
    write(2, s + ZS_HDR, php_strlen(s));
    write(2, "\n", 1);
    exit(255);
}

// defined for real further down, once the class hierarchy exists
i64 php_throw_cls(uptr cls, uptr msg);
i64 php_throw_str(uptr cls, uptr msg) { return php_throw_cls(cls, msg); }

// ---- array value semantics -------------------------------------------------
// A php array is a VALUE: `$b = $a; $b[] = 1;` must leave $a alone. php does
// that with a refcount and copy-on-write; D7 removed the free, so a refcount
// that never drops would never separate. T6 copies EAGERLY at the four places
// the value is handed over -- an assignment, an insertion, an argument, a
// return -- which is exactly right and costs one O(n) copy each. The cost is
// measured in RESULTS.md; the compiler skips it when the source is a value it
// has just built.
void php_zv_cpv(uptr d, uptr s) {
    php_zv_cp(d, s);
    if (php_zv_type(s) == IS_ARRAY) st64(d, php_arr_copy(ld64(s)));
}

uptr php_zv_val(uptr s) {
    uptr z = php_zv_dup(s);
    if (php_zv_type(s) == IS_ARRAY) st64(z, php_arr_copy(ld64(s)));
    return z;
}

uptr php_zifalse(i64 v) { if (v < 0) return php_zbool(0); return php_zlong(v); }

// auto-vivification: $a[k][j] = v makes the inner array when it is not there
uptr php_arr_dim(uptr a, uptr k) {
    uptr b = php_arr_zslot(a, k);
    if (php_zv_type(b) != IS_ARRAY) { st64(b, php_arr_new(8)); php_zv_settype(b, IS_ARRAY); }
    return ld64(b);
}

uptr php_arr_dimn(uptr a) {
    uptr b = php_arr_nextslot(a);
    if (php_zv_type(b) != IS_ARRAY) { st64(b, php_arr_new(8)); php_zv_settype(b, IS_ARRAY); }
    return ld64(b);
}

// a zval used as an array on the left of a subscript
uptr php_zv_arr_w(uptr z) {
    if (php_zv_type(z) != IS_ARRAY) { st64(z, php_arr_new(8)); php_zv_settype(z, IS_ARRAY); }
    return ld64(z);
}

uptr php_zv_arr_r(uptr z) {
    if (php_zv_type(z) != IS_ARRAY) return php_arr_new(8);
    return ld64(z);
}

// `$z[k]` where $z is a zval: php reads an array element (warning on a
// missing key), a string offset, and for anything else warns
// "Trying to access array offset on <type>" and yields null -- and it does
// NOT then also complain about the key. One function, so the two warnings
// cannot both fire.
uptr php_str_off(uptr s, i64 i);
uptr php_zstr(uptr s);

uptr php_zv_dim_rd(uptr z, uptr k) {
    i64 t = php_zv_type(z);
    if (t == IS_ARRAY) return php_arr_zget_w(ld64(z), k);
    if (t == IS_STRING) {
        uptr s = ld64(z);
        i64 i = php_zv_long(k);
        i64 n = php_strlen(s);
        i64 j = i;
        if (j < 0) j = n + j;
        if (j < 0 || j >= n) {
            php_mreset();
            php_mc("Uninitialized string offset ");
            php_mi(i);
            php_raise_m(PHE_WARNING);
            return php_zstr(php_str_new("", 0));
        }
        return php_zstr(php_str_off(s, i));
    }
    if (t == IS_OBJECT) return php_arr_zget_w(php_arr_new(8), k);
    php_mreset();
    php_mc("Trying to access array offset on ");
    if (t == IS_TRUE) php_mc("true");
    if (t == IS_FALSE) php_mc("false");
    if (t != IS_TRUE && t != IS_FALSE) php_ms(php_f_get_debug_type(z));
    php_raise_m(PHE_WARNING);
    return php_znull();
}

// ---- iteration (foreach) ---------------------------------------------------
i64 php_it_next(uptr a, i64 i) {
    i64 used = php_ht_used(a);
    loop {
        if (i >= used) return -1;
        if (ld8(php_ht_bkt(a, i) + 8) != IS_UNDEF) return i;
        i = i + 1;
    }
    return -1;
}

uptr php_it_key(uptr a, i64 i) {
    uptr b = php_ht_bkt(a, i);
    uptr k = ld64(b + 24);
    if (k) return php_zstr(k);
    return php_zlong(ld64(b + 16));
}

uptr php_it_val(uptr a, i64 i) { return php_zv_val(php_ht_bkt(a, i)); }
uptr php_it_ref(uptr a, i64 i) { return php_ht_bkt(a, i); }

// a string offset: $s[3], and php's negative index
uptr php_str_off(uptr s, i64 i) {
    i64 n = php_strlen(s);
    if (i < 0) i = n + i;
    if (i < 0 || i >= n) return php_str_new("", 0);
    return php_str_new(s + ZS_HDR + i, 1);
}

// ---- ++ and -- on a zval, php's own rules ----------------------------------
// null++ is 1, null-- stays null, a numeric string is a number, and a
// non-numeric string gets php's perl-style alphanumeric increment.
uptr php_str_inc(uptr s) {
    i64 n = php_strlen(s);
    if (n == 0) return php_str_new("1", 1);
    uptr o = php_str_new(s + ZS_HDR, n);
    uptr v = o + ZS_HDR;
    i64 i = n - 1;
    loop {
        if (i < 0) break;
        i64 c = ld8(v + i);
        if (c >= 'a' && c < 'z') { st8(v + i, c + 1); return o; }
        if (c >= 'A' && c < 'Z') { st8(v + i, c + 1); return o; }
        if (c >= '0' && c < '9') { st8(v + i, c + 1); return o; }
        if (c == 'z') { st8(v + i, 'a'); i = i - 1; continue; }
        if (c == 'Z') { st8(v + i, 'A'); i = i - 1; continue; }
        if (c == '9') { st8(v + i, '0'); i = i - 1; continue; }
        return o;
    }
    // every position carried: php prepends a, A or 1 by the first character
    i64 f = ld8(o + ZS_HDR);
    uptr r = php_str_alloc(n + 1);
    i64 c0 = '1';
    if (f == 'a') c0 = 'a';
    if (f == 'A') c0 = 'A';
    st8(r + ZS_HDR, c0);
    php_memcpy(r + ZS_HDR + 1, o + ZS_HDR, n);
    return r;
}

uptr php_zv_inc(uptr z) {
    i64 t = php_zv_type(z);
    if (t == IS_NULL || t == IS_UNDEF) return php_zlong(1);
    if (t == IS_LONG) {
        i64 v = ld64(z);
        if (v == 9223372036854775807) return php_zdouble(9223372036854775808.0);
        return php_zlong(v + 1);
    }
    if (t == IS_DOUBLE) return php_zdouble(ldf64(z) + 1.0);
    if (t == IS_STRING) {
        u8 lb[8];
        u8 db[8];
        i64 k = php_str_isnum(ld64(z), lb, db);
        if (k == 1) return php_zlong(ld64(lb) + 1);
        if (k == 2) return php_zdouble(ldf64(db) + 1.0);
        php_depr1("Increment on non-numeric string is deprecated, use str_increment() instead");
        return php_zstr(php_str_inc(ld64(z)));
    }
    return php_zv_dup(z);
}

uptr php_zv_dec(uptr z) {
    i64 t = php_zv_type(z);
    if (t == IS_NULL || t == IS_UNDEF) return php_znull();
    if (t == IS_LONG) {
        i64 v = ld64(z);
        if (v == -9223372036854775807 - 1) return php_zdouble(-9223372036854775808.0);
        return php_zlong(v - 1);
    }
    if (t == IS_DOUBLE) return php_zdouble(ldf64(z) - 1.0);
    if (t == IS_STRING) {
        u8 lb[8];
        u8 db[8];
        i64 k = php_str_isnum(ld64(z), lb, db);
        if (k == 1) return php_zlong(ld64(lb) - 1);
        if (k == 2) return php_zdouble(ldf64(db) - 1.0);
        php_depr1("Decrement on non-numeric string has no effect and is deprecated");
        return php_zv_dup(z);
    }
    return php_zv_dup(z);
}

// [...$a]: string keys keep their name, integer keys are renumbered
void php_arr_spread(uptr a, uptr z) {
    if (php_zv_type(z) != IS_ARRAY) return;
    uptr s = ld64(z);
    i64 used = php_ht_used(s);
    i64 i = 0;
    loop {
        if (i >= used) break;
        uptr b = php_ht_bkt(s, i);
        if (ld8(b + 8) != IS_UNDEF) {
            uptr k = ld64(b + 24);
            if (k) php_zv_cpv(php_ht_slotfor(a, php_str_hash(k), k), b);
            if (!k) php_zv_cpv(php_arr_nextslot(a), b);
        }
        i = i + 1;
    }
}

// isset() / ?? on a zval: null is "not set"
i64 php_zv_isset(uptr z) { i64 t = php_zv_type(z); if (t == IS_NULL || t == IS_UNDEF) return 0; return 1; }
i64 php_zv_isnull(uptr z) { i64 t = php_zv_type(z); if (t == IS_NULL || t == IS_UNDEF) return 1; return 0; }
i64 php_zv_is(uptr z, i64 t) { i64 k = php_zv_type(z); if (t == IS_TRUE) { if (k == IS_TRUE || k == IS_FALSE) return 1; return 0; } if (k == t) return 1; return 0; }
i64 php_zv_isnum(uptr z) {
    i64 t = php_zv_type(z);
    if (t == IS_LONG || t == IS_DOUBLE) return 1;
    if (t == IS_STRING) { u8 lb[8]; u8 db[8]; if (php_str_isnum(ld64(z), lb, db)) return 1; }
    return 0;
}
i64 php_zv_isset_key(uptr a, uptr k) {
    if (!php_arr_has(a, k)) return 0;
    return php_zv_isset(php_arr_zget(a, k));
}
uptr php_zv_pick(uptr a, uptr b) { if (php_zv_isset(a)) return a; return b; }

i64 php_zv_isscalar(uptr z) {
    i64 t = php_zv_type(z);
    if (t == IS_LONG || t == IS_DOUBLE || t == IS_STRING || t == IS_TRUE || t == IS_FALSE) return 1;
    return 0;
}

// ============================================================================
// The library: every one of these takes zvals and answers a native value, so
// the compiler needs one table row per function and no special case. php's own
// coercion rules live here and not in the compiler (D9).
// ============================================================================

uptr php_f_ret(uptr a) { return a; }

// ---- arrays ----------------------------------------------------------------
u8 php_f_array_key_exists(uptr k, uptr a) {
    if (php_zv_type(a) != IS_ARRAY) return 0;
    return php_arr_has(ld64(a), k);
}

uptr php_f_array_keys(uptr a) {
    uptr r = php_arr_new(8);
    if (php_zv_type(a) != IS_ARRAY) return r;
    uptr h = ld64(a);
    i64 used = php_ht_used(h);
    i64 i = 0;
    loop {
        if (i >= used) break;
        uptr b = php_ht_bkt(h, i);
        if (ld8(b + 8) != IS_UNDEF) php_arr_push(r, php_it_key(h, i));
        i = i + 1;
    }
    return r;
}

uptr php_f_array_values(uptr a) {
    uptr r = php_arr_new(8);
    if (php_zv_type(a) != IS_ARRAY) return r;
    uptr h = ld64(a);
    i64 used = php_ht_used(h);
    i64 i = 0;
    loop {
        if (i >= used) break;
        uptr b = php_ht_bkt(h, i);
        if (ld8(b + 8) != IS_UNDEF) php_arr_push(r, b);
        i = i + 1;
    }
    return r;
}

i64 php_ht_pos(uptr h, uptr needle, i64 strict) {
    i64 used = php_ht_used(h);
    i64 i = 0;
    loop {
        if (i >= used) break;
        uptr b = php_ht_bkt(h, i);
        if (ld8(b + 8) != IS_UNDEF) {
            if (strict) { if (php_zv_identical(b, needle)) return i; }
            if (!strict) { if (php_zv_cmp(b, needle) == 0) return i; }
        }
        i = i + 1;
    }
    return -1;
}

u8 php_f_in_array(uptr n, uptr a, uptr strict) {
    if (php_zv_type(a) != IS_ARRAY) return 0;
    if (php_ht_pos(ld64(a), n, php_zv_bool(strict)) >= 0) return 1;
    return 0;
}

uptr php_f_array_search(uptr n, uptr a, uptr strict) {
    if (php_zv_type(a) != IS_ARRAY) return php_zbool(0);
    i64 i = php_ht_pos(ld64(a), n, php_zv_bool(strict));
    if (i < 0) return php_zbool(0);
    return php_it_key(ld64(a), i);
}

void php_ht_append_all(uptr r, uptr z) {
    if (php_zv_type(z) != IS_ARRAY) return;
    uptr h = ld64(z);
    i64 used = php_ht_used(h);
    i64 i = 0;
    loop {
        if (i >= used) break;
        uptr b = php_ht_bkt(h, i);
        if (ld8(b + 8) != IS_UNDEF) {
            uptr k = ld64(b + 24);
            if (k) php_zv_cpv(php_ht_slotfor(r, php_str_hash(k), k), b);
            if (!k) php_zv_cpv(php_arr_nextslot(r), b);
        }
        i = i + 1;
    }
}

uptr php_f_array_merge(uptr a, uptr b, uptr c, uptr d) {
    uptr r = php_arr_new(8);
    php_ht_append_all(r, a);
    php_ht_append_all(r, b);
    php_ht_append_all(r, c);
    php_ht_append_all(r, d);
    return r;
}

i64 php_ht_last(uptr h) {
    i64 i = php_ht_used(h) - 1;
    loop {
        if (i < 0) return -1;
        if (ld8(php_ht_bkt(h, i) + 8) != IS_UNDEF) return i;
        i = i - 1;
    }
    return -1;
}

uptr php_f_array_pop(uptr a) {
    if (php_zv_type(a) != IS_ARRAY) return php_znull();
    uptr h = ld64(a);
    i64 i = php_ht_last(h);
    if (i < 0) return php_znull();
    uptr b = php_ht_bkt(h, i);
    uptr v = php_zv_dup(b);
    php_zv_settype(b, IS_UNDEF);
    st32(h + 28, ld32(h + 28) - 1);
    st32(h + 24, i);
    if (!ld64(b + 24)) { if (ld64(h + 40) == ld64(b + 16) + 1) st64(h + 40, ld64(b + 16)); }
    return v;
}

// shift renumbers the integer keys, as php does
uptr php_f_array_shift(uptr a) {
    if (php_zv_type(a) != IS_ARRAY) return php_znull();
    uptr h = ld64(a);
    i64 i = php_it_next(h, 0);
    if (i < 0) return php_znull();
    uptr v = php_zv_dup(php_ht_bkt(h, i));
    uptr r = php_arr_new(ld32(h + 32));
    i64 used = php_ht_used(h);
    i64 j = i + 1;
    loop {
        if (j >= used) break;
        uptr b = php_ht_bkt(h, j);
        if (ld8(b + 8) != IS_UNDEF) {
            uptr k = ld64(b + 24);
            if (k) php_zv_cp(php_ht_slotfor(r, php_str_hash(k), k), b);
            if (!k) php_zv_cp(php_arr_nextslot(r), b);
        }
        j = j + 1;
    }
    st64(a, r);
    return v;
}

i64 php_f_array_unshift(uptr a, uptr v) {
    if (php_zv_type(a) != IS_ARRAY) return 0;
    uptr h = ld64(a);
    uptr r = php_arr_new(ld32(h + 32));
    php_arr_push(r, v);
    php_ht_append_all(r, a);
    st64(a, r);
    return php_count(r);
}

uptr php_f_array_slice(uptr a, uptr off, uptr len, uptr pres) {
    uptr r = php_arr_new(8);
    if (php_zv_type(a) != IS_ARRAY) return r;
    uptr h = ld64(a);
    i64 n = php_count(h);
    i64 o = php_zv_long(off);
    if (o < 0) { o = n + o; if (o < 0) o = 0; }
    i64 l = n - o;
    if (php_zv_type(len) != IS_NULL) {
        l = php_zv_long(len);
        if (l < 0) l = n - o + l;
    }
    i64 keep = php_zv_bool(pres);
    i64 used = php_ht_used(h);
    i64 i = 0;
    i64 seen = 0;
    i64 taken = 0;
    loop {
        if (i >= used) break;
        uptr b = php_ht_bkt(h, i);
        if (ld8(b + 8) != IS_UNDEF) {
            if (seen >= o && taken < l) {
                uptr k = ld64(b + 24);
                if (k) php_zv_cpv(php_ht_slotfor(r, php_str_hash(k), k), b);
                if (!k && keep) php_zv_cpv(php_arr_islot(r, ld64(b + 16)), b);
                if (!k && !keep) php_zv_cpv(php_arr_nextslot(r), b);
                taken = taken + 1;
            }
            seen = seen + 1;
        }
        i = i + 1;
    }
    return r;
}

uptr php_f_array_reverse(uptr a, uptr pres) {
    uptr r = php_arr_new(8);
    if (php_zv_type(a) != IS_ARRAY) return r;
    uptr h = ld64(a);
    i64 keep = php_zv_bool(pres);
    i64 i = php_ht_used(h) - 1;
    loop {
        if (i < 0) break;
        uptr b = php_ht_bkt(h, i);
        if (ld8(b + 8) != IS_UNDEF) {
            uptr k = ld64(b + 24);
            if (k) php_zv_cpv(php_ht_slotfor(r, php_str_hash(k), k), b);
            if (!k && keep) php_zv_cpv(php_arr_islot(r, ld64(b + 16)), b);
            if (!k && !keep) php_zv_cpv(php_arr_nextslot(r), b);
        }
        i = i - 1;
    }
    return r;
}

uptr php_f_array_sum(uptr a) {
    uptr acc = php_zlong(0);
    if (php_zv_type(a) != IS_ARRAY) return acc;
    uptr h = ld64(a);
    i64 used = php_ht_used(h);
    i64 i = 0;
    loop {
        if (i >= used) break;
        uptr b = php_ht_bkt(h, i);
        if (ld8(b + 8) != IS_UNDEF) acc = php_zv_add(acc, b);
        i = i + 1;
    }
    return acc;
}

uptr php_f_array_product(uptr a) {
    uptr acc = php_zlong(1);
    if (php_zv_type(a) != IS_ARRAY) return acc;
    uptr h = ld64(a);
    i64 used = php_ht_used(h);
    i64 i = 0;
    loop {
        if (i >= used) break;
        uptr b = php_ht_bkt(h, i);
        if (ld8(b + 8) != IS_UNDEF) acc = php_zv_mul(acc, b);
        i = i + 1;
    }
    return acc;
}

uptr php_f_array_flip(uptr a) {
    uptr r = php_arr_new(8);
    if (php_zv_type(a) != IS_ARRAY) return r;
    uptr h = ld64(a);
    i64 used = php_ht_used(h);
    i64 i = 0;
    loop {
        if (i >= used) break;
        uptr b = php_ht_bkt(h, i);
        if (ld8(b + 8) != IS_UNDEF) php_zv_cp(php_arr_zslot(r, b), php_it_key(h, i));
        i = i + 1;
    }
    return r;
}

uptr php_f_array_unique(uptr a, uptr _p2) {
    uptr r = php_arr_new(8);
    if (php_zv_type(a) != IS_ARRAY) return r;
    uptr h = ld64(a);
    i64 used = php_ht_used(h);
    i64 i = 0;
    loop {
        if (i >= used) break;
        uptr b = php_ht_bkt(h, i);
        if (ld8(b + 8) != IS_UNDEF) {
            if (php_ht_pos(r, b, 0) < 0) {
                uptr k = ld64(b + 24);
                if (k) php_zv_cpv(php_ht_slotfor(r, php_str_hash(k), k), b);
                if (!k) php_zv_cpv(php_arr_islot(r, ld64(b + 16)), b);
            }
        }
        i = i + 1;
    }
    return r;
}

uptr php_f_array_combine(uptr k, uptr v) {
    uptr r = php_arr_new(8);
    if (php_zv_type(k) != IS_ARRAY || php_zv_type(v) != IS_ARRAY) return r;
    uptr hk = ld64(k);
    uptr hv = ld64(v);
    i64 i = php_it_next(hk, 0);
    i64 j = php_it_next(hv, 0);
    loop {
        if (i < 0 || j < 0) break;
        php_zv_cpv(php_arr_zslot(r, php_ht_bkt(hk, i)), php_ht_bkt(hv, j));
        i = php_it_next(hk, i + 1);
        j = php_it_next(hv, j + 1);
    }
    return r;
}

uptr php_f_array_fill(uptr st, uptr num, uptr v) {
    uptr r = php_arr_new(8);
    i64 s = php_zv_long(st);
    i64 n = php_zv_long(num);
    i64 i = 0;
    loop { if (i >= n) break; php_zv_cpv(php_arr_islot(r, s + i), v); i = i + 1; }
    return r;
}

uptr php_f_array_fill_keys(uptr k, uptr v) {
    uptr r = php_arr_new(8);
    if (php_zv_type(k) != IS_ARRAY) return r;
    uptr h = ld64(k);
    i64 used = php_ht_used(h);
    i64 i = 0;
    loop {
        if (i >= used) break;
        uptr b = php_ht_bkt(h, i);
        if (ld8(b + 8) != IS_UNDEF) php_zv_cpv(php_arr_zslot(r, b), v);
        i = i + 1;
    }
    return r;
}

uptr php_f_array_key_first(uptr a) {
    if (php_zv_type(a) != IS_ARRAY) return php_znull();
    i64 i = php_it_next(ld64(a), 0);
    if (i < 0) return php_znull();
    return php_it_key(ld64(a), i);
}

uptr php_f_array_key_last(uptr a) {
    if (php_zv_type(a) != IS_ARRAY) return php_znull();
    i64 i = php_ht_last(ld64(a));
    if (i < 0) return php_znull();
    return php_it_key(ld64(a), i);
}

uptr php_f_range(uptr a, uptr b, uptr st) {
    uptr r = php_arr_new(8);
    i64 isf = 0;
    if (php_zv_isdouble(a) || php_zv_isdouble(b) || php_zv_isdouble(st)) isf = 1;
    // a single-character string range, php's own
    if (php_zv_type(a) == IS_STRING && php_zv_type(b) == IS_STRING && !php_zv_isnum(a) && !php_zv_isnum(b)) {
        i64 x = 0;
        i64 y = 0;
        if (php_strlen(ld64(a))) x = ld8(ld64(a) + ZS_HDR);
        if (php_strlen(ld64(b))) y = ld8(ld64(b) + ZS_HDR);
        i64 d = 1;
        if (y < x) d = -1;
        loop {
            php_arr_push(r, php_zstr(php_chr(x)));
            if (x == y) break;
            x = x + d;
        }
        return r;
    }
    if (isf) {
        f64 x = php_zv_double(a);
        f64 y = php_zv_double(b);
        f64 s = 1.0;
        if (php_zv_type(st) != IS_NULL) s = php_abs_f(php_zv_double(st));
        if (s == 0.0) s = 1.0;
        if (y < x) s = 0.0 - s;
        i64 n = (i64) (php_abs_f(y - x) / php_abs_f(s));
        i64 i = 0;
        loop { if (i > n) break; php_arr_push(r, php_zdouble(x + s * (f64) i)); i = i + 1; }
        return r;
    }
    i64 x2 = php_zv_long(a);
    i64 y2 = php_zv_long(b);
    i64 s2 = 1;
    if (php_zv_type(st) != IS_NULL) s2 = php_abs_i(php_zv_long(st));
    if (s2 == 0) s2 = 1;
    if (y2 < x2) s2 = 0 - s2;
    loop {
        php_arr_push(r, php_zlong(x2));
        if (s2 > 0 && x2 + s2 > y2) break;
        if (s2 < 0 && x2 + s2 < y2) break;
        x2 = x2 + s2;
    }
    return r;
}

// ---- sorting: an insertion sort over the bucket order, stable -------------
void php_ht_reindex(uptr h, uptr order, i64 n, i64 keepkeys) {
    uptr r = php_arr_new(ld32(h + 32));
    i64 i = 0;
    loop {
        if (i >= n) break;
        uptr b = php_ht_bkt(h, ld64(order + i * 8));
        uptr k = ld64(b + 24);
        if (keepkeys && k) php_zv_cp(php_ht_slotfor(r, php_str_hash(k), k), b);
        if (keepkeys && !k) php_zv_cp(php_arr_islot(r, ld64(b + 16)), b);
        if (!keepkeys) php_zv_cp(php_arr_nextslot(r), b);
        i = i + 1;
    }
    // move the new table into the old header, so every handle stays valid
    st32(h + 12, ld32(r + 12));
    st64(h + 16, ld64(r + 16));
    st32(h + 24, ld32(r + 24));
    st32(h + 28, ld32(r + 28));
    st32(h + 32, ld32(r + 32));
    st64(h + 40, ld64(r + 40));
}

// mode: 0 by value ascending, 1 by value descending, 2 by key ascending,
//       3 by key descending
u8 php_f_sort(uptr a, i64 mode, i64 keepkeys) {
    if (php_zv_type(a) != IS_ARRAY) return 0;
    uptr h = ld64(a);
    i64 n = php_count(h);
    uptr order = php_alloc(n * 8 + 8);
    i64 used = php_ht_used(h);
    i64 w = 0;
    i64 i = 0;
    loop {
        if (i >= used) break;
        if (ld8(php_ht_bkt(h, i) + 8) != IS_UNDEF) { st64(order + w * 8, i); w = w + 1; }
        i = i + 1;
    }
    i = 1;
    loop {
        if (i >= w) break;
        i64 cur = ld64(order + i * 8);
        i64 j = i - 1;
        loop {
            if (j < 0) break;
            i64 prev = ld64(order + j * 8);
            i64 c = 0;
            if (mode < 2) c = php_zv_cmp(php_ht_bkt(h, prev), php_ht_bkt(h, cur));
            if (mode >= 2) c = php_zv_cmp(php_it_key(h, prev), php_it_key(h, cur));
            if (mode == 1 || mode == 3) c = 0 - c;
            if (c <= 0) break;
            st64(order + (j + 1) * 8, prev);
            j = j - 1;
        }
        st64(order + (j + 1) * 8, cur);
        i = i + 1;
    }
    php_ht_reindex(h, order, w, keepkeys);
    return 1;
}

u8 php_f_sort_a(uptr a, uptr _p2) { return php_f_sort(a, 0, 0); }
u8 php_f_rsort(uptr a, uptr _p2) { return php_f_sort(a, 1, 0); }
u8 php_f_asort(uptr a, uptr _p2) { return php_f_sort(a, 0, 1); }
u8 php_f_arsort(uptr a, uptr _p2) { return php_f_sort(a, 1, 1); }
u8 php_f_ksort(uptr a, uptr _p2) { return php_f_sort(a, 2, 1); }
u8 php_f_krsort(uptr a, uptr _p2) { return php_f_sort(a, 3, 1); }

// ---- strings ---------------------------------------------------------------
i64 php_hexval(i64 c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

uptr php_f_bin2hex(uptr z) {
    uptr s = php_zv_str(z);
    i64 n = php_strlen(s);
    uptr o = php_str_alloc(n * 2);
    i64 i = 0;
    loop {
        if (i >= n) break;
        i64 c = ld8(s + ZS_HDR + i);
        st8(o + ZS_HDR + i * 2, ld8("0123456789abcdef" + ((c >> 4) & 15)));
        st8(o + ZS_HDR + i * 2 + 1, ld8("0123456789abcdef" + (c & 15)));
        i = i + 1;
    }
    return o;
}

uptr php_f_hex2bin(uptr z) {
    uptr s = php_zv_str(z);
    i64 n = php_strlen(s) / 2;
    uptr o = php_str_alloc(n);
    i64 i = 0;
    loop {
        if (i >= n) break;
        st8(o + ZS_HDR + i, php_hexval(ld8(s + ZS_HDR + i * 2)) * 16 + php_hexval(ld8(s + ZS_HDR + i * 2 + 1)));
        i = i + 1;
    }
    return o;
}

uptr php_f_base64_encode(uptr z) {
    uptr s = php_zv_str(z);
    i64 n = php_strlen(s);
    i64 ol = (n + 2) / 3 * 4;
    uptr o = php_str_alloc(ol);
    uptr t = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    i64 i = 0;
    i64 w = 0;
    loop {
        if (i >= n) break;
        i64 b0 = ld8(s + ZS_HDR + i);
        i64 b1 = 0;
        i64 b2 = 0;
        i64 have = 1;
        if (i + 1 < n) { b1 = ld8(s + ZS_HDR + i + 1); have = 2; }
        if (i + 2 < n) { b2 = ld8(s + ZS_HDR + i + 2); have = 3; }
        st8(o + ZS_HDR + w, ld8(t + (b0 >> 2)));
        st8(o + ZS_HDR + w + 1, ld8(t + (((b0 & 3) << 4) | (b1 >> 4))));
        if (have > 1) st8(o + ZS_HDR + w + 2, ld8(t + (((b1 & 15) << 2) | (b2 >> 6))));
        if (have == 1) st8(o + ZS_HDR + w + 2, '=');
        if (have > 2) st8(o + ZS_HDR + w + 3, ld8(t + (b2 & 63)));
        if (have < 3) st8(o + ZS_HDR + w + 3, '=');
        w = w + 4;
        i = i + 3;
    }
    return o;
}

i64 php_b64val(i64 c) {
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '+') return 62;
    if (c == '/') return 63;
    return -1;
}

uptr php_f_base64_decode(uptr z, uptr _p2) {
    uptr s = php_zv_str(z);
    i64 n = php_strlen(s);
    uptr o = php_str_alloc(n);
    i64 acc = 0;
    i64 bits = 0;
    i64 w = 0;
    i64 i = 0;
    loop {
        if (i >= n) break;
        i64 v = php_b64val(ld8(s + ZS_HDR + i));
        i = i + 1;
        if (v < 0) continue;
        acc = (acc << 6) | v;
        bits = bits + 6;
        if (bits >= 8) { bits = bits - 8; st8(o + ZS_HDR + w, (acc >> bits) & 255); w = w + 1; }
    }
    st64(o + 16, w);
    st8(o + ZS_HDR + w, 0);
    return o;
}

i64 php_inset(uptr set, i64 c) {
    i64 n = php_strlen(set);
    i64 i = 0;
    loop { if (i >= n) break; if (ld8(set + ZS_HDR + i) == c) return 1; i = i + 1; }
    return 0;
}

// strspn/strcspn take php's substring window (offset, length), both signs
i64 php_span_win(uptr s, uptr oz, uptr lz, uptr pb) {
    i64 n = php_strlen(s);
    i64 o = 0;
    if (oz) { if (php_zv_type(oz) != IS_NULL) o = php_zv_long(oz); }
    if (o < 0) { o = n + o; if (o < 0) o = 0; }
    if (o > n) o = n;
    i64 l = n - o;
    if (lz) { if (php_zv_type(lz) != IS_NULL) {
        l = php_zv_long(lz);
        if (l < 0) { l = n - o + l; if (l < 0) l = 0; }
        if (l > n - o) l = n - o;
    } }
    st64(pb, o);
    return l;
}

i64 php_f_strspn(uptr a, uptr b, uptr oz, uptr lz) {
    uptr s = php_zv_str(a);
    uptr set = php_zv_str(b);
    u8 ob[8];
    i64 l = php_span_win(s, oz, lz, ob);
    i64 o = ld64(ob);
    i64 i = 0;
    loop { if (i >= l) break; if (!php_inset(set, ld8(s + ZS_HDR + o + i))) break; i = i + 1; }
    return i;
}

i64 php_f_strcspn(uptr a, uptr b, uptr oz, uptr lz) {
    uptr s = php_zv_str(a);
    uptr set = php_zv_str(b);
    u8 ob[8];
    i64 l = php_span_win(s, oz, lz, ob);
    i64 o = ld64(ob);
    i64 i = 0;
    loop { if (i >= l) break; if (php_inset(set, ld8(s + ZS_HDR + o + i))) break; i = i + 1; }
    return i;
}

uptr php_f_chunk_split(uptr a, uptr lz, uptr ez) {
    uptr s = php_zv_str(a);
    i64 n = php_strlen(s);
    i64 l = 76;
    if (php_zv_type(lz) != IS_NULL) l = php_zv_long(lz);
    if (l < 1) l = 1;
    uptr e = php_str_new("\r\n", 2);
    if (php_zv_type(ez) != IS_NULL) e = php_zv_str(ez);
    i64 el = php_strlen(e);
    i64 nc = (n + l - 1) / l;
    if (n == 0) nc = 0;
    uptr o = php_str_alloc(n + nc * el);
    i64 i = 0;
    i64 w = 0;
    loop {
        if (i >= n) break;
        i64 k = l;
        if (n - i < k) k = n - i;
        php_memcpy(o + ZS_HDR + w, s + ZS_HDR + i, k);
        w = w + k;
        php_memcpy(o + ZS_HDR + w, e + ZS_HDR, el);
        w = w + el;
        i = i + l;
    }
    return o;
}

uptr php_f_substr_replace(uptr sz, uptr rz, uptr oz, uptr lz) {
    uptr s = php_zv_str(sz);
    uptr r = php_zv_str(rz);
    i64 n = php_strlen(s);
    i64 o = php_zv_long(oz);
    if (o < 0) { o = n + o; if (o < 0) o = 0; }
    if (o > n) o = n;
    i64 l = n - o;
    if (php_zv_type(lz) != IS_NULL) {
        l = php_zv_long(lz);
        if (l < 0) { l = n - o + l; if (l < 0) l = 0; }
    }
    if (o + l > n) l = n - o;
    i64 rl = php_strlen(r);
    uptr out = php_str_alloc(n - l + rl);
    php_memcpy(out + ZS_HDR, s + ZS_HDR, o);
    php_memcpy(out + ZS_HDR + o, r + ZS_HDR, rl);
    php_memcpy(out + ZS_HDR + o + rl, s + ZS_HDR + o + l, n - o - l);
    return out;
}

// php's strrpos offset: a non-negative one is where the search STARTS, a
// negative one says the match must start at or before strlen + offset
// (measured: strrpos("hello","o",-2) is false and ("hello world","o",-5) is 4)
i64 php_rpos(uptr h, uptr nd, i64 off) {
    i64 hn = php_strlen(h);
    i64 from = 0;
    i64 upto = hn;
    if (off >= 0) from = off;
    if (off < 0) {
        upto = hn + off;
        if (upto < 0) return 0 - 1;
    }
    if (from > hn) return 0 - 1;
    i64 last = 0 - 1;
    i64 i = from;
    loop {
        i64 p = php_strpos(h, nd, i);
        if (p < 0) break;
        if (p > upto) break;
        last = p;
        i = p + 1;
    }
    return last;
}

i64 php_f_strrpos(uptr hz, uptr nz, uptr oz) {
    i64 off = 0;
    if (oz) { if (php_zv_type(oz) != IS_NULL) off = php_zv_long(oz); }
    return php_rpos(php_zv_str(hz), php_zv_str(nz), off);
}

i64 php_f_stripos(uptr hz, uptr nz, uptr oz) {
    return php_strpos(php_case(php_zv_str(hz), 0), php_case(php_zv_str(nz), 0), php_zv_long(oz));
}

i64 php_f_strripos(uptr hz, uptr nz, uptr oz) {
    i64 off2 = 0;
    if (oz) { if (php_zv_type(oz) != IS_NULL) off2 = php_zv_long(oz); }
    return php_rpos(php_case(php_zv_str(hz), 0), php_case(php_zv_str(nz), 0), off2);
}

i64 php_f_strripos_old(uptr hz, uptr nz, uptr oz) {
    uptr h = php_case(php_zv_str(hz), 0);
    uptr nd = php_case(php_zv_str(nz), 0);
    i64 last = -1;
    i64 i = 0;
    loop {
        i64 p = php_strpos(h, nd, i);
        if (p < 0) break;
        last = p;
        i = p + 1;
    }
    return last;
}

uptr php_f_strstr(uptr hz, uptr nz, uptr bz) {
    uptr h = php_zv_str(hz);
    uptr nd = php_zv_str(nz);
    i64 p = php_strpos(h, nd, 0);
    if (p < 0) return php_zbool(0);
    if (php_zv_bool(bz)) return php_zstr(php_str_new(h + ZS_HDR, p));
    return php_zstr(php_str_new(h + ZS_HDR + p, php_strlen(h) - p));
}

uptr php_f_stristr(uptr hz, uptr nz, uptr bz) {
    uptr h = php_zv_str(hz);
    i64 p = php_strpos(php_case(h, 0), php_case(php_zv_str(nz), 0), 0);
    if (p < 0) return php_zbool(0);
    if (php_zv_bool(bz)) return php_zstr(php_str_new(h + ZS_HDR, p));
    return php_zstr(php_str_new(h + ZS_HDR + p, php_strlen(h) - p));
}

uptr php_f_strrchr(uptr hz, uptr nz) {
    uptr h = php_zv_str(hz);
    uptr nd = php_zv_str(nz);
    if (php_strlen(nd) == 0) return php_zbool(0);
    i64 c = ld8(nd + ZS_HDR);
    i64 n = php_strlen(h);
    i64 i = n - 1;
    loop {
        if (i < 0) return php_zbool(0);
        if (ld8(h + ZS_HDR + i) == c) break;
        i = i - 1;
    }
    return php_zstr(php_str_new(h + ZS_HDR + i, n - i));
}

i64 php_f_strncmp(uptr a, uptr b, uptr nz) {
    i64 n = php_zv_long(nz);
    uptr x = php_zv_str(a);
    uptr y = php_zv_str(b);
    if (php_strlen(x) > n) x = php_str_new(x + ZS_HDR, n);
    if (php_strlen(y) > n) y = php_str_new(y + ZS_HDR, n);
    return php_str_cmp(x, y);
}

i64 php_f_strncasecmp(uptr a, uptr b, uptr nz) {
    i64 n = php_zv_long(nz);
    uptr x = php_case(php_zv_str(a), 0);
    uptr y = php_case(php_zv_str(b), 0);
    if (php_strlen(x) > n) x = php_str_new(x + ZS_HDR, n);
    if (php_strlen(y) > n) y = php_str_new(y + ZS_HDR, n);
    return php_str_cmp(x, y);
}

uptr php_f_str_ireplace(uptr se, uptr re, uptr su) {
    uptr s = php_zv_str(se);
    uptr r = php_zv_str(re);
    uptr h = php_zv_str(su);
    i64 sl = php_strlen(s);
    if (sl == 0) return h;
    uptr lh = php_case(h, 0);
    uptr ls = php_case(s, 0);
    i64 rl = php_strlen(r);
    i64 hn = php_strlen(h);
    i64 cnt = 0;
    i64 i = 0;
    loop {
        i64 p = php_strpos(lh, ls, i);
        if (p < 0) break;
        cnt = cnt + 1;
        i = p + sl;
    }
    uptr o = php_str_alloc(hn + cnt * (rl - sl));
    i64 w = 0;
    i = 0;
    loop {
        i64 p = php_strpos(lh, ls, i);
        if (p < 0) break;
        php_memcpy(o + ZS_HDR + w, h + ZS_HDR + i, p - i);
        w = w + p - i;
        php_memcpy(o + ZS_HDR + w, r + ZS_HDR, rl);
        w = w + rl;
        i = p + sl;
    }
    php_memcpy(o + ZS_HDR + w, h + ZS_HDR + i, hn - i);
    return o;
}

uptr php_f_str_split(uptr sz, uptr lz) {
    uptr s = php_zv_str(sz);
    i64 n = php_strlen(s);
    i64 l = 1;
    if (php_zv_type(lz) != IS_NULL) l = php_zv_long(lz);
    if (l < 1) l = 1;
    uptr r = php_arr_new(8);
    i64 i = 0;
    loop {
        if (i >= n) break;
        i64 k = l;
        if (n - i < k) k = n - i;
        php_arr_push(r, php_zstr(php_str_new(s + ZS_HDR + i, k)));
        i = i + l;
    }
    // php 8.2 and later: str_split("") is the EMPTY array, not [""]
    return r;
}

uptr php_f_ucwords(uptr sz, uptr dz) {
    uptr s = php_zv_str(sz);
    i64 n = php_strlen(s);
    u8 dbuf[8];
    st8(dbuf, 32); st8(dbuf + 1, 9); st8(dbuf + 2, 13); st8(dbuf + 3, 10); st8(dbuf + 4, 12); st8(dbuf + 5, 11);
    uptr d = php_str_new(dbuf, 6);
    if (php_zv_type(dz) != IS_NULL) d = php_zv_str(dz);
    uptr o = php_str_new(s + ZS_HDR, n);
    i64 up = 1;
    i64 i = 0;
    loop {
        if (i >= n) break;
        i64 c = ld8(o + ZS_HDR + i);
        if (up && c >= 'a' && c <= 'z') st8(o + ZS_HDR + i, c - 32);
        up = php_inset(d, c);
        i = i + 1;
    }
    return o;
}

uptr php_f_nl2br(uptr sz, uptr xz) {
    uptr s = php_zv_str(sz);
    i64 n = php_strlen(s);
    uptr tag = php_str_new("<br />", 6);
    if (php_zv_type(xz) != IS_NULL && !php_zv_bool(xz)) tag = php_str_new("<br>", 4);
    i64 tl = php_strlen(tag);
    i64 cnt = 0;
    i64 i = 0;
    loop { if (i >= n) break; i64 c = ld8(s + ZS_HDR + i); if (c == 10 || c == 13) cnt = cnt + 1; i = i + 1; }
    uptr o = php_str_alloc(n + cnt * tl);
    i64 w = 0;
    i = 0;
    loop {
        if (i >= n) break;
        i64 c = ld8(s + ZS_HDR + i);
        if (c == 10 || c == 13) {
            php_memcpy(o + ZS_HDR + w, tag + ZS_HDR, tl);
            w = w + tl;
            st8(o + ZS_HDR + w, c);
            w = w + 1;
            if (i + 1 < n) {
                i64 d = ld8(s + ZS_HDR + i + 1);
                if ((c == 13 && d == 10) || (c == 10 && d == 13)) { st8(o + ZS_HDR + w, d); w = w + 1; i = i + 1; }
            }
            i = i + 1;
            continue;
        }
        st8(o + ZS_HDR + w, c);
        w = w + 1;
        i = i + 1;
    }
    st64(o + 16, w);
    st8(o + ZS_HDR + w, 0);
    return o;
}

uptr php_f_strip_tags(uptr sz, uptr _p2) {
    uptr s = php_zv_str(sz);
    i64 n = php_strlen(s);
    uptr o = php_str_alloc(n);
    i64 w = 0;
    i64 depth = 0;
    i64 i = 0;
    loop {
        if (i >= n) break;
        i64 c = ld8(s + ZS_HDR + i);
        if (c == '<') { depth = depth + 1; i = i + 1; continue; }
        if (c == '>') { if (depth) depth = depth - 1; i = i + 1; continue; }
        if (!depth) { st8(o + ZS_HDR + w, c); w = w + 1; }
        i = i + 1;
    }
    st64(o + 16, w);
    st8(o + ZS_HDR + w, 0);
    return o;
}

uptr php_f_addslashes(uptr sz) {
    uptr s = php_zv_str(sz);
    i64 n = php_strlen(s);
    uptr o = php_str_alloc(n * 2);
    i64 w = 0;
    i64 i = 0;
    loop {
        if (i >= n) break;
        i64 c = ld8(s + ZS_HDR + i);
        if (c == 39 || c == 34 || c == 92 || c == 0) { st8(o + ZS_HDR + w, 92); w = w + 1; }
        if (c == 0) { st8(o + ZS_HDR + w, '0'); w = w + 1; i = i + 1; continue; }
        st8(o + ZS_HDR + w, c);
        w = w + 1;
        i = i + 1;
    }
    st64(o + 16, w);
    st8(o + ZS_HDR + w, 0);
    return o;
}

uptr php_f_stripslashes(uptr sz) {
    uptr s = php_zv_str(sz);
    i64 n = php_strlen(s);
    uptr o = php_str_alloc(n);
    i64 w = 0;
    i64 i = 0;
    loop {
        if (i >= n) break;
        i64 c = ld8(s + ZS_HDR + i);
        if (c == 92 && i + 1 < n) {
            i = i + 1;
            i64 d = ld8(s + ZS_HDR + i);
            if (d == '0') d = 0;
            st8(o + ZS_HDR + w, d);
            w = w + 1;
            i = i + 1;
            continue;
        }
        st8(o + ZS_HDR + w, c);
        w = w + 1;
        i = i + 1;
    }
    st64(o + 16, w);
    st8(o + ZS_HDR + w, 0);
    return o;
}

uptr php_f_htmlspecialchars(uptr sz, uptr _p2, uptr _p3, uptr _p4) {
    uptr s = php_zv_str(sz);
    i64 n = php_strlen(s);
    uptr o = php_str_alloc(n * 6);
    i64 w = 0;
    i64 i = 0;
    loop {
        if (i >= n) break;
        i64 c = ld8(s + ZS_HDR + i);
        uptr rep = 0;
        i64 rl = 0;
        if (c == '&')  { rep = "&amp;"; rl = 5; }
        if (c == '<')  { rep = "&lt;"; rl = 4; }
        if (c == '>')  { rep = "&gt;"; rl = 4; }
        if (c == 34)   { rep = "&quot;"; rl = 6; }
        if (c == 39)   { rep = "&#039;"; rl = 6; }
        if (rep) { php_memcpy(o + ZS_HDR + w, rep, rl); w = w + rl; }
        if (!rep) { st8(o + ZS_HDR + w, c); w = w + 1; }
        i = i + 1;
    }
    st64(o + 16, w);
    st8(o + ZS_HDR + w, 0);
    return o;
}

uptr php_f_wordwrap(uptr sz, uptr wz, uptr bz, uptr cz) {
    uptr s = php_zv_str(sz);
    i64 n = php_strlen(s);
    i64 width = 75;
    if (php_zv_type(wz) != IS_NULL) width = php_zv_long(wz);
    uptr brk = php_str_new("\n", 1);
    if (php_zv_type(bz) != IS_NULL) brk = php_zv_str(bz);
    i64 bl = php_strlen(brk);
    i64 cut = php_zv_bool(cz);
    uptr o = php_str_alloc(n * 2 + bl * (n / 2 + 2));
    i64 w = 0;
    i64 line = 0;
    i64 lastsp = -1;
    i64 i = 0;
    loop {
        if (i >= n) break;
        i64 c = ld8(s + ZS_HDR + i);
        if (c == 10) { st8(o + ZS_HDR + w, c); w = w + 1; line = 0; lastsp = -1; i = i + 1; continue; }
        st8(o + ZS_HDR + w, c);
        if (c == 32) lastsp = w;
        w = w + 1;
        line = line + 1;
        if (line > width && lastsp >= 0) {
            i64 tail = w - lastsp - 1;
            i64 k = tail;
            loop { if (k <= 0) break; st8(o + ZS_HDR + lastsp + bl + k - 1, ld8(o + ZS_HDR + lastsp + k)); k = k - 1; }
            php_memcpy(o + ZS_HDR + lastsp, brk + ZS_HDR, bl);
            w = w + bl - 1;
            line = tail;
            lastsp = -1;
        }
        // a word longer than the width is cut at EXACTLY the width, so the
        // test is >= and not > (measured: wordwrap("...woooooooooooord.", 8))
        if (line >= width && lastsp < 0 && cut && i + 1 < n) {
            php_memcpy(o + ZS_HDR + w, brk + ZS_HDR, bl);
            w = w + bl;
            line = 0;
        }
        i = i + 1;
    }
    st64(o + 16, w);
    st8(o + ZS_HDR + w, 0);
    return o;
}

uptr php_f_strtr(uptr sz, uptr az, uptr bz) {
    uptr s = php_zv_str(sz);
    i64 n = php_strlen(s);
    if (php_zv_type(bz) == IS_NULL) {
        // strtr($s, ["from" => "to", ...]), longest match first
        if (php_zv_type(az) != IS_ARRAY) return s;
        uptr h = ld64(az);
        uptr o = php_str_alloc(n * 4 + 16);
        i64 w = 0;
        i64 i = 0;
        loop {
            if (i >= n) break;
            i64 best = -1;
            i64 bl = 0;
            i64 used = php_ht_used(h);
            i64 j = 0;
            loop {
                if (j >= used) break;
                uptr b = php_ht_bkt(h, j);
                if (ld8(b + 8) != IS_UNDEF) {
                    uptr k = ld64(b + 24);
                    uptr ks = k;
                    if (!k) ks = php_itos(ld64(b + 16));
                    i64 kl = php_strlen(ks);
                    if (kl > bl && kl > 0 && i + kl <= n) {
                        i64 m = 1;
                        i64 q = 0;
                        loop { if (q >= kl) break; if (ld8(s + ZS_HDR + i + q) != ld8(ks + ZS_HDR + q)) { m = 0; break; } q = q + 1; }
                        if (m) { best = j; bl = kl; }
                    }
                }
                j = j + 1;
            }
            if (best < 0) { st8(o + ZS_HDR + w, ld8(s + ZS_HDR + i)); w = w + 1; i = i + 1; continue; }
            uptr rv = php_zv_str(php_ht_bkt(h, best));
            php_memcpy(o + ZS_HDR + w, rv + ZS_HDR, php_strlen(rv));
            w = w + php_strlen(rv);
            i = i + bl;
        }
        st64(o + 16, w);
        st8(o + ZS_HDR + w, 0);
        return o;
    }
    uptr a = php_zv_str(az);
    uptr b = php_zv_str(bz);
    i64 m = php_strlen(a);
    if (php_strlen(b) < m) m = php_strlen(b);
    uptr o = php_str_new(s + ZS_HDR, n);
    i64 i = 0;
    loop {
        if (i >= n) break;
        i64 c = ld8(o + ZS_HDR + i);
        i64 j = 0;
        loop {
            if (j >= m) break;
            if (ld8(a + ZS_HDR + j) == c) { st8(o + ZS_HDR + i, ld8(b + ZS_HDR + j)); break; }
            j = j + 1;
        }
        i = i + 1;
    }
    return o;
}

// number_format, php's own rounding
uptr php_f_number_format(uptr nz, uptr dz, uptr pz, uptr tz) {
    f64 x = php_zv_double(nz);
    i64 dec = 0;
    if (php_zv_type(dz) != IS_NULL) dec = php_zv_long(dz);
    if (dec < 0) dec = 0;
    uptr dp = php_str_new(".", 1);
    if (php_zv_type(pz) != IS_NULL) dp = php_zv_str(pz);
    uptr ts = php_str_new(",", 1);
    if (php_zv_type(tz) != IS_NULL) ts = php_zv_str(tz);
    i64 neg = 0;
    if (x < 0.0) { neg = 1; x = 0.0 - x; }
    f64 scale = ph_pow10(dec);
    f64 r = x * scale;
    u64 iv = (u64) (r + 0.5);
    uptr digits = php_itos(iv);
    i64 dn = php_strlen(digits);
    uptr dv = digits + ZS_HDR;
    i64 ipl = dn - dec;
    uptr pad = 0;
    if (ipl <= 0) {
        uptr t2 = php_str_alloc(dec + 1);
        i64 z = 0;
        loop { if (z >= dec + 1 - dn) break; st8(t2 + ZS_HDR + z, '0'); z = z + 1; }
        php_memcpy(t2 + ZS_HDR + dec + 1 - dn, dv, dn);
        digits = t2;
        dv = digits + ZS_HDR;
        dn = dec + 1;
        ipl = 1;
    }
    i64 ngroups = (ipl - 1) / 3;
    i64 tl = php_strlen(ts);
    i64 dpl = php_strlen(dp);
    uptr o = php_str_alloc(neg + ipl + ngroups * tl + dec * 1 + dpl + 4);
    i64 w = 0;
    if (neg) { st8(o + ZS_HDR, '-'); w = 1; }
    i64 i = 0;
    loop {
        if (i >= ipl) break;
        if (i > 0 && (ipl - i) % 3 == 0) { php_memcpy(o + ZS_HDR + w, ts + ZS_HDR, tl); w = w + tl; }
        st8(o + ZS_HDR + w, ld8(dv + i));
        w = w + 1;
        i = i + 1;
    }
    if (dec > 0) {
        php_memcpy(o + ZS_HDR + w, dp + ZS_HDR, dpl);
        w = w + dpl;
        php_memcpy(o + ZS_HDR + w, dv + ipl, dec);
        w = w + dec;
    }
    st64(o + 16, w);
    st8(o + ZS_HDR + w, 0);
    return o;
}

// ---- number bases ----------------------------------------------------------
uptr php_tobase(u64 v, i64 base) {
    u8 t[70];
    i64 k = 0;
    loop {
        st8(t + k, ld8("0123456789abcdefghijklmnopqrstuvwxyz" + v % base));
        v = v / base;
        k = k + 1;
        if (v == 0) break;
    }
    uptr s = php_str_alloc(k);
    i64 i = 0;
    loop { if (i >= k) break; st8(s + ZS_HDR + i, ld8(t + k - 1 - i)); i = i + 1; }
    return s;
}

i64 php_frombase(uptr s, i64 base) {
    i64 n = php_strlen(s);
    i64 acc = 0;
    i64 i = 0;
    loop {
        if (i >= n) break;
        i64 c = ld8(s + ZS_HDR + i);
        i64 d = -1;
        if (c >= '0' && c <= '9') d = c - '0';
        if (c >= 'a' && c <= 'z') d = c - 'a' + 10;
        if (c >= 'A' && c <= 'Z') d = c - 'A' + 10;
        if (d >= 0 && d < base) acc = acc * base + d;
        i = i + 1;
    }
    return acc;
}

uptr php_f_dechex(uptr z) { return php_tobase(php_zv_long(z), 16); }
uptr php_f_decbin(uptr z) { return php_tobase(php_zv_long(z), 2); }
uptr php_f_decoct(uptr z) { return php_tobase(php_zv_long(z), 8); }
i64  php_f_hexdec(uptr z) { return php_frombase(php_zv_str(z), 16); }
i64  php_f_bindec(uptr z) { return php_frombase(php_zv_str(z), 2); }
i64  php_f_octdec(uptr z) { return php_frombase(php_zv_str(z), 8); }
uptr php_f_base_convert(uptr z, uptr f, uptr t) {
    return php_tobase(php_frombase(php_zv_str(z), php_zv_long(f)), php_zv_long(t));
}

// ---- math ------------------------------------------------------------------
f64 php_f_floor(uptr z) {
    f64 x = php_zv_double(z);
    i64 i = (i64) x;
    f64 r = (f64) i;
    if (r > x) r = r - 1.0;
    return r;
}

f64 php_f_ceil(uptr z) {
    f64 x = php_zv_double(z);
    i64 i = (i64) x;
    f64 r = (f64) i;
    if (r < x) r = r + 1.0;
    return r;
}

f64 php_f_round(uptr z, uptr pz, uptr _p3) {
    f64 x = php_zv_double(z);
    i64 p = 0;
    if (php_zv_type(pz) != IS_NULL) p = php_zv_long(pz);
    f64 s = ph_pow10(p);
    f64 y = x * s;
    f64 h = 0.5;
    if (y < 0.0) h = -0.5;
    // php rounds half away from zero, after a pre-round that kills the noise
    i64 iv = (i64) (y + h);
    f64 d = y - (f64) iv;
    if (d >= 0.5) iv = iv + 1;
    if (d <= -0.5) iv = iv - 1;
    return (f64) iv / s;
}

f64 php_f_sqrt(uptr z) {
    f64 x = php_zv_double(z);
    if (x < 0.0) return ph_unbits(0x7ff8000000000000);
    if (x == 0.0) return 0.0;
    f64 g = x;
    if (g < 1.0) g = 1.0;
    i64 i = 0;
    loop { if (i >= 60) break; g = (g + x / g) * 0.5; i = i + 1; }
    return g;
}

f64 php_f_fmod(uptr a, uptr b) {
    f64 x = php_zv_double(a);
    f64 y = php_zv_double(b);
    if (y == 0.0) return ph_unbits(0x7ff8000000000000);
    f64 q = x / y;
    i64 iq = (i64) q;
    return x - (f64) iq * y;
}

f64 php_f_exp(uptr z) {
    f64 x = php_zv_double(z);
    i64 k = (i64) (x * 1.4426950408889634);
    f64 r = x - (f64) k * 0.6931471805599453;
    f64 t = 1.0;
    f64 acc = 1.0;
    i64 i = 1;
    loop {
        if (i > 20) break;
        t = t * r / (f64) i;
        acc = acc + t;
        i = i + 1;
    }
    f64 p = 1.0;
    i64 n = k;
    if (n < 0) n = 0 - n;
    i = 0;
    loop { if (i >= n) break; p = p * 2.0; i = i + 1; }
    if (k < 0) return acc / p;
    return acc * p;
}

f64 php_f_log(uptr z, uptr bz) {
    f64 x = php_zv_double(z);
    if (x <= 0.0) { if (x == 0.0) return ph_unbits(0xfff0000000000000); return ph_unbits(0x7ff8000000000000); }
    i64 e = 0;
    loop { if (x < 2.0) break; x = x / 2.0; e = e + 1; }
    loop { if (x >= 1.0) break; x = x * 2.0; e = e - 1; }
    f64 u = (x - 1.0) / (x + 1.0);
    f64 u2 = u * u;
    f64 t = u;
    f64 acc = 0.0;
    i64 i = 0;
    loop {
        if (i > 30) break;
        acc = acc + t / (f64) (2 * i + 1);
        t = t * u2;
        i = i + 1;
    }
    f64 r = 2.0 * acc + (f64) e * 0.6931471805599453;
    if (php_zv_type(bz) == IS_NULL) return r;
    f64 b = php_zv_double(bz);
    u8 t2[16];
    stf64(t2, b);
    uptr bz2 = php_zdouble(b);
    f64 lb = php_f_log(bz2, php_znull());
    return r / lb;
}

f64 php_f_log10(uptr z) { return php_f_log(z, php_zdouble(10.0)); }

// The trigonometric family is libm's: php prints 14 significant digits and a
// hand-rolled series does not survive that comparison. libSystem/libc carries
// every one of these on all five targets mc writes for.
extern f64 sin(f64 x);
extern f64 cos(f64 x);
extern f64 tan(f64 x);
extern f64 asin(f64 x);
extern f64 acos(f64 x);
extern f64 atan(f64 x);
extern f64 atan2(f64 y, f64 x);
extern f64 sinh(f64 x);
extern f64 cosh(f64 x);
extern f64 tanh(f64 x);
extern f64 asinh(f64 x);
extern f64 acosh(f64 x);
extern f64 atanh(f64 x);
extern f64 hypot(f64 x, f64 y);
extern f64 expm1(f64 x);
extern f64 log1p(f64 x);
extern f64 log2(f64 x);

f64 php_f_sin(uptr z)   { return sin(php_zv_double(z)); }
f64 php_f_cos(uptr z)   { return cos(php_zv_double(z)); }
f64 php_f_tan(uptr z)   { return tan(php_zv_double(z)); }
f64 php_f_asin(uptr z)  { return asin(php_zv_double(z)); }
f64 php_f_acos(uptr z)  { return acos(php_zv_double(z)); }
f64 php_f_atan(uptr z)  { return atan(php_zv_double(z)); }
f64 php_f_sinh(uptr z)  { return sinh(php_zv_double(z)); }
f64 php_f_cosh(uptr z)  { return cosh(php_zv_double(z)); }
f64 php_f_tanh(uptr z)  { return tanh(php_zv_double(z)); }
f64 php_f_asinh(uptr z) { return asinh(php_zv_double(z)); }
f64 php_f_acosh(uptr z) { return acosh(php_zv_double(z)); }
f64 php_f_atanh(uptr z) { return atanh(php_zv_double(z)); }
f64 php_f_expm1(uptr z) { return expm1(php_zv_double(z)); }
f64 php_f_log1p(uptr z) { return log1p(php_zv_double(z)); }
f64 php_f_log2(uptr z)  { return log2(php_zv_double(z)); }
f64 php_f_atan2(uptr a, uptr b) { return atan2(php_zv_double(a), php_zv_double(b)); }
f64 php_f_hypot(uptr a, uptr b) { return hypot(php_zv_double(a), php_zv_double(b)); }
f64 php_f_deg2rad(uptr z) { return php_zv_double(z) * 0.017453292519943295; }
f64 php_f_rad2deg(uptr z) { return php_zv_double(z) * 57.29577951308232; }
// php's fdiv is IEEE division: no warning, and inf/nan where php has them
f64 php_f_fdiv(uptr a, uptr b) { return php_zv_double(a) / php_zv_double(b); }
f64 php_f_pi() { return 3.141592653589793; }

u8 php_f_is_nan(uptr z) { return ph_is_nan(php_zv_double(z)); }
u8 php_f_is_infinite(uptr z) { return ph_is_inf(php_zv_double(z)); }
u8 php_f_is_finite(uptr z) {
    f64 x = php_zv_double(z);
    if (ph_is_nan(x) || ph_is_inf(x)) return 0;
    return 1;
}

uptr php_f_pow(uptr a, uptr b) { return php_zv_pow(a, b); }
uptr php_f_abs(uptr z) {
    if (php_zv_isdouble(z)) return php_zdouble(php_abs_f(php_zv_double(z)));
    return php_zlong(php_abs_i(php_zv_long(z)));
}

// a deterministic generator: a binary must give the same answer twice (D7's
// sibling rule, docs/determinism.md), so there is no entropy here.
u64 ph_seed;
i64 php_f_mt_rand(uptr a, uptr b) {
    ph_seed = ph_seed * 6364136223846793005 + 1442695040888963407;
    u64 r = (ph_seed >> 33) & 2147483647;
    if (php_zv_type(a) == IS_NULL) return r;
    i64 lo = php_zv_long(a);
    i64 hi = php_zv_long(b);
    if (hi <= lo) return lo;
    return lo + (r % (hi - lo + 1));
}
void php_f_srand(uptr z, uptr _p2) { ph_seed = php_zv_long(z); }
i64 php_f_mt_getrandmax() { return 2147483647; }

// ---- type and misc ---------------------------------------------------------
uptr php_f_gettype(uptr z) {
    i64 t = php_zv_type(z);
    if (t == IS_LONG)   return php_str_new("integer", 7);
    if (t == IS_DOUBLE) return php_str_new("double", 6);
    if (t == IS_STRING) return php_str_new("string", 6);
    if (t == IS_ARRAY)  return php_str_new("array", 5);
    if (t == IS_OBJECT) return php_str_new("object", 6);
    if (t == IS_RESOURCE) return php_str_new("resource", 8);
    if (t == IS_TRUE || t == IS_FALSE) return php_str_new("boolean", 7);
    return php_str_new("NULL", 4);
}

uptr php_f_get_debug_type(uptr z) {
    i64 t = php_zv_type(z);
    if (t == IS_LONG)   return php_str_new("int", 3);
    if (t == IS_DOUBLE) return php_str_new("float", 5);
    if (t == IS_STRING) return php_str_new("string", 6);
    if (t == IS_ARRAY)  return php_str_new("array", 5);
    if (t == IS_OBJECT) return php_obj_cname(ld64(z));
    if (t == IS_RESOURCE) return php_str_new("resource (stream)", 17);
    if (t == IS_TRUE || t == IS_FALSE) return php_str_new("bool", 4);
    return php_str_new("null", 4);
}

uptr php_f_print_r(uptr z, uptr ret) {
    if (!php_zv_bool(ret)) { php_print_r(z); return php_str_new("", 0); }
    php_ob_start();
    php_print_r(z);
    return php_ob_get();
}

uptr php_f_var_export(uptr z, uptr ret) {
    if (!php_zv_bool(ret)) { php_ex_zv(z, 0); return php_str_new("", 0); }
    php_ob_start();
    php_ex_zv(z, 0);
    return php_ob_get();
}

i64 php_f_noop(uptr a) { return 0; }
uptr php_f_nullf(uptr a, uptr _p2, uptr _p3) { return php_znull(); }
u8 php_f_false1(uptr a) { return 0; }
uptr php_f_strrev_z(uptr z) { return php_strrev(php_zv_str(z)); }

// ============================================================================
// Objects: classes, interfaces, traits and enums.
//
// The class entry is built at program start by code the compiler emits, and
// every lookup is BY NAME through a registry. That is not reflection (D6): the
// name is a literal in the source, and there is no run-time type table a
// program can enumerate -- `get_class_methods` and friends stay refused.
//
// ce layout:
//    0 name     zend_string*
//    8 parent   ce*        (0 at the root)
//   16 tostr    fn         (__toString, or 0)
//   24 methods  HashTable  lowercased name -> long(fn)
//   32 statics  HashTable  name -> zval
//   40 props    HashTable  name -> the default zval, in declaration order
//   48 ifaces   HashTable  lowercased name -> true
//   56 consts   HashTable  name -> zval
//   64 flags    long       1 abstract, 2 final, 4 interface, 8 enum, 16 backed
//   72 vis      HashTable  member name -> long(vis*8 + kind), vis 0/1/2
//   80 magic    HashTable  lowercased name -> long(fn) for __get and friends
//   88 cases    HashTable  an enum's cases, name -> the case object
//   96 ro       HashTable  a readonly property's name -> its DECLARING ce
// ============================================================================
#define CE_SIZE 104

uptr php_mcall(uptr o, uptr name, uptr scope, i64 n, uptr a1, uptr a2, uptr a3, uptr a4, uptr a5, uptr a6);
uptr php_obj_get(uptr o, uptr name, uptr scope);
uptr php_enum_cases(uptr ce);
uptr php_enum_from(uptr ce, uptr v, i64 try);

uptr ph_classes;

uptr php_ce_reg() {
    if (!ph_classes) ph_classes = php_arr_new(16);
    return ph_classes;
}

// A class is keyed by the part after the LAST backslash, lowercased: this
// compiler FLATTENS namespaces (D1 resolves every include at compile time,
// so there is one program and one class table). `\PHPUnit\Framework\TestCase`
// and `TestCase` are the same class here, and two classes with the same
// base name in different namespaces would collide -- which is the cost,
// written down rather than hidden.
uptr php_clskey(uptr name) {
    i64 n = php_strlen(name);
    i64 cut = 0;
    i64 i = 0;
    loop {
        if (i >= n) break;
        if (ld8(name + ZS_HDR + i) == 92) cut = i + 1;
        i = i + 1;
    }
    if (!cut) return php_case(name, 0);
    return php_case(php_str_new(name + ZS_HDR + cut, n - cut), 0);
}

uptr php_ce_new(uptr name) {
    uptr ce = php_alloc(CE_SIZE);
    st64(ce, name);
    st64(ce + 8, 0);
    st64(ce + 16, 0);
    st64(ce + 24, php_arr_new(8));
    st64(ce + 32, php_arr_new(8));
    st64(ce + 40, php_arr_new(8));
    st64(ce + 48, php_arr_new(8));
    st64(ce + 56, php_arr_new(8));
    st64(ce + 64, 0);
    st64(ce + 72, php_arr_new(8));
    st64(ce + 80, php_arr_new(8));
    st64(ce + 88, php_arr_new(8));
    st64(ce + 96, php_arr_new(8));
    uptr lk = php_clskey(name);
    php_zv_cp(php_arr_sslot(php_ce_reg(), lk), php_zlong(ce));
    return ce;
}

uptr php_ce_find(uptr name) {
    if (!ph_classes) return 0;
    uptr b = php_ht_find(ph_classes, php_str_hash(php_clskey(name)), php_clskey(name));
    if (!b) return 0;
    return ld64(b);
}

void php_ce_extend(uptr ce, uptr pname) {
    uptr p = php_ce_find(pname);
    if (!p) {
        uptr m = php_str_concat(php_str_new("Class \"", 7), pname);
        m = php_str_concat(m, php_str_new("\" not found", 11));
        php_fatal(m);
    }
    st64(ce + 8, p);
}

// an abstract or interface method: no body, but the name is declared, which
// is what `#[\Override]` and `class_implements`-shaped questions read
void php_ce_absm(uptr ce, uptr name, i64 vis) {
    php_zv_cp(php_arr_sslot(ld64(ce + 72), php_case(name, 0)), php_zlong(vis * 8 + 1));
}

void php_ce_method(uptr ce, uptr name, i64 fn, i64 vis) {
    php_zv_cp(php_arr_sslot(ld64(ce + 24), php_case(name, 0)), php_zlong(fn));
    php_zv_cp(php_arr_sslot(ld64(ce + 72), php_case(name, 0)), php_zlong(vis * 8 + 1));
    uptr l = php_case(name, 0);
    if (php_str_eq(l, php_str_new("__tostring", 10))) st64(ce + 16, fn);
    if (php_strlen(l) > 2 && ld8(l + ZS_HDR) == 95 && ld8(l + ZS_HDR + 1) == 95)
        php_zv_cp(php_arr_sslot(ld64(ce + 80), l), php_zlong(fn));
}

// `public readonly int $x`: the name, against the class that DECLARED it --
// php names the declarer in the message even when the object is a subclass.
void php_ce_ro(uptr ce, uptr name) {
    php_zv_cp(php_arr_sslot(ld64(ce + 96), name), php_zlong(ce));
}

// the declaring ce of a readonly property, 0 when it is not one
uptr php_ro_of(uptr ce, uptr name) {
    uptr c = ce;
    loop {
        if (!c) break;
        uptr b = php_ht_find(ld64(c + 96), php_str_hash(name), name);
        if (b) return ld64(b);
        c = ld64(c + 8);
    }
    return 0;
}

// php allows exactly one write, from inside the declaring scope. `written`
// is a per-OBJECT mark its caller keeps (php_obj_set), not the value: the
// value was a proxy for it until T10, and a readonly property deliberately
// initialised to NULL could then be written a second time.
i64 php_ro_check(uptr ce, uptr name, uptr scope, i64 written) {
    uptr d = php_ro_of(ce, name);
    if (!d) return 0;
    if (d == scope && !written) return 0;
    uptr m = php_str_concat(php_str_new("Cannot modify readonly property ", 32), ld64(d));
    m = php_str_concat(m, php_str_new("::$", 3));
    m = php_str_concat(m, name);
    php_throw_str(php_str_new("Error", 5), m);
    return 1;
}

void php_ce_prop(uptr ce, uptr name, uptr def, i64 vis) {
    php_zv_cpv(php_arr_sslot(ld64(ce + 40), name), def);
    php_zv_cp(php_arr_sslot(ld64(ce + 72), name), php_zlong(vis * 8));
}

void php_ce_sprop(uptr ce, uptr name, uptr def, i64 vis) {
    php_zv_cpv(php_arr_sslot(ld64(ce + 32), name), def);
    php_zv_cp(php_arr_sslot(ld64(ce + 72), name), php_zlong(vis * 8 + 2));
}

void php_ce_const(uptr ce, uptr name, uptr v) { php_zv_cpv(php_arr_sslot(ld64(ce + 56), name), v); }
void php_ce_iface(uptr ce, uptr name) { php_zv_cp(php_arr_sslot(ld64(ce + 48), php_clskey(name)), php_zbool(1)); }
void php_ce_flag(uptr ce, i64 f) { st64(ce + 64, ld64(ce + 64) | f); }

// a trait is copied in, member by member, at class-build time
void php_ce_use(uptr ce, uptr tname) {
    uptr t = php_ce_find(tname);
    if (!t) return;
    php_ht_append_all(ld64(ce + 24), php_zarr(ld64(t + 24)));
    php_ht_append_all(ld64(ce + 40), php_zarr(ld64(t + 40)));
    php_ht_append_all(ld64(ce + 32), php_zarr(ld64(t + 32)));
    php_ht_append_all(ld64(ce + 72), php_zarr(ld64(t + 72)));
    php_ht_append_all(ld64(ce + 80), php_zarr(ld64(t + 80)));
    if (ld64(t + 16)) st64(ce + 16, ld64(t + 16));
}

// ---- lookup, walking the parent chain -------------------------------------
uptr php_ce_lookup(uptr ce, i64 tab, uptr name) {
    uptr c = ce;
    uptr k = name;
    loop {
        if (!c) return 0;
        uptr b = php_ht_find(ld64(c + tab), php_str_hash(k), k);
        if (b) return b;
        c = ld64(c + 8);
    }
    return 0;
}

uptr php_ce_owner(uptr ce, i64 tab, uptr name) {
    uptr c = ce;
    loop {
        if (!c) return 0;
        if (php_ht_find(ld64(c + tab), php_str_hash(name), name)) return c;
        c = ld64(c + 8);
    }
    return 0;
}

i64 php_ce_is(uptr ce, uptr name) {
    uptr lk = php_clskey(name);
    uptr c = ce;
    loop {
        if (!c) return 0;
        if (php_str_eq(php_clskey(ld64(c)), lk)) return 1;
        if (php_ht_find(ld64(c + 48), php_str_hash(lk), lk)) return 1;
        // an interface can extend another: its own ifaces table carries them
        c = ld64(c + 8);
    }
    return 0;
}

i64 php_instanceof(uptr z, uptr name) {
    if (php_zv_type(z) != IS_OBJECT) return 0;
    return php_ce_is(php_obj_ce(ld64(z)), name);
}

// ---- construction ----------------------------------------------------------
void php_obj_defaults(uptr o, uptr ce) {
    if (ld64(ce + 8)) php_obj_defaults(o, ld64(ce + 8));
    uptr p = ld64(ce + 40);
    uptr t = php_obj_props(o);
    i64 used = php_ht_used(p);
    i64 i = 0;
    loop {
        if (i >= used) break;
        uptr b = php_ht_bkt(p, i);
        if (ld8(b + 8) != IS_UNDEF) php_zv_cpv(php_arr_sslot(t, ld64(b + 24)), b);
        i = i + 1;
    }
}

uptr php_new_ce(uptr ce) {
    if (ld64(ce + 64) & 1) {
        uptr m = php_str_concat(php_str_new("Cannot instantiate abstract class ", 34), ld64(ce));
        php_throw_str(php_str_new("Error", 5), m);
    }
    if (ld64(ce + 64) & 4) {
        uptr m = php_str_concat(php_str_new("Cannot instantiate interface ", 29), ld64(ce));
        php_throw_str(php_str_new("Error", 5), m);
    }
    uptr o = php_obj_new(ce);
    php_obj_defaults(o, ce);
    return o;
}

uptr php_new_ce_at(uptr ce, uptr file, i64 line);

uptr php_new_at(uptr name, uptr file, i64 line) {
    uptr ce = php_ce_find(name);
    if (!ce) {
        uptr m = php_str_concat(php_str_new("Class \"", 7), name);
        m = php_str_concat(m, php_str_new("\" not found", 11));
        php_throw_str(php_str_new("Error", 5), m);
        return php_obj_new(ph_ce_stdclass);
    }
    uptr o = php_new_ce(ce);
    // php records where a throwable was CREATED, not where it was thrown
    if (php_ce_is(ce, php_str_new("Throwable", 9))) {
        php_zv_cp(php_arr_sslot(php_obj_props(o), php_str_new("file", 4)), php_zstr(file));
        php_zv_cp(php_arr_sslot(php_obj_props(o), php_str_new("line", 4)), php_zlong(line));
    }
    return o;
}

// `new static()` / `new self()`: the class ENTRY is what the compiler has,
// not a literal name
uptr php_new_ce_at(uptr ce, uptr file, i64 line) {
    if (!ce) {
        php_throw_str(php_str_new("Error", 5), php_str_new("Cannot instantiate an unknown class", 35));
        return php_obj_new(ph_ce_stdclass);
    }
    uptr o = php_new_ce(ce);
    if (php_ce_is(ce, php_str_new("Throwable", 9))) {
        php_zv_cp(php_arr_sslot(php_obj_props(o), php_str_new("file", 4)), php_zstr(file));
        php_zv_cp(php_arr_sslot(php_obj_props(o), php_str_new("line", 4)), php_zlong(line));
    }
    return o;
}

uptr php_new(uptr name) {
    uptr fn = ph_dfile;
    if (!fn) fn = "";
    return php_new_at(name, php_str_new(fn, php_cstrlen(fn)), ph_dline);
}

uptr php_clone(uptr z) {
    if (php_zv_type(z) != IS_OBJECT) return z;
    uptr o = ld64(z);
    uptr n = php_obj_new(php_obj_ce(o));
    php_dt_arm(n);
    st64(n + 24, php_arr_copy(php_obj_props(o)));
    // and the readonly marks WITH the properties: php keeps a readonly
    // property initialised across a clone and refuses the next write, and a
    // clone that started with an empty mark table accepted one.
    if (ld64(o + 32)) st64(n + 32, php_arr_copy(ld64(o + 32)));
    uptr b = php_ht_find(ld64(php_obj_ce(o) + 80), php_str_hash(php_str_new("__clone", 7)), php_str_new("__clone", 7));
    if (b) callp(ld64(b), n);
    return php_zobj(n);
}

// ---- visibility ------------------------------------------------------------
// The scope is the class entry of the code doing the access, or 0 outside a
// class. Enforced at run time and not at compile time, because a method is
// reached through the vtable: the compiler does not know the receiver's class.
i64 php_vis_ok(uptr ce, uptr name, uptr scope) {
    uptr b = php_ce_lookup(ce, 72, name);
    if (!b) return 1;
    i64 vis = ld64(b) / 8;
    if (vis == V_PUBLIC) return 1;
    if (!scope) return 0;
    if (vis == V_PRIVATE) {
        uptr owner = php_ce_owner(ce, 72, name);
        if (owner == scope) return 1;
        return 0;
    }
    if (php_ce_is(scope, ld64(ce)) || php_ce_is(ce, ld64(scope))) return 1;
    return 0;
}

// php names the visibility in the message: `Cannot access private property
// C::$p`, `Call to private method C::m() from global scope`. The word comes
// from the one table every member is in.
uptr php_vis_word(uptr ce, uptr name) {
    uptr b = php_ce_lookup(ce, 72, name);
    if (!b) return php_str_new("public", 6);
    i64 vis = ld64(b) / 8;
    if (vis == V_PRIVATE) return php_str_new("private", 7);
    if (vis == V_PROTECTED) return php_str_new("protected", 9);
    return php_str_new("public", 6);
}

void php_vis_die(uptr ce, uptr name, uptr what) {
    uptr m = php_str_concat(php_str_new("Cannot access ", 14), php_vis_word(ce, name));
    m = php_str_concat(m, php_str_new(" ", 1));
    m = php_str_concat(m, what);
    m = php_str_concat(m, php_str_new(" ", 1));
    m = php_str_concat(m, ld64(ce));
    m = php_str_concat(m, php_str_new("::$", 3));
    m = php_str_concat(m, name);
    php_throw_str(php_str_new("Error", 5), m);
}

// `Call to private method C::m() from global scope` / `from scope D`
void php_vis_mdie(uptr ce, uptr lname, uptr name, uptr scope) {
    uptr m = php_str_concat(php_str_new("Call to ", 8), php_vis_word(ce, lname));
    m = php_str_concat(m, php_str_new(" method ", 8));
    m = php_str_concat(m, ld64(ce));
    m = php_str_concat(m, php_str_new("::", 2));
    m = php_str_concat(m, name);
    m = php_str_concat(m, php_str_new("() from ", 8));
    if (!scope) m = php_str_concat(m, php_str_new("global scope", 12));
    if (scope) {
        m = php_str_concat(m, php_str_new("scope ", 6));
        m = php_str_concat(m, ld64(scope));
    }
    php_throw_str(php_str_new("Error", 5), m);
}

// ---- properties ------------------------------------------------------------
uptr php_obj_slot(uptr o, uptr name) { return php_arr_sslot(php_obj_props(o), name); }

uptr php_obj_get(uptr o, uptr name, uptr scope) {
    uptr ce = php_obj_ce(o);
    uptr b = php_ht_find(php_obj_props(o), php_str_hash(name), name);
    if (b) {
        // the check has to STOP the read: returning the bucket after raising
        // gave the caller the private value anyway
        // (docs/review-backlog.md section 2)
        if (!php_vis_ok(ce, name, scope)) {
            php_vis_die(ce, name, php_str_new("property", 8));
            return php_znull();
        }
        return b;
    }
    uptr g = php_ht_find(ld64(ce + 80), php_str_hash(php_str_new("__get", 5)), php_str_new("__get", 5));
    if (g) return callp(ld64(g), o, php_zstr(name));
    php_mreset();
    php_mc("Undefined property: ");
    php_ms(php_obj_cname(o));
    php_mc("::$");
    php_ms(name);
    php_raise_m(PHE_WARNING);
    return php_znull();
}

uptr php_obj_get_q(uptr o, uptr name, uptr scope) {
    uptr ce = php_obj_ce(o);
    uptr b = php_ht_find(php_obj_props(o), php_str_hash(name), name);
    if (b && !php_vis_ok(ce, name, scope)) return php_znull();
    if (b) return b;
    uptr g = php_ht_find(ld64(ce + 80), php_str_hash(php_str_new("__get", 5)), php_str_new("__get", 5));
    if (g) return callp(ld64(g), o, php_zstr(name));
    return php_znull();
}

void php_obj_set(uptr o, uptr name, uptr v, uptr scope) {
    uptr ce = php_obj_ce(o);
    uptr b = php_ht_find(php_obj_props(o), php_str_hash(name), name);
    if (!b) {
        uptr sfn = php_ht_find(ld64(ce + 80), php_str_hash(php_str_new("__set", 5)), php_str_new("__set", 5));
        if (sfn) { callp(ld64(sfn), o, php_zstr(name), v); return; }
    }
    if (b && !php_vis_ok(ce, name, scope)) {
        php_vis_die(ce, name, php_str_new("property", 8));
        return;
    }
    // readonly: refused from outside the declaring scope, and inside it only
    // while the property has not been written. The test used to be the
    // VALUE -- "still null means never written" -- so a readonly property
    // deliberately initialised to NULL could be written a second time and
    // php refuses that. The mark is per OBJECT now, kept in the object's
    // own property table under a key beginning with a SPACE, which no php
    // property name can be (php mangles with a NUL and this language
    // forbids one in a literal).
    if (b) {
        i64 was = 0;
        if (php_ht_find(php_obj_romarks(o), php_str_hash(name), name)) was = 1;
        if (php_ro_check(ce, name, scope, was)) return;
        if (php_ro_of(ce, name))
            php_zv_cpv(php_arr_sslot(php_obj_romarks(o), name), php_zlong(1));
    }
    php_zv_cpv(php_arr_sslot(php_obj_props(o), name), v);
}

// $o->p on a zval receiver
// the quiet read `??` and isset() make: no "Undefined property" and no
// "Attempt to read property on <type>"
uptr php_obj_get_q(uptr o, uptr name, uptr scope);

uptr php_zv_pget_q(uptr z, uptr name, uptr scope) {
    if (php_zv_type(z) != IS_OBJECT) return php_znull();
    return php_obj_get_q(ld64(z), name, scope);
}

uptr php_zv_pget(uptr z, uptr name, uptr scope) {
    if (php_zv_type(z) != IS_OBJECT) {
        // php reads a property of a non-object as null with a warning; it is
        // an Error only when the property is WRITTEN.
        php_mreset();
        php_mc("Attempt to read property \"");
        php_ms(name);
        php_mc("\" on ");
        i64 t = php_zv_type(z);
        if (t == IS_TRUE) php_mc("true");
        if (t == IS_FALSE) php_mc("false");
        if (t != IS_TRUE && t != IS_FALSE) php_ms(php_f_get_debug_type(z));
        php_raise_m(PHE_WARNING);
        return php_znull();
    }
    return php_obj_get(ld64(z), name, scope);
}

void php_zv_pset(uptr z, uptr name, uptr v, uptr scope) {
    if (php_zv_type(z) != IS_OBJECT) {
        php_throw_str(php_str_new("Error", 5), php_str_new("Attempt to assign property on a non-object", 42));
        return;
    }
    php_obj_set(ld64(z), name, v, scope);
}

// the array slot behind $o->p[k] = v
uptr php_zv_parr(uptr z, uptr name, uptr scope) {
    if (php_zv_type(z) != IS_OBJECT) return php_arr_new(8);
    uptr b = php_obj_slot(ld64(z), name);
    return php_zv_arr_w(b);
}

uptr php_obj_parr(uptr o, uptr name, uptr scope) { return php_zv_arr_w(php_obj_slot(o, name)); }

// ---- methods ---------------------------------------------------------------
// Late static binding: `static::` is the class the call was made ON, not the
// class the method was declared in. One global, saved and restored around
// every call that can change it -- an instance call binds the object's class
// and a static call binds the named one unless it FORWARDS (a `parent::` or
// `self::` from inside an instance method carries $this, and php keeps the
// caller's binding for exactly those).
uptr ph_lsb;

uptr php_lsb_or(uptr decl) { if (ph_lsb) return ph_lsb; return decl; }

// get_called_class(): the same binding, as a name. Not reflection (D6): it
// answers one question about the call in progress and enumerates nothing.
uptr php_f_called_class(uptr decl) {
    uptr ce = php_lsb_or(decl);
    if (!ce) return php_zbool(0);
    return php_zstr(ld64(ce));
}

uptr php_mcall(uptr o, uptr name, uptr scope, i64 n, uptr a1, uptr a2, uptr a3, uptr a4, uptr a5, uptr a6) {
    uptr ce = php_obj_ce(o);
    uptr lk = php_case(name, 0);
    uptr b = php_ce_lookup(ce, 24, lk);
    if (b) {
        if (!php_vis_ok(ce, lk, scope)) {
            php_vis_mdie(ce, lk, name, scope);
            return php_znull();
        }
        uptr sv = ph_lsb;
        ph_lsb = ce;
        uptr r = callp(ld64(b), o, a1, a2, a3, a4, a5, a6);
        ph_lsb = sv;
        return r;
    }
    uptr c = php_ht_find(ld64(ce + 80), php_str_hash(php_str_new("__call", 6)), php_str_new("__call", 6));
    if (c) {
        uptr args = php_arr_new(8);
        if (n > 0) php_arr_push(args, a1);
        if (n > 1) php_arr_push(args, a2);
        if (n > 2) php_arr_push(args, a3);
        if (n > 3) php_arr_push(args, a4);
        if (n > 4) php_arr_push(args, a5);
        if (n > 5) php_arr_push(args, a6);
        return callp(ld64(c), o, php_zstr(name), php_zarr(args));
    }
    uptr m2 = php_str_concat(php_str_new("Call to undefined method ", 25), ld64(ce));
    m2 = php_str_concat(m2, php_str_new("::", 2));
    m2 = php_str_concat(m2, name);
    m2 = php_str_concat(m2, php_str_new("()", 2));
    php_throw_str(php_str_new("Error", 5), m2);
    return php_znull();
}

// `?->` -- php's nullsafe operator: a null receiver answers null and the
// access does not happen (docs/review-backlog.md section 2; before this the
// operator was parsed and then dispatched like `->`). Known difference,
// written down in RESULTS.md: php SHORT-CIRCUITS the rest of the chain, so
// `$x?->a->b` with a null $x is null with no diagnostic, while here the
// second step reads a property of null and warns. Every chain whose steps
// are all `?->` -- which is what the operator is for -- is exact, because
// null propagates through each of them.
uptr php_zv_pget(uptr z, uptr name, uptr scope);

uptr php_zv_pget_ns(uptr z, uptr name, uptr scope) {
    if (php_zv_type(z) == IS_NULL) return php_znull();
    return php_zv_pget(z, name, scope);
}

uptr php_zv_mcall(uptr z, uptr name, uptr scope, i64 n, uptr a1, uptr a2, uptr a3, uptr a4, uptr a5, uptr a6);

uptr php_zv_mcall_ns(uptr z, uptr name, uptr scope, i64 n, uptr a1, uptr a2, uptr a3, uptr a4, uptr a5, uptr a6) {
    if (php_zv_type(z) == IS_NULL) return php_znull();
    return php_zv_mcall(z, name, scope, n, a1, a2, a3, a4, a5, a6);
}

uptr php_zv_mcall(uptr z, uptr name, uptr scope, i64 n, uptr a1, uptr a2, uptr a3, uptr a4, uptr a5, uptr a6) {
    if (php_zv_type(z) != IS_OBJECT) {
        uptr m = php_str_concat(php_str_new("Call to a member function ", 26), name);
        m = php_str_concat(m, php_str_new("() on ", 6));
        m = php_str_concat(m, php_f_get_debug_type(z));
        php_throw_str(php_str_new("Error", 5), m);
        return php_znull();
    }
    return php_mcall(ld64(z), name, scope, n, a1, a2, a3, a4, a5, a6);
}

// Foo::bar(): a static call, and the one that carries `parent::`
uptr php_scall(uptr ce, uptr name, uptr thisp, uptr scope, i64 n, uptr a1, uptr a2, uptr a3, uptr a4, uptr a5, uptr a6) {
    uptr lk = php_case(name, 0);
    uptr b = php_ce_lookup(ce, 24, lk);
    if (!b && (ld64(ce + 64) & 8)) {
        // an enum's three built-in static methods
        if (php_str_eq(lk, php_str_new("cases", 5))) return php_zarr(php_enum_cases(ce));
        if (php_str_eq(lk, php_str_new("from", 4))) return php_enum_from(ce, a1, 0);
        if (php_str_eq(lk, php_str_new("tryfrom", 7))) return php_enum_from(ce, a1, 1);
    }
    if (!b) {
        uptr c = php_ht_find(ld64(ce + 80), php_str_hash(php_str_new("__callstatic", 12)), php_str_new("__callstatic", 12));
        if (c) {
            uptr args = php_arr_new(8);
            if (n > 0) php_arr_push(args, a1);
            if (n > 1) php_arr_push(args, a2);
            if (n > 2) php_arr_push(args, a3);
            if (n > 3) php_arr_push(args, a4);
            return callp(ld64(c), 0, php_zstr(name), php_zarr(args));
        }
        uptr m = php_str_concat(php_str_new("Call to undefined method ", 25), ld64(ce));
        m = php_str_concat(m, php_str_new("::", 2));
        m = php_str_concat(m, name);
        m = php_str_concat(m, php_str_new("()", 2));
        php_throw_str(php_str_new("Error", 5), m);
        return php_znull();
    }
    // a static call was never checked at all (docs/review-backlog.md
    // section 2): `C::privateMethod()` from outside reached callp
    if (!php_vis_ok(ce, lk, scope)) {
        php_vis_mdie(ce, lk, name, scope);
        return php_znull();
    }
    uptr sv = ph_lsb;
    // a forwarding call (`parent::m()` from an instance method) carries
    // $this and keeps the caller's binding; a named one rebinds
    if (!thisp) ph_lsb = ce;
    uptr r = callp(ld64(b), thisp, a1, a2, a3, a4, a5, a6);
    ph_lsb = sv;
    return r;
}

uptr php_ce_byname(uptr name) {
    uptr ce = php_ce_find(name);
    if (!ce) {
        uptr m = php_str_concat(php_str_new("Class \"", 7), name);
        m = php_str_concat(m, php_str_new("\" not found", 11));
        php_throw_str(php_str_new("Error", 5), m);
    }
    return ce;
}

// a class constant, walking the parents and then the interfaces
uptr php_ce_getconst(uptr ce, uptr name) {
    uptr b = php_ce_lookup(ce, 56, name);
    if (b) return b;
    uptr ifs = ld64(ce + 48);
    i64 used = php_ht_used(ifs);
    i64 i = 0;
    loop {
        if (i >= used) break;
        uptr k = php_ht_bkt(ifs, i);
        if (ld8(k + 8) != IS_UNDEF) {
            uptr ic = php_ce_find(ld64(k + 24));
            if (ic) { uptr r = php_ce_getconst(ic, name); if (php_zv_type(r) != IS_UNDEF) return r; }
        }
        i = i + 1;
    }
    uptr m = php_str_concat(php_str_new("Undefined constant ", 19), ld64(ce));
    m = php_str_concat(m, php_str_new("::", 2));
    m = php_str_concat(m, name);
    php_throw_str(php_str_new("Error", 5), m);
    return php_znull();
}

// `#[\Override]` is not reflection: php checks it while COMPILING the class,
// so nothing enumerates a table at run time -- the compiler emits one call
// per marked member, with the member's own file and line, into the class
// setup that runs before any user statement. The check is the parent chain
// and every interface it names, which is php's own rule.
i64 php_ce_has(uptr ce, uptr lname, i64 kind) {
    uptr c = ce;
    loop {
        if (!c) break;
        // the vis table and not the method table: an ABSTRACT or interface
        // method has no function pointer and still counts as a parent's
        uptr vb = php_ht_find(ld64(c + 72), php_str_hash(lname), lname);
        if (vb) {
            i64 v = ld64(vb);
            i64 k = v - v / 8 * 8;
            i64 want = 1;
            if (kind) want = 0;
            // a static property records 2, an instance one 0
            if (kind && k == 2) k = 0;
            // a PRIVATE member of a parent is not a match: php says the
            // override has nothing to override (override/010)
            if (k == want && v / 8 != V_PRIVATE) return 1;
        }
        uptr ifs = ld64(c + 48);
        i64 used = php_ht_used(ifs);
        i64 i = 0;
        loop {
            if (i >= used) break;
            uptr k = php_ht_bkt(ifs, i);
            if (ld8(k + 8) != IS_UNDEF) {
                uptr ic = php_ce_find(ld64(k + 24));
                if (ic) { if (php_ce_has(ic, lname, kind)) return 1; }
            }
            i = i + 1;
        }
        c = ld64(c + 8);
    }
    return 0;
}

// php reports a compile-time fatal on stdout with its own file and line, and
// exits 255 (T7's road, from the runtime rather than from the compiler:
// what a parent has is only known once every class entry is built).
void php_rt_fatal_at(uptr msg, uptr file, i64 line) {
    php_write("\nFatal error: ", 14);
    php_echo_str(msg);
    php_write(" in ", 4);
    php_write(file, php_cstrlen(file));
    php_write(" on line ", 9);
    uptr d = php_itos(line);
    php_write(d + ZS_HDR, php_strlen(d));
    // php raises this one as an Error while compiling the class, so its
    // output carries the trace an uncaught Error carries (measured: the
    // .phpt EXPECTF quotes the first line, the grid compares php's OWN
    // output, and that is the whole of it).
    php_write("\nStack trace:\n#0 {main}\n", 24);
    php_flush();
    write(2, "PHP Fatal error:  ", 18);
    write(2, msg + ZS_HDR, php_strlen(msg));
    write(2, " in ", 4);
    write(2, file, php_cstrlen(file));
    write(2, " on line ", 9);
    write(2, d + ZS_HDR, php_strlen(d));
    write(2, "\nStack trace:\n#0 {main}\n", 24);
    exit(255);
}

// kind 0 a method, 1 a property. `what` is what php names: `C::m()` / `C::$p`.
void php_ce_ovr(uptr ce, uptr what, uptr name, i64 kind, uptr file, i64 line) {
    uptr par = ld64(ce + 8);
    i64 ok = 0;
    if (par) ok = php_ce_has(par, php_case(name, 0), kind);
    if (!ok) {
        // an interface the class itself names counts as a parent here
        uptr ifs = ld64(ce + 48);
        i64 used = php_ht_used(ifs);
        i64 i = 0;
        loop {
            if (i >= used) break;
            uptr k = php_ht_bkt(ifs, i);
            if (ld8(k + 8) != IS_UNDEF) {
                uptr ic = php_ce_find(ld64(k + 24));
                if (ic) { if (php_ce_has(ic, php_case(name, 0), kind)) ok = 1; }
            }
            i = i + 1;
        }
    }
    if (ok) return;
    uptr m = php_str_concat(what, php_str_new(" has #[\\Override] attribute, but no matching parent ", 52));
    if (kind) m = php_str_concat(m, php_str_new("property exists", 15));
    if (!kind) m = php_str_concat(m, php_str_new("method exists", 13));
    php_rt_fatal_at(m, file, line);
}

// A static property slot, with the caller's scope: the read and the write
// both go through it, and it had no scope at all
// (docs/review-backlog.md section 2). A refused access answers a throw-away
// slot, so the assignment that may follow writes nowhere.
uptr php_ce_sslot_s(uptr ce, uptr name, uptr scope) {
    uptr c = ce;
    loop {
        if (!c) break;
        uptr b = php_ht_find(ld64(c + 32), php_str_hash(name), name);
        if (b) {
            if (!php_vis_ok(c, name, scope)) {
                php_vis_die(c, name, php_str_new("property", 8));
                return php_zv_alloc();
            }
            return b;
        }
        c = ld64(c + 8);
    }
    return php_arr_sslot(ld64(ce + 32), name);
}

uptr php_ce_sslot(uptr ce, uptr name) { return php_ce_sslot_s(ce, name, 0); }

// ---- enums -----------------------------------------------------------------
uptr php_enum_case(uptr ce, uptr name, uptr val) {
    uptr o = php_obj_new(ce);
    php_zv_cp(php_arr_sslot(php_obj_props(o), php_str_new("name", 4)), php_zstr(name));
    if (php_zv_type(val) != IS_NULL) php_zv_cp(php_arr_sslot(php_obj_props(o), php_str_new("value", 5)), val);
    uptr z = php_zobj(o);
    php_zv_cp(php_arr_sslot(ld64(ce + 88), name), z);
    php_zv_cp(php_arr_sslot(ld64(ce + 56), name), z);
    return z;
}

uptr php_enum_cases(uptr ce) {
    uptr r = php_arr_new(8);
    php_ht_append_all(r, php_zarr(ld64(ce + 88)));
    return php_f_array_values(php_zarr(r));
}

uptr php_enum_from(uptr ce, uptr v, i64 try) {
    uptr cs = ld64(ce + 88);
    i64 used = php_ht_used(cs);
    i64 i = 0;
    loop {
        if (i >= used) break;
        uptr b = php_ht_bkt(cs, i);
        if (ld8(b + 8) != IS_UNDEF) {
            uptr cv = php_ht_find(php_obj_props(ld64(b)), php_str_hash(php_str_new("value", 5)), php_str_new("value", 5));
            if (cv && php_zv_cmp(cv, v) == 0) return b;
        }
        i = i + 1;
    }
    if (try) return php_znull();
    uptr m = php_str_concat(php_str_new("\"", 1), php_zv_str(v));
    m = php_str_concat(m, php_str_new("\" is not a valid backing value for enum ", 40));
    m = php_str_concat(m, ld64(ce));
    php_throw_str(php_str_new("ValueError", 10), m);
    return php_znull();
}

// ---- callables -------------------------------------------------------------
// A Closure is an object of the built-in class Closure whose `fn` property is
// the function pointer and whose `use` property is the bound array. D6 refuses
// the STRING form of a callable; this is the value form.
uptr ph_ce_closure;

uptr php_closure_new(i64 fn, uptr bound, uptr thisp) {
    if (!ph_ce_closure) ph_ce_closure = php_ce_new(php_str_new("Closure", 7));
    uptr o = php_obj_new(ph_ce_closure);
    php_zv_cp(php_arr_sslot(php_obj_props(o), php_str_new("fn", 2)), php_zlong(fn));
    php_zv_cp(php_arr_sslot(php_obj_props(o), php_str_new("use", 3)), php_zarr(bound));
    php_zv_cp(php_arr_sslot(php_obj_props(o), php_str_new("this", 4)), php_zlong(thisp));
    return php_zobj(o);
}

uptr php_call_zv(uptr z, i64 n, uptr a1, uptr a2, uptr a3, uptr a4, uptr a5) {
    if (php_zv_type(z) != IS_OBJECT) {
        php_throw_str(php_str_new("Error", 5), php_str_new("Value not callable", 18));
        return php_znull();
    }
    uptr o = ld64(z);
    uptr b = php_ht_find(php_obj_props(o), php_str_hash(php_str_new("fn", 2)), php_str_new("fn", 2));
    if (!b) return php_mcall(o, php_str_new("__invoke", 8), 0, n, a1, a2, a3, a4, a5, 0);
    uptr u = php_ht_find(php_obj_props(o), php_str_hash(php_str_new("use", 3)), php_str_new("use", 3));
    uptr t = php_ht_find(php_obj_props(o), php_str_hash(php_str_new("this", 4)), php_str_new("this", 4));
    uptr tp = 0;
    if (t) tp = ld64(t);
    return callp(ld64(b), ld64(u), tp, a1, a2, a3, a4, a5);
}

u8 php_f_is_callable(uptr z, uptr _p2, uptr _p3) {
    if (php_zv_type(z) != IS_OBJECT) return 0;
    uptr o = ld64(z);
    if (php_ht_find(php_obj_props(o), php_str_hash(php_str_new("fn", 2)), php_str_new("fn", 2))) return 1;
    if (php_ce_lookup(php_obj_ce(o), 24, php_str_new("__invoke", 8))) return 1;
    return 0;
}

uptr php_f_get_class(uptr z) {
    if (php_zv_type(z) != IS_OBJECT) return php_zbool(0);
    return php_zstr(php_obj_cname(ld64(z)));
}

uptr php_f_get_parent_class(uptr z) {
    if (php_zv_type(z) != IS_OBJECT) return php_zbool(0);
    uptr p = ld64(php_obj_ce(ld64(z)) + 8);
    if (!p) return php_zbool(0);
    return php_zstr(ld64(p));
}

u8 php_f_class_exists(uptr z, uptr _p2) { if (php_ce_find(php_zv_str(z))) return 1; return 0; }

u8 php_f_method_exists(uptr z, uptr m) {
    uptr ce = 0;
    if (php_zv_type(z) == IS_OBJECT) ce = php_obj_ce(ld64(z));
    if (php_zv_type(z) == IS_STRING) ce = php_ce_find(ld64(z));
    if (!ce) return 0;
    if (php_ce_lookup(ce, 24, php_case(php_zv_str(m), 0))) return 1;
    return 0;
}

u8 php_f_property_exists(uptr z, uptr m) {
    uptr ce = 0;
    if (php_zv_type(z) == IS_OBJECT) {
        if (php_ht_find(php_obj_props(ld64(z)), php_str_hash(php_zv_str(m)), php_zv_str(m))) return 1;
        ce = php_obj_ce(ld64(z));
    }
    if (php_zv_type(z) == IS_STRING) ce = php_ce_find(ld64(z));
    if (!ce) return 0;
    if (php_ce_lookup(ce, 40, php_zv_str(m))) return 1;
    return 0;
}

// the callback library, now that a callable is a value
uptr php_f_array_map(uptr f, uptr a) {
    uptr r = php_arr_new(8);
    if (php_zv_type(a) != IS_ARRAY) return r;
    uptr h = ld64(a);
    i64 used = php_ht_used(h);
    i64 i = 0;
    loop {
        if (i >= used) break;
        uptr b = php_ht_bkt(h, i);
        if (ld8(b + 8) != IS_UNDEF) {
            uptr v = b;
            if (php_zv_type(f) != IS_NULL) v = php_call_zv(f, 1, b, 0, 0, 0, 0);
            uptr k = ld64(b + 24);
            if (k) php_zv_cpv(php_ht_slotfor(r, php_str_hash(k), k), v);
            if (!k) php_zv_cpv(php_arr_islot(r, ld64(b + 16)), v);
        }
        i = i + 1;
    }
    if (php_zv_type(f) == IS_NULL) return r;
    // php renumbers when every key is an integer and there is one array
    return r;
}

uptr php_f_array_filter(uptr a, uptr f, uptr mode) {
    uptr r = php_arr_new(8);
    if (php_zv_type(a) != IS_ARRAY) return r;
    uptr h = ld64(a);
    i64 used = php_ht_used(h);
    i64 i = 0;
    loop {
        if (i >= used) break;
        uptr b = php_ht_bkt(h, i);
        if (ld8(b + 8) != IS_UNDEF) {
            i64 keep = 0;
            if (php_zv_type(f) == IS_NULL) keep = php_zv_bool(b);
            if (php_zv_type(f) != IS_NULL) {
                i64 m = php_zv_long(mode);
                if (m == 1) keep = php_zv_bool(php_call_zv(f, 1, php_it_key(h, i), 0, 0, 0, 0));
                if (m == 2) keep = php_zv_bool(php_call_zv(f, 2, b, php_it_key(h, i), 0, 0, 0));
                if (m != 1 && m != 2) keep = php_zv_bool(php_call_zv(f, 1, b, 0, 0, 0, 0));
            }
            if (keep) {
                uptr k = ld64(b + 24);
                if (k) php_zv_cpv(php_ht_slotfor(r, php_str_hash(k), k), b);
                if (!k) php_zv_cpv(php_arr_islot(r, ld64(b + 16)), b);
            }
        }
        i = i + 1;
    }
    return r;
}

uptr php_f_array_reduce(uptr a, uptr f, uptr init) {
    uptr acc = init;
    if (php_zv_type(a) != IS_ARRAY) return acc;
    uptr h = ld64(a);
    i64 used = php_ht_used(h);
    i64 i = 0;
    loop {
        if (i >= used) break;
        uptr b = php_ht_bkt(h, i);
        if (ld8(b + 8) != IS_UNDEF) acc = php_call_zv(f, 2, acc, b, 0, 0, 0);
        i = i + 1;
    }
    return acc;
}

// usort and friends: the same insertion sort, with the comparison delegated
u8 php_f_usort(uptr a, uptr f, i64 bykey, i64 keepkeys) {
    if (php_zv_type(a) != IS_ARRAY) return 0;
    uptr h = ld64(a);
    i64 n = php_count(h);
    uptr order = php_alloc(n * 8 + 8);
    i64 used = php_ht_used(h);
    i64 w = 0;
    i64 i = 0;
    loop {
        if (i >= used) break;
        if (ld8(php_ht_bkt(h, i) + 8) != IS_UNDEF) { st64(order + w * 8, i); w = w + 1; }
        i = i + 1;
    }
    i = 1;
    loop {
        if (i >= w) break;
        i64 cur = ld64(order + i * 8);
        i64 j = i - 1;
        loop {
            if (j < 0) break;
            i64 prev = ld64(order + j * 8);
            uptr x = php_ht_bkt(h, prev);
            uptr y = php_ht_bkt(h, cur);
            if (bykey) { x = php_it_key(h, prev); y = php_it_key(h, cur); }
            if (php_zv_long(php_call_zv(f, 2, x, y, 0, 0, 0)) <= 0) break;
            st64(order + (j + 1) * 8, prev);
            j = j - 1;
        }
        st64(order + (j + 1) * 8, cur);
        i = i + 1;
    }
    php_ht_reindex(h, order, w, keepkeys);
    return 1;
}

u8 php_f_usort_a(uptr a, uptr f) { return php_f_usort(a, f, 0, 0); }
u8 php_f_uasort(uptr a, uptr f) { return php_f_usort(a, f, 0, 1); }
u8 php_f_uksort(uptr a, uptr f) { return php_f_usort(a, f, 1, 1); }

uptr php_ce_parent(uptr ce) {
    uptr p = ld64(ce + 8);
    if (!p) { php_throw_str(php_str_new("Error", 5), php_str_new("Cannot use \"parent\" when current class scope has no parent", 58)); return ce; }
    return p;
}

// ---- a declared parameter type is CHECKED and COERCED ---------------------
// A method's parameter type was skipped over and the parameter bound as a
// plain zval, so `function m(int $x)` took anything at all
// (docs/review-backlog.md section 2). php's non-strict rules, and php's own
// TypeError text -- which names the CALLER's position, and the runtime has
// it in the two globals every diagnostic uses.
#define PC_INT    1
#define PC_FLOAT  2
#define PC_STRING 3
#define PC_BOOL   4
#define PC_ARRAY  5

uptr php_pc_name(i64 want) {
    if (want == PC_INT)    return php_str_new("int", 3);
    if (want == PC_FLOAT)  return php_str_new("float", 5);
    if (want == PC_STRING) return php_str_new("string", 6);
    if (want == PC_BOOL)   return php_str_new("bool", 4);
    return php_str_new("array", 5);
}

uptr php_param_err(uptr z, i64 want, uptr cls, uptr fn, i64 argno, uptr argname) {
    uptr m = php_str_new("", 0);
    if (php_strlen(cls)) {
        m = php_str_concat(m, cls);
        m = php_str_concat(m, php_str_new("::", 2));
    }
    m = php_str_concat(m, fn);
    // argno 0 is the RETURN value: the same rules, php's other sentence
    if (!argno) {
        m = php_str_concat(m, php_str_new("(): Return value must be of type ", 33));
        m = php_str_concat(m, php_pc_name(want));
        m = php_str_concat(m, php_str_new(", ", 2));
        m = php_str_concat(m, php_f_get_debug_type(z));
        m = php_str_concat(m, php_str_new(" returned", 9));
        php_throw_str(php_str_new("TypeError", 9), m);
        return php_znull();
    }
    m = php_str_concat(m, php_str_new("(): Argument #", 14));
    m = php_str_concat(m, php_itos(argno));
    // php names the parameter -- `Argument #1 ($x)` -- except on a variadic,
    // where the argument has no parameter of its own. An empty name is how
    // the caller says so.
    if (php_strlen(argname)) {
        m = php_str_concat(m, php_str_new(" ($", 3));
        m = php_str_concat(m, argname);
        m = php_str_concat(m, php_str_new(")", 1));
    }
    m = php_str_concat(m, php_str_new(" must be of type ", 17));
    m = php_str_concat(m, php_pc_name(want));
    m = php_str_concat(m, php_str_new(", ", 2));
    m = php_str_concat(m, php_f_get_debug_type(z));
    m = php_str_concat(m, php_str_new(" given, called in ", 18));
    m = php_str_concat(m, php_str_new(ph_dfile, php_cstrlen(ph_dfile)));
    m = php_str_concat(m, php_str_new(" on line ", 9));
    m = php_str_concat(m, php_itos(ph_dline));
    php_throw_str(php_str_new("TypeError", 9), m);
    return php_znull();
}

uptr php_param_coerce(uptr z, i64 want, uptr cls, uptr fn, i64 argno, uptr argname) {
    if (!z) return z;                          // not passed: the default fills it
    // a whole argument list is checked before its call, with ONE check after
    // it: once something is pending the rest must not overwrite it, because
    // php reports the FIRST argument it refused
    if (ph_exc) return z;
    i64 t = php_zv_type(z);
    if (want == PC_ARRAY) {
        if (t == IS_ARRAY) return z;
        return php_param_err(z, want, cls, fn, argno, argname);
    }
    if (t == IS_ARRAY || t == IS_NULL || t == IS_UNDEF)
        return php_param_err(z, want, cls, fn, argno, argname);
    if (want == PC_INT) {
        if (t == IS_LONG) return z;
        if (t == IS_OBJECT) return php_param_err(z, want, cls, fn, argno, argname);
        if (t == IS_STRING) {
            u8 lb[8];
            u8 db[8];
            if (!php_str_isnum(ld64(z), lb, db))
                return php_param_err(z, want, cls, fn, argno, argname);
        }
        return php_zlong(php_zv_ilong(z));
    }
    if (want == PC_FLOAT) {
        if (t == IS_DOUBLE) return z;
        if (t == IS_OBJECT) return php_param_err(z, want, cls, fn, argno, argname);
        if (t == IS_STRING) {
            u8 lb2[8];
            u8 db2[8];
            if (!php_str_isnum(ld64(z), lb2, db2))
                return php_param_err(z, want, cls, fn, argno, argname);
        }
        return php_zdouble(php_zv_double(z));
    }
    if (want == PC_STRING) {
        if (t == IS_STRING) return z;
        if (t == IS_OBJECT) {
            if (!php_ce_lookup(php_obj_ce(ld64(z)), 24, php_str_new("__tostring", 10)))
                return php_param_err(z, want, cls, fn, argno, argname);
            return php_zstr(php_obj_tostr(ld64(z)));
        }
        return php_zstr(php_zv_str(z));
    }
    if (t == IS_OBJECT) return php_param_err(z, want, cls, fn, argno, argname);
    return php_zbool(php_zv_bool(z));
}

// The same check for a BY-REFERENCE parameter. php coerces the caller's own
// variable -- `f(int &$x)` with "5" leaves 6 behind, not '5' -- so the
// coerced value is stored back into the SAME cell and that cell is what the
// callee keeps: returning the new zval would have silently broken the alias.
uptr php_param_coerce_ref(uptr z, i64 want, uptr cls, uptr fn, i64 argno, uptr argname) {
    uptr c = php_param_coerce(z, want, cls, fn, argno, argname);
    if (!z || c == z) return z;
    // a FAILED coercion raised and answered null, and storing that wrote
    // null into the caller's own variable on the way out: php leaves it
    // exactly as it was. Measured -- `m(int &$x)` with an array printed
    // `NULL` here and `array(0) {}` there.
    if (ph_exc) return z;
    return php_zv_store(z, c);
}

void php_argcount(uptr cls, uptr fn) {
    uptr m = php_str_concat(php_str_new("Too few arguments to function ", 30), cls);
    m = php_str_concat(m, php_str_new("::", 2));
    m = php_str_concat(m, fn);
    m = php_str_concat(m, php_str_new("()", 2));
    php_throw_str(php_str_new("ArgumentCountError", 18), m);
}

uptr php_ce_name(uptr ce) { return ld64(ce); }

// php does not destruct an object whose CONSTRUCTOR threw: it was never
// fully created. php_obj_new registers every candidate, so a throwing
// constructor takes it back off the list -- measured, five Zend/tests said so
// (Zend/tests/try/catch_002 expects `Caught` and nothing else).
uptr php_ctor(uptr o, uptr name, uptr scope, i64 n, uptr a1, uptr a2, uptr a3, uptr a4, uptr a5, uptr a6) {
    uptr ce = php_obj_ce(o);
    if (!php_ce_lookup(ce, 24, php_str_new("__construct", 11))) { php_dt_arm(o); return php_znull(); }
    uptr r = php_mcall(o, name, scope, n, a1, a2, a3, a4, a5, a6);
    if (!ph_exc) php_dt_arm(o);
    return r;
}

uptr php_ctor0(uptr o) {
    uptr ce = php_obj_ce(o);
    if (!php_ce_lookup(ce, 24, php_str_new("__construct", 11))) { php_dt_arm(o); return php_znull(); }
    uptr r = php_mcall(o, php_str_new("__construct", 11), 0, 0, 0, 0, 0, 0, 0, 0);
    if (!ph_exc) php_dt_arm(o);
    return r;
}

uptr php_zv_store(uptr slot, uptr v) { php_zv_cpv(slot, v); return slot; }

i64 php_f_obj_id(uptr z) { if (php_zv_type(z) != IS_OBJECT) return 0; return php_obj_id(ld64(z)); }

// php's spl_object_hash() is a 32-character hex STRING, not the id
// (docs/review-backlog.md section 2). The id is what varies, in the low half,
// which is php's own layout for it.
uptr php_f_spl_object_hash(uptr z) {
    i64 id = php_f_obj_id(z);
    uptr s = php_str_alloc(32);
    uptr p = php_str_val(s);
    i64 i = 0;
    loop {
        if (i >= 32) break;
        st8(p + i, 48);
        i = i + 1;
    }
    i64 k = 31;
    i64 v = id;
    loop {
        if (k < 16) break;
        i64 d = v % 16;
        if (d < 10) st8(p + k, 48 + d);
        if (d >= 10) st8(p + k, 87 + d);
        v = v / 16;
        k = k - 1;
    }
    return s;
}

// ============================================================================
// Exceptions.
//
// There is no VM and no setjmp: mc's five targets include a bare board with no
// libc, and a per-architecture setjmp written in #opcode would be five copies
// of the hardest code in the runtime. So unwinding is a PENDING-EXCEPTION FLAG
// that the compiler checks after every statement that can throw, and a throw
// returns from the function it is in. RESULTS.md measures what the check costs
// against the alternative.
//
// The consequence, named and not hidden: a side effect between the throwing
// call and the end of the same STATEMENT still happens -- `f(g(), h())` runs
// h() even when g() threw. The value is then discarded, because the check
// fires before the next statement.
// ============================================================================
uptr ph_exc;                                  // the pending throwable, 0 = none
uptr ph_ce_stdclass;

i64 php_thrown() { if (ph_exc) return 1; return 0; }
uptr php_exc_get() { return ph_exc; }
void php_exc_clear() { ph_exc = 0; }

uptr php_throw(uptr z) {
    if (php_zv_type(z) != IS_OBJECT) {
        uptr m = php_str_new("Can only throw objects", 22);
        ph_exc = 0;
        php_throw_str(php_str_new("Error", 5), m);
        return php_znull();
    }
    ph_exc = z;
    return php_znull();
}

uptr php_exm_get(uptr o, uptr k) {
    uptr b = php_ht_find(php_obj_props(o), php_str_hash(k), k);
    if (!b) return php_znull();
    return b;
}

uptr php_exm_message(uptr o) { return php_exm_get(o, php_str_new("message", 7)); }
uptr php_exm_code(uptr o) { return php_exm_get(o, php_str_new("code", 4)); }
uptr php_exm_file(uptr o) { return php_exm_get(o, php_str_new("file", 4)); }
uptr php_exm_line(uptr o) { return php_exm_get(o, php_str_new("line", 4)); }
uptr php_exm_prev(uptr o) { return php_exm_get(o, php_str_new("previous", 8)); }
uptr php_exm_trace(uptr o) { return php_zstr(php_str_new("#0 {main}", 9)); }
uptr php_exm_tracearr(uptr o) { return php_zarr(php_arr_new(8)); }

uptr php_exm_ctor(uptr o, uptr msg, uptr code, uptr prev) {
    if (msg) php_zv_cpv(php_arr_sslot(php_obj_props(o), php_str_new("message", 7)), msg);
    if (code) php_zv_cpv(php_arr_sslot(php_obj_props(o), php_str_new("code", 4)), code);
    if (prev) php_zv_cpv(php_arr_sslot(php_obj_props(o), php_str_new("previous", 8)), prev);
    return php_znull();
}

uptr php_exm_tostring(uptr o) {
    uptr s = php_obj_cname(o);
    s = php_str_concat(s, php_str_new(": ", 2));
    s = php_str_concat(s, php_zv_str(php_exm_message(o)));
    return php_zstr(s);
}

void php_ex_members(uptr ce) {
    php_ce_prop(ce, php_str_new("message", 7), php_zstr(php_str_new("", 0)), V_PROTECTED);
    php_ce_prop(ce, php_str_new("code", 4), php_zlong(0), V_PROTECTED);
    php_ce_prop(ce, php_str_new("file", 4), php_zstr(php_str_new("", 0)), V_PROTECTED);
    php_ce_prop(ce, php_str_new("line", 4), php_zlong(0), V_PROTECTED);
    php_ce_prop(ce, php_str_new("previous", 8), php_znull(), V_PRIVATE);
    php_ce_method(ce, php_str_new("__construct", 11), &php_exm_ctor, V_PUBLIC);
    php_ce_method(ce, php_str_new("getMessage", 10), &php_exm_message, V_PUBLIC);
    php_ce_method(ce, php_str_new("getCode", 7), &php_exm_code, V_PUBLIC);
    php_ce_method(ce, php_str_new("getFile", 7), &php_exm_file, V_PUBLIC);
    php_ce_method(ce, php_str_new("getLine", 7), &php_exm_line, V_PUBLIC);
    php_ce_method(ce, php_str_new("getPrevious", 11), &php_exm_prev, V_PUBLIC);
    php_ce_method(ce, php_str_new("getTraceAsString", 16), &php_exm_trace, V_PUBLIC);
    php_ce_method(ce, php_str_new("getTrace", 8), &php_exm_tracearr, V_PUBLIC);
    php_ce_method(ce, php_str_new("__toString", 10), &php_exm_tostring, V_PUBLIC);
    php_ce_iface(ce, php_str_new("Throwable", 9));
    php_ce_iface(ce, php_str_new("Stringable", 10));
}

uptr php_sub(uptr name, i64 n, uptr parent) {
    uptr ce = php_ce_new(php_str_new(name, n));
    st64(ce + 8, parent);
    return ce;
}

i64 ph_boot_done;

void php_bootstrap() {
    if (ph_boot_done) return;
    ph_boot_done = 1;
    // the phpt runner's INI, which is php-src's run-tests.php own default set:
    // error_reporting=E_ALL (30719 on 8.5), display_errors=1, log_errors=0.
    // A plain `php file.php` has log_errors=On, which is why the stderr form
    // exists at all; probes/t8/g/*.php compare both streams.
    ph_erep = 30719;
    ph_disp = 1;
    ph_log = 1;
    php_ce_flag(php_ce_new(php_str_new("Throwable", 9)), 4);
    php_ce_flag(php_ce_new(php_str_new("Stringable", 10)), 4);
    php_ce_flag(php_ce_new(php_str_new("Countable", 9)), 4);
    php_ce_flag(php_ce_new(php_str_new("Iterator", 8)), 4);
    php_ce_flag(php_ce_new(php_str_new("IteratorAggregate", 17)), 4);
    php_ce_flag(php_ce_new(php_str_new("Traversable", 11)), 4);
    php_ce_flag(php_ce_new(php_str_new("ArrayAccess", 11)), 4);
    php_ce_flag(php_ce_new(php_str_new("JsonSerializable", 16)), 4);
    php_ce_flag(php_ce_new(php_str_new("UnitEnum", 8)), 4);
    php_ce_flag(php_ce_new(php_str_new("BackedEnum", 10)), 4);
    ph_ce_stdclass = php_ce_new(php_str_new("stdClass", 8));

    uptr e = php_ce_new(php_str_new("Exception", 9));
    php_ex_members(e);
    uptr er = php_ce_new(php_str_new("Error", 5));
    php_ex_members(er);

    uptr te = php_sub("TypeError", 9, er);
    php_sub("ValueError", 10, er);
    uptr ae = php_sub("ArithmeticError", 15, er);
    php_sub("DivisionByZeroError", 19, ae);
    php_sub("ArgumentCountError", 18, te);
    php_sub("AssertionError", 14, er);
    php_sub("UnhandledMatchError", 19, er);

    uptr le = php_sub("LogicException", 14, e);
    uptr re = php_sub("RuntimeException", 16, e);
    uptr ia = php_sub("InvalidArgumentException", 24, le);
    php_sub("DomainException", 15, le);
    php_sub("LengthException", 15, le);
    php_sub("OutOfRangeException", 19, le);
    php_sub("BadFunctionCallException", 24, le);
    php_sub("BadMethodCallException", 22, le);
    php_sub("OutOfBoundsException", 20, re);
    php_sub("OverflowException", 17, re);
    php_sub("RangeException", 14, re);
    php_sub("UnderflowException", 18, re);
    php_sub("UnexpectedValueException", 24, re);
    php_sub("JsonException", 13, e);
    php_sub("ErrorException", 14, e);
}

// an uncaught throwable, in php's own words
void php_uncaught() {
    if (!ph_exc) return;
    // set_exception_handler(): php hands an uncaught throwable to it and
    // exits 255 afterwards, with none of the Fatal error text
    if (ph_xhz) {
        uptr hz = ph_xhz;
        ph_xhz = 0;
        uptr z = ph_exc;
        ph_exc = 0;
        php_call_zv(hz, 1, z, 0, 0, 0, 0);
        // measured on php 8.5.10: a handled uncaught exception exits 0
        if (!ph_exc) { php_shutdown(); php_flush(); exit(0); }
    }
    uptr o = ld64(ph_exc);
    uptr s = php_str_concat(php_str_new("Uncaught ", 9), php_obj_cname(o));
    uptr m = php_zv_str(php_exm_message(o));
    if (php_strlen(m)) {
        s = php_str_concat(s, php_str_new(": ", 2));
        s = php_str_concat(s, m);
    }
    uptr f = php_zv_str(php_exm_file(o));
    i64 ln = php_zv_long(php_exm_line(o));
    s = php_str_concat(s, php_str_new(" in ", 4));
    s = php_str_concat(s, f);
    s = php_str_concat(s, php_str_new(":", 1));
    s = php_str_concat(s, php_itos(ln));
    s = php_str_concat(s, php_str_new("\nStack trace:\n#0 {main}\n  thrown in ", 36));
    s = php_str_concat(s, f);
    s = php_str_concat(s, php_str_new(" on line ", 9));
    s = php_str_concat(s, php_itos(ln));
    ph_exc = 0;
    php_fatal(s);
}

// the runtime's own throws, now that the hierarchy exists
i64 php_throw_cls(uptr cls, uptr msg) {
    php_bootstrap();
    uptr ce = php_ce_find(cls);
    if (!ce) ce = php_ce_find(php_str_new("Error", 5));
    uptr o = php_obj_new(ce);
    php_obj_defaults(o, ce);
    php_zv_cpv(php_arr_sslot(php_obj_props(o), php_str_new("message", 7)), php_zstr(msg));
    // a throwable the RUNTIME raises is created where the program is, which
    // is the position the compiler last announced (php_pos).
    uptr fn = ph_dfile;
    if (!fn) fn = "";
    php_zv_cp(php_arr_sslot(php_obj_props(o), php_str_new("file", 4)),
              php_zstr(php_str_new(fn, php_cstrlen(fn))));
    php_zv_cp(php_arr_sslot(php_obj_props(o), php_str_new("line", 4)), php_zlong(ph_dline));
    ph_exc = php_zobj(o);
    return 0;
}

// does the pending throwable match this catch clause?
uptr php_unhandled_match(uptr z) {
    uptr m = php_str_concat(php_str_new("Unhandled match case ", 21), php_zv_str(z));
    php_throw_cls(php_str_new("UnhandledMatchError", 19), m);
    return php_znull();
}

i64 php_catches(uptr name) {
    if (!ph_exc) return 0;
    return php_instanceof(ph_exc, name);
}

uptr php_catch_take() {
    uptr z = ph_exc;
    ph_exc = 0;
    if (!z) return php_znull();
    return z;
}

f64 php_nan(i64 ignored) { return ph_unbits(0x7ff8000000000000); }
f64 php_inf(i64 ignored) { return ph_unbits(0x7ff0000000000000); }

// ---- the global variable table --------------------------------------------
// `global $x` and a top-level variable a function reaches through it share
// ONE zval, allocated once and never moved -- the hash stores the pointer, so
// a rehash cannot invalidate an alias.
uptr ph_globals;

uptr php_gvar(uptr name) {
    if (!ph_globals) ph_globals = php_arr_new(16);
    uptr b = php_ht_find(ph_globals, php_str_hash(name), name);
    if (b) return ld64(b);
    uptr z = php_znull();
    php_zv_cp(php_arr_sslot(ph_globals, name), php_zlong(z));
    return z;
}

// a function `static`: one zval per declaration, initialised on the first call
uptr php_static(uptr slot, uptr init) {
    uptr z = ld64(slot);
    if (z) return z;
    z = php_zv_val(init);
    st64(slot, z);
    return z;
}

// ---- named runtime constants ----------------------------------------------
uptr ph_consts;

void php_const_set(uptr name, uptr v) {
    if (!ph_consts) ph_consts = php_arr_new(16);
    php_zv_cpv(php_arr_sslot(ph_consts, name), v);
}

uptr php_const_get(uptr name) {
    if (!ph_consts) ph_consts = php_arr_new(16);
    uptr b = php_ht_find(ph_consts, php_str_hash(name), name);
    if (b) return b;
    uptr m = php_str_concat(php_str_new("Undefined constant \"", 20), name);
    m = php_str_concat(m, php_str_new("\"", 1));
    php_throw_cls(php_str_new("Error", 5), m);
    return php_znull();
}

u8 php_f_defined(uptr z) {
    if (!ph_consts) return 0;
    uptr n = php_zv_str(z);
    if (php_ht_find(ph_consts, php_str_hash(n), n)) return 1;
    return 0;
}

uptr php_f_constant(uptr z) { return php_const_get(php_zv_str(z)); }
u8 php_f_define(uptr n, uptr v) { php_const_set(php_zv_str(n), v); return 1; }

// ---- sprintf's conversions -------------------------------------------------
// The FORMAT is a literal (D1), so the compiler walks it and emits one call
// per conversion; this is the conversion itself. flags: 1 left, 2 plus,
// 4 space, 8 zero-pad.
#define SPF_LEFT  1
#define SPF_PLUS  2
#define SPF_SPACE 4
#define SPF_ZERO  8

uptr php_spf_pad(uptr s, i64 flags, i64 width, i64 pad) {
    i64 n = php_strlen(s);
    if (width <= n) return s;
    uptr o = php_str_alloc(width);
    i64 k = width - n;
    if (flags & SPF_LEFT) {
        php_memcpy(o + ZS_HDR, s + ZS_HDR, n);
        i64 i = 0;
        loop { if (i >= k) break; st8(o + ZS_HDR + n + i, 32); i = i + 1; }
        return o;
    }
    // a zero pad goes AFTER the sign
    i64 skip = 0;
    if (pad == 48 && n > 0) {
        i64 c0 = ld8(s + ZS_HDR);
        if (c0 == 45 || c0 == 43) skip = 1;
    }
    if (skip) st8(o + ZS_HDR, ld8(s + ZS_HDR));
    i64 i2 = 0;
    loop { if (i2 >= k) break; st8(o + ZS_HDR + skip + i2, pad); i2 = i2 + 1; }
    php_memcpy(o + ZS_HDR + skip + k, s + ZS_HDR + skip, n - skip);
    return o;
}

uptr php_spf_sign(uptr s, i64 flags, i64 neg) {
    if (neg) return s;
    if (flags & SPF_PLUS) return php_str_concat(php_str_new("+", 1), s);
    if (flags & SPF_SPACE) return php_str_concat(php_str_new(" ", 1), s);
    return s;
}

// %e / %E, php's own: one digit, the point, `prec` digits, e+NN
uptr php_spf_e(f64 x, i64 prec, i64 up) {
    i64 neg = 0;
    if ((ph_bits(x) >> 63) != 0) { neg = 1; x = 0.0 - x; }
    if (ph_is_nan(x)) return php_str_new("NAN", 3);
    if (ph_is_inf(x)) { if (neg) return php_str_new("-INF", 4); return php_str_new("INF", 3); }
    u8 pe[8];
    i64 d = 0;
    i64 e = 0;
    if (x != 0.0) { d = ph_digits(x, prec + 1, pe); e = ld64(pe) + prec; }
    u8 t[64];
    i64 k = 0;
    u8 dg[32];
    i64 nd = 0;
    i64 u = d;
    loop { st8(dg + nd, 48 + u % 10); u = u / 10; nd = nd + 1; if (u == 0) break; }
    loop { if (nd >= prec + 1) break; st8(dg + nd, 48); nd = nd + 1; }
    if (neg) { st8(t + k, 45); k = k + 1; }
    st8(t + k, ld8(dg + nd - 1));
    k = k + 1;
    if (prec > 0) {
        st8(t + k, 46);
        k = k + 1;
        i64 i = 1;
        loop { if (i > prec) break; st8(t + k, ld8(dg + nd - 1 - i)); k = k + 1; i = i + 1; }
    }
    st8(t + k, 101);
    if (up) st8(t + k, 69);
    k = k + 1;
    if (e < 0) { st8(t + k, 45); e = 0 - e; } else { st8(t + k, 43); }
    k = k + 1;
    uptr es = php_itos(e);
    if (php_strlen(es) < 1) es = php_str_new("0", 1);
    php_memcpy(t + k, es + ZS_HDR, php_strlen(es));
    k = k + php_strlen(es);
    return php_str_new(t, k);
}

// %f, with an explicit precision
uptr php_spf_f(f64 x, i64 prec) {
    if (ph_is_nan(x)) return php_str_new("NAN", 3);
    if (ph_is_inf(x)) { if (x < 0.0) return php_str_new("-INF", 4); return php_str_new("INF", 3); }
    i64 neg = 0;
    if ((ph_bits(x) >> 63) != 0) { neg = 1; x = 0.0 - x; }
    f64 sc = ph_pow10(prec);
    f64 r = x * sc;
    // the integer part can exceed i64; fall back to the shortest form there
    if (r >= 9.2233720368547758e18) return php_ftos(x);
    // printf rounds half to EVEN, like the C library php calls: 2.25 with one
    // decimal is 2.2 and not 2.3
    u64 iv = (u64) r;
    f64 fr = r - (f64) iv;
    if (fr > 0.5) iv = iv + 1;
    if (fr == 0.5) { if (iv & 1) iv = iv + 1; }
    uptr ds = php_itos(iv);
    i64 dn = php_strlen(ds);
    uptr dv = ds + ZS_HDR;
    i64 ip = dn - prec;
    uptr o = php_str_alloc(neg + prec + 2 + dn);
    i64 w = 0;
    if (neg) { st8(o + ZS_HDR, 45); w = 1; }
    if (ip <= 0) {
        st8(o + ZS_HDR + w, 48);
        w = w + 1;
    }
    i64 i = 0;
    loop { if (i >= ip) break; st8(o + ZS_HDR + w, ld8(dv + i)); w = w + 1; i = i + 1; }
    if (prec > 0) {
        st8(o + ZS_HDR + w, 46);
        w = w + 1;
        i64 z = 0;
        loop { if (z >= 0 - ip) break; st8(o + ZS_HDR + w, 48); w = w + 1; z = z + 1; }
        i64 j = ip;
        if (j < 0) j = 0;
        loop { if (j >= dn) break; st8(o + ZS_HDR + w, ld8(dv + j)); w = w + 1; j = j + 1; }
    }
    st64(o + 16, w);
    st8(o + ZS_HDR + w, 0);
    return o;
}

uptr php_spf(uptr z, i64 flags, i64 width, i64 prec, i64 conv, i64 pad) {
    uptr s = 0;
    i64 neg = 0;
    if (conv == 's') {
        s = php_zv_str(z);
        if (prec >= 0 && php_strlen(s) > prec) s = php_str_new(s + ZS_HDR, prec);
    }
    if (conv == 'd' || conv == 'i') {
        i64 v = php_zv_long(z);
        if (v < 0) neg = 1;
        s = php_itos(v);
    }
    if (conv == 'u') {
        u64 v2 = php_zv_long(z);
        s = php_tobase(v2, 10);
    }
    if (conv == 'x') s = php_tobase(php_zv_long(z), 16);
    if (conv == 'X') s = php_case(php_tobase(php_zv_long(z), 16), 1);
    if (conv == 'o') s = php_tobase(php_zv_long(z), 8);
    if (conv == 'b') s = php_tobase(php_zv_long(z), 2);
    if (conv == 'c') { i64 cv = php_zv_long(z); s = php_chr(cv); }
    if (conv == 'f' || conv == 'F') {
        i64 p = 6;
        if (prec >= 0) p = prec;
        f64 x = php_zv_double(z);
        if (x < 0.0) neg = 1;
        s = php_spf_f(x, p);
    }
    if (conv == 'e' || conv == 'E') {
        i64 p2 = 6;
        if (prec >= 0) p2 = prec;
        f64 x2 = php_zv_double(z);
        if (x2 < 0.0) neg = 1;
        s = php_spf_e(x2, p2, conv == 'E');
    }
    if (conv == 'g' || conv == 'G') {
        i64 p3 = 6;
        if (prec > 0) p3 = prec;
        u8 b[64];
        i64 n = php_fmt_f64(b, php_zv_double(z), p3);
        s = php_str_new(b, n);
        if (conv == 'g') s = php_case(s, 0);
    }
    if (!s) s = php_zv_str(z);
    if (conv == 'd' || conv == 'f' || conv == 'F' || conv == 'e' || conv == 'E') s = php_spf_sign(s, flags, neg);
    return php_spf_pad(s, flags, width, pad);
}

// ---- more of the library ---------------------------------------------------
uptr php_f_md5(uptr z, uptr _p2);
uptr php_f_sha1(uptr z, uptr _p2);

i64 php_f_strcmp_z(uptr a, uptr b) { return php_str_cmp(php_zv_str(a), php_zv_str(b)); }

uptr php_f_str_rot13(uptr z) {
    uptr s = php_zv_str(z);
    i64 n = php_strlen(s);
    uptr o = php_str_new(s + ZS_HDR, n);
    i64 i = 0;
    loop {
        if (i >= n) break;
        i64 c = ld8(o + ZS_HDR + i);
        if (c >= 'a' && c <= 'z') st8(o + ZS_HDR + i, 'a' + (c - 'a' + 13) % 26);
        if (c >= 'A' && c <= 'Z') st8(o + ZS_HDR + i, 'A' + (c - 'A' + 13) % 26);
        i = i + 1;
    }
    return o;
}

uptr php_f_quotemeta(uptr z) {
    uptr s = php_zv_str(z);
    i64 n = php_strlen(s);
    uptr o = php_str_alloc(n * 2);
    i64 w = 0;
    i64 i = 0;
    loop {
        if (i >= n) break;
        i64 c = ld8(s + ZS_HDR + i);
        if (php_inset(php_str_new(".\\+*?[^]$()", 11), c)) { st8(o + ZS_HDR + w, 92); w = w + 1; }
        st8(o + ZS_HDR + w, c);
        w = w + 1;
        i = i + 1;
    }
    st64(o + 16, w);
    st8(o + ZS_HDR + w, 0);
    return o;
}

uptr php_f_strpbrk(uptr sz, uptr cz) {
    uptr s = php_zv_str(sz);
    uptr set = php_zv_str(cz);
    i64 n = php_strlen(s);
    i64 i = 0;
    loop {
        if (i >= n) break;
        if (php_inset(set, ld8(s + ZS_HDR + i))) return php_zstr(php_str_new(s + ZS_HDR + i, n - i));
        i = i + 1;
    }
    return php_zbool(0);
}

i64 php_f_substr_compare(uptr mz, uptr nz, uptr oz, uptr lz, uptr _p5) {
    uptr m = php_zv_str(mz);
    uptr nd = php_zv_str(nz);
    i64 o = php_zv_long(oz);
    if (o < 0) o = php_strlen(m) + o;
    uptr a = php_substr(m, o, 0, 0);
    uptr b = nd;
    if (php_zv_type(lz) != IS_NULL) {
        i64 l = php_zv_long(lz);
        a = php_substr(a, 0, l, 1);
        b = php_substr(b, 0, l, 1);
    }
    return php_str_cmp(a, b);
}

i64 php_f_levenshtein(uptr az, uptr bz) {
    uptr a = php_zv_str(az);
    uptr b = php_zv_str(bz);
    i64 n = php_strlen(a);
    i64 m = php_strlen(b);
    if (n == 0) return m;
    if (m == 0) return n;
    uptr prev = php_alloc((m + 1) * 8);
    uptr cur = php_alloc((m + 1) * 8);
    i64 j = 0;
    loop { if (j > m) break; st64(prev + j * 8, j); j = j + 1; }
    i64 i = 1;
    loop {
        if (i > n) break;
        st64(cur, i);
        j = 1;
        loop {
            if (j > m) break;
            i64 cost = 1;
            if (ld8(a + ZS_HDR + i - 1) == ld8(b + ZS_HDR + j - 1)) cost = 0;
            i64 d = ld64(prev + j * 8) + 1;
            i64 ins = ld64(cur + (j - 1) * 8) + 1;
            i64 sub = ld64(prev + (j - 1) * 8) + cost;
            if (ins < d) d = ins;
            if (sub < d) d = sub;
            st64(cur + j * 8, d);
            j = j + 1;
        }
        uptr t = prev;
        prev = cur;
        cur = t;
        i = i + 1;
    }
    return ld64(prev + m * 8);
}

// php's third argument is by REFERENCE and carries the percentage; T8's
// by-reference call sites make it the caller's own zval, so this can write
// it. The recursion passes 0 and only the OUTER call fills it in.
i64 php_f_similar_text(uptr az, uptr bz, uptr pz) {
    i64 sim = php_similar_n(az, bz);
    if (pz) {
        if (php_zv_type(pz) != IS_NULL || 1) {
            i64 la = php_strlen(php_zv_str(az));
            i64 lb = php_strlen(php_zv_str(bz));
            f64 pc = 0.0;
            if (la + lb) pc = ((f64) sim) * 2.0 * 100.0 / ((f64) (la + lb));
            stf64(pz, pc);
            php_zv_settype(pz, IS_DOUBLE);
        }
    }
    return sim;
}

i64 php_similar_n(uptr az, uptr bz) {
    uptr a = php_zv_str(az);
    uptr b = php_zv_str(bz);
    i64 n = php_strlen(a);
    i64 m = php_strlen(b);
    if (n == 0 || m == 0) return 0;
    i64 bi = 0;
    i64 bj = 0;
    i64 bl = 0;
    i64 i = 0;
    loop {
        if (i >= n) break;
        i64 j = 0;
        loop {
            if (j >= m) break;
            i64 k = 0;
            loop {
                if (i + k >= n || j + k >= m) break;
                if (ld8(a + ZS_HDR + i + k) != ld8(b + ZS_HDR + j + k)) break;
                k = k + 1;
            }
            if (k > bl) { bl = k; bi = i; bj = j; }
            j = j + 1;
        }
        i = i + 1;
    }
    if (bl == 0) return 0;
    i64 sum = bl;
    if (bi && bj) sum = sum + php_similar_n(php_zstr(php_str_new(a + ZS_HDR, bi)), php_zstr(php_str_new(b + ZS_HDR, bj)));
    if (bi + bl < n && bj + bl < m)
        sum = sum + php_similar_n(php_zstr(php_str_new(a + ZS_HDR + bi + bl, n - bi - bl)),
                                  php_zstr(php_str_new(b + ZS_HDR + bj + bl, m - bj - bl)));
    return sum;
}

uptr php_f_soundex(uptr z) {
    uptr s = php_case(php_zv_str(z), 1);
    uptr code = "01230120022455012623010202";
    i64 n = php_strlen(s);
    u8 t[8];
    i64 w = 0;
    i64 last = 0;
    i64 i = 0;
    loop {
        if (i >= n || w >= 4) break;
        i64 c = ld8(s + ZS_HDR + i);
        i = i + 1;
        if (c < 'A' || c > 'Z') continue;
        i64 d = ld8(code + (c - 'A'));
        if (!w) { st8(t, c); w = 1; last = d; continue; }
        if (d != '0' && d != last) { st8(t + w, d); w = w + 1; }
        last = d;
    }
    if (!w) return php_str_new("", 0);
    loop { if (w >= 4) break; st8(t + w, '0'); w = w + 1; }
    return php_str_new(t, 4);
}

uptr php_f_count_chars(uptr z, uptr mz) {
    uptr s = php_zv_str(z);
    i64 n = php_strlen(s);
    u8 tab[2048];
    i64 i = 0;
    loop { if (i >= 256) break; st64(tab + i * 8, 0); i = i + 1; }
    i = 0;
    loop { if (i >= n) break; i64 c = ld8(s + ZS_HDR + i); st64(tab + c * 8, ld64(tab + c * 8) + 1); i = i + 1; }
    i64 mode = php_zv_long(mz);
    uptr r = php_arr_new(16);
    i = 0;
    loop {
        if (i >= 256) break;
        i64 v = ld64(tab + i * 8);
        if (mode == 0) php_zv_cp(php_arr_islot(r, i), php_zlong(v));
        if (mode == 1 && v) php_zv_cp(php_arr_islot(r, i), php_zlong(v));
        if (mode == 3 && v) { u8 cb[1]; st8(cb, i); php_arr_push(r, php_zstr(php_str_new(cb, 1))); }
        i = i + 1;
    }
    if (mode == 3) {
        uptr o = php_str_alloc(php_count(r));
        i64 w = 0;
        i64 u = php_ht_used(r);
        i = 0;
        loop {
            if (i >= u) break;
            uptr b = php_ht_bkt(r, i);
            if (ld8(b + 8) != IS_UNDEF) { st8(o + ZS_HDR + w, ld8(php_zv_str(b) + ZS_HDR)); w = w + 1; }
            i = i + 1;
        }
        return php_zstr(o);
    }
    return php_zarr(r);
}

uptr php_f_str_word_count(uptr z, uptr _p2, uptr _p3) {
    uptr s = php_zv_str(z);
    i64 n = php_strlen(s);
    uptr r = php_arr_new(8);
    i64 i = 0;
    loop {
        if (i >= n) break;
        i64 c = ld8(s + ZS_HDR + i);
        i64 ok = 0;
        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == 39 || c == 45) ok = 1;
        if (!ok) { i = i + 1; continue; }
        i64 st = i;
        loop {
            if (i >= n) break;
            i64 d = ld8(s + ZS_HDR + i);
            i64 k = 0;
            if ((d >= 'a' && d <= 'z') || (d >= 'A' && d <= 'Z') || d == 39 || d == 45) k = 1;
            if (!k) break;
            i = i + 1;
        }
        php_arr_push(r, php_zstr(php_str_new(s + ZS_HDR + st, i - st)));
    }
    return r;
}

// trim's charlist understands `x..y` as a RANGE (measured:
// trim("a..z", "a..z") is ".." because a..z is every letter)
i64 php_trimset2(uptr set, i64 c) {
    i64 n = php_strlen(set);
    uptr b = set + ZS_HDR;
    i64 i = 0;
    loop {
        if (i >= n) break;
        if (i + 3 < n) {
            if (ld8(b + i + 1) == 46) { if (ld8(b + i + 2) == 46) {
                i64 lo = ld8(b + i);
                i64 hi = ld8(b + i + 3);
                if (c >= lo && c <= hi) return 1;
                i = i + 4;
                continue;
            } }
        }
        if (ld8(b + i) == c) return 1;
        i = i + 1;
    }
    return 0;
}

uptr php_f_ltrim_c(uptr z, uptr cz, i64 mode) {
    uptr s = php_zv_str(z);
    if (php_zv_type(cz) == IS_NULL) return php_trim(s, mode);
    uptr set = php_zv_str(cz);
    i64 n = php_strlen(s);
    i64 a = 0;
    i64 b = n;
    if (mode != 2) { loop { if (a >= b) break; if (!php_trimset2(set, ld8(s + ZS_HDR + a))) break; a = a + 1; } }
    if (mode != 1) { loop { if (b <= a) break; if (!php_trimset2(set, ld8(s + ZS_HDR + b - 1))) break; b = b - 1; } }
    return php_str_new(s + ZS_HDR + a, b - a);
}

uptr php_f_trim(uptr z, uptr c) { return php_f_ltrim_c(z, c, 0); }
uptr php_f_ltrim(uptr z, uptr c) { return php_f_ltrim_c(z, c, 1); }
uptr php_f_rtrim(uptr z, uptr c) { return php_f_ltrim_c(z, c, 2); }

uptr php_f_ucfirst(uptr z) { return php_ucfirst(php_zv_str(z)); }

// implode with ONE argument (php 8 allows implode($array)), explode with a
// LIMIT, and substr_count with an offset and a length: the arities T6's rows
// were one or two short of, which why.py counted 30 times under
// "the wrong number of arguments for".
uptr php_implode(uptr sep, uptr a);
uptr php_arr_new(i64 cap);

uptr php_f_explode3(uptr sz, uptr hz, uptr lz) {
    uptr sep = php_zv_str(sz);
    uptr s = php_zv_str(hz);
    i64 lim = 9223372036854775807;
    if (php_zv_type(lz) != IS_NULL) lim = php_zv_long(lz);
    if (lim == 0) lim = 1;                       // php: a limit of 0 is a limit of 1
    uptr all = php_explode(sep, s);
    if (lim >= php_count(all) && lim > 0) return all;
    i64 n = php_count(all);
    uptr r = php_arr_new(8);
    if (lim > 0) {
        i64 i = 0;
        loop {
            if (i >= lim - 1) break;
            php_zv_cpv(php_arr_nextslot(r), php_arr_iget(all, i));
            i = i + 1;
        }
        // the tail, joined back with the separator
        uptr acc = php_str_new("", 0);
        i64 j = lim - 1;
        loop {
            if (j >= n) break;
            if (j > lim - 1) acc = php_str_concat(acc, sep);
            acc = php_str_concat(acc, php_zv_str(php_arr_iget(all, j)));
            j = j + 1;
        }
        php_zv_cpv(php_arr_nextslot(r), php_zstr(acc));
        return r;
    }
    // a negative limit drops that many elements from the end
    i64 keep = n + lim;
    i64 k = 0;
    loop {
        if (k >= keep) break;
        php_zv_cpv(php_arr_nextslot(r), php_arr_iget(all, k));
        k = k + 1;
    }
    return r;
}

i64 php_f_substr_count(uptr hz, uptr nz, uptr oz, uptr lz) {
    uptr h = php_zv_str(hz);
    uptr nd = php_zv_str(nz);
    i64 hn = php_strlen(h);
    i64 off = 0;
    if (php_zv_type(oz) != IS_NULL) off = php_zv_long(oz);
    if (off < 0) off = hn + off;
    if (off < 0) off = 0;
    i64 end = hn;
    if (php_zv_type(lz) != IS_NULL) {
        i64 len = php_zv_long(lz);
        if (len < 0) end = hn + len;
        if (len >= 0) end = off + len;
    }
    if (end > hn) end = hn;
    i64 nn = php_strlen(nd);
    if (nn == 0) return 0;
    i64 c = 0;
    i64 i = off;
    loop {
        if (i + nn > end) break;
        i64 k = 0;
        i64 eq = 1;
        loop {
            if (k >= nn) break;
            if (ld8(h + ZS_HDR + i + k) != ld8(nd + ZS_HDR + k)) { eq = 0; break; }
            k = k + 1;
        }
        if (eq) { c = c + 1; i = i + nn; continue; }
        i = i + 1;
    }
    return c;
}

// ---- more of the library (T6's "most wanted" table) -----------------------
// class_alias($class, $alias): a second NAME for a class entry. It is not
// reflection (D6): the registry is the same one `new Foo` already walks, and
// nothing can enumerate it.
uptr php_ce_find(uptr name);
uptr php_ce_reg();
uptr php_case(uptr s, i64 up);

u8 php_f_class_alias(uptr cz, uptr az, uptr autoz) {
    uptr cn = php_zv_str(cz);
    uptr ce = php_ce_find(cn);
    if (!ce) {
        uptr m = php_str_concat(php_str_new("Class \"", 7), cn);
        m = php_str_concat(m, php_str_new("\" not found", 11));
        php_throw_str(php_str_new("Error", 5), m);
        return 0;
    }
    uptr an = php_case(php_zv_str(az), 0);
    php_zv_cpv(php_arr_sslot(php_ce_reg(), an), php_zlong(ce));
    return 1;
}

// register_shutdown_function($fn, ...): php runs these at the end, before the
// destructors. One list, called by php_shutdown.
uptr ph_sdfn;
i64  ph_nsdfn;

// `n` is how many arguments AFTER the callback were really passed. The
// library row pads the slots it was not given with php_znull(), so the
// callee cannot tell `register_shutdown_function($f)` from
// `register_shutdown_function($f, null, null, null)` -- and php_shutdown
// then handed the callback three nulls, which func_num_args() can see. The
// count comes from the CALL SITE, which is the only place that knows it:
// ph_call special-cases the name, exactly as it does for array_push.
u8 php_f_reg_shutdown(uptr f, uptr a1, uptr a2, uptr a3) {
    if (!ph_sdfn) ph_sdfn = php_arr_new(8);
    uptr row = php_arr_new(8);
    php_zv_cpv(php_arr_islot(row, 0), f);
    php_zv_cpv(php_arr_islot(row, 1), a1);
    php_zv_cpv(php_arr_islot(row, 2), a2);
    php_zv_cpv(php_arr_islot(row, 3), a3);
    // How many arguments AFTER the callback were really passed. The library
    // row pads the slots it was not given with php_znull(), so this could
    // not tell `register_shutdown_function($f)` from one called with three
    // explicit nulls, and php_shutdown handed the callback three of them --
    // which the callback can see. ph_call special-cases the name (the
    // array_push shape) and passes php_zundef() for a slot that was not
    // written, which IS distinguishable from a null that was.
    i64 sn = 0;
    if (php_zv_type(a1) != IS_UNDEF) sn = 1;
    if (php_zv_type(a2) != IS_UNDEF) sn = 2;
    if (php_zv_type(a3) != IS_UNDEF) sn = 3;
    php_zv_cpv(php_arr_islot(row, 4), php_zlong(sn));
    php_zv_cpv(php_arr_nextslot(ph_sdfn), php_zarr(row));
    ph_nsdfn = ph_nsdfn + 1;
    return 1;
}

// strtok($string, $token) / strtok($token): php keeps the cursor in a global
uptr ph_tok_s;
i64  ph_tok_i;

i64 php_tok_in(uptr set, i64 c) {
    i64 n = php_strlen(set);
    i64 i = 0;
    loop { if (i >= n) break; if (ld8(set + ZS_HDR + i) == c) return 1; i = i + 1; }
    return 0;
}

uptr php_f_strtok(uptr a, uptr b) {
    uptr set = 0;
    if (php_zv_type(b) != IS_NULL) {
        ph_tok_s = php_zv_str(a);
        ph_tok_i = 0;
        set = php_zv_str(b);
    }
    if (!set) {
        if (php_zv_type(a) == IS_NULL) {
            php_warn1("strtok(): Both arguments must be provided when starting tokenization");
            return php_zbool(0);
        }
        set = php_zv_str(a);
    }
    if (!ph_tok_s) return php_zbool(0);
    i64 n = php_strlen(ph_tok_s);
    i64 i = ph_tok_i;
    loop { if (i >= n) break; if (!php_tok_in(set, ld8(ph_tok_s + ZS_HDR + i))) break; i = i + 1; }
    if (i >= n) { ph_tok_i = n; return php_zbool(0); }
    i64 st = i;
    loop { if (i >= n) break; if (php_tok_in(set, ld8(ph_tok_s + ZS_HDR + i))) break; i = i + 1; }
    ph_tok_i = i + 1;
    if (i > n) ph_tok_i = n;
    return php_zstr(php_str_new(ph_tok_s + ZS_HDR + st, i - st));
}

// strnatcmp / strnatcasecmp: php's "natural order" -- a run of digits
// compares as a number, everything else byte by byte.
i64 php_nat_digit(i64 c) { if (c >= 48 && c <= 57) return 1; return 0; }

i64 php_natcmp(uptr a, uptr b, i64 fold) {
    i64 la = php_strlen(a);
    i64 lb = php_strlen(b);
    i64 i = 0;
    i64 j = 0;
    loop {
        if (i >= la || j >= lb) break;
        i64 ca = ld8(a + ZS_HDR + i);
        i64 cb = ld8(b + ZS_HDR + j);
        if (php_nat_digit(ca) && php_nat_digit(cb)) {
            loop { if (i >= la) break; if (ld8(a + ZS_HDR + i) != 48) break; i = i + 1; }
            loop { if (j >= lb) break; if (ld8(b + ZS_HDR + j) != 48) break; j = j + 1; }
            i64 ea = i;
            i64 eb = j;
            loop { if (ea >= la) break; if (!php_nat_digit(ld8(a + ZS_HDR + ea))) break; ea = ea + 1; }
            loop { if (eb >= lb) break; if (!php_nat_digit(ld8(b + ZS_HDR + eb))) break; eb = eb + 1; }
            if (ea - i != eb - j) { if (ea - i < eb - j) return -1; return 1; }
            loop {
                if (i >= ea) break;
                i64 x = ld8(a + ZS_HDR + i);
                i64 y = ld8(b + ZS_HDR + j);
                if (x != y) { if (x < y) return -1; return 1; }
                i = i + 1;
                j = j + 1;
            }
            i = ea;
            j = eb;
            continue;
        }
        if (fold) {
            if (ca >= 65 && ca <= 90) ca = ca + 32;
            if (cb >= 65 && cb <= 90) cb = cb + 32;
        }
        if (ca != cb) { if (ca < cb) return -1; return 1; }
        i = i + 1;
        j = j + 1;
    }
    if (la - i < lb - j) return -1;
    if (la - i > lb - j) return 1;
    return 0;
}

i64 php_f_strnatcmp(uptr a, uptr b) { return php_natcmp(php_zv_str(a), php_zv_str(b), 0); }
i64 php_f_strnatcasecmp(uptr a, uptr b) { return php_natcmp(php_zv_str(a), php_zv_str(b), 1); }

// addcslashes($string, $characters): a backslash before every listed byte,
// with php's own C escapes for the unprintable ones. A range is spelled
// `a..z`; php builds the 256-byte mask ONCE per call, which is also where it
// warns about a decreasing range -- once, not once per input byte.
void php_cs_mask(uptr m, uptr set) {
    i64 n = php_strlen(set);
    i64 i = 0;
    loop { if (i >= 256) break; st8(m + i, 0); i = i + 1; }
    i = 0;
    loop {
        if (i >= n) break;
        i64 x = ld8(set + ZS_HDR + i);
        if (i + 3 < n && ld8(set + ZS_HDR + i + 1) == '.' && ld8(set + ZS_HDR + i + 2) == '.') {
            i64 y = ld8(set + ZS_HDR + i + 3);
            if (y < x) {
                php_warn1("addcslashes(): Invalid '..'-range, '..'-range needs to be incrementing");
                st8(m + x, 1);
                st8(m + '.', 1);
                st8(m + y, 1);
                i = i + 4;
                continue;
            }
            i64 c = x;
            loop { if (c > y) break; st8(m + c, 1); c = c + 1; }
            i = i + 4;
            continue;
        }
        st8(m + x, 1);
        i = i + 1;
    }
}

uptr php_f_addcslashes(uptr sz, uptr cz) {
    uptr s = php_zv_str(sz);
    u8 mask[256];
    php_cs_mask(mask, php_zv_str(cz));
    i64 n = php_strlen(s);
    uptr o = php_str_alloc(n * 4);
    i64 k = 0;
    i64 i = 0;
    loop {
        if (i >= n) break;
        i64 c = ld8(s + ZS_HDR + i);
        if (ld8(mask + c)) {
            if (c < 32 || c > 126) {
                st8(o + ZS_HDR + k, 92);
                k = k + 1;
                if (c == 10) { st8(o + ZS_HDR + k, 'n'); k = k + 1; }
                else { if (c == 9) { st8(o + ZS_HDR + k, 't'); k = k + 1; }
                else { if (c == 13) { st8(o + ZS_HDR + k, 'r'); k = k + 1; }
                else { if (c == 7) { st8(o + ZS_HDR + k, 'a'); k = k + 1; }
                else { if (c == 11) { st8(o + ZS_HDR + k, 'v'); k = k + 1; }
                else { if (c == 8) { st8(o + ZS_HDR + k, 'b'); k = k + 1; }
                else { if (c == 12) { st8(o + ZS_HDR + k, 'f'); k = k + 1; }
                else {
                    st8(o + ZS_HDR + k, 48 + (c / 64 & 7)); k = k + 1;
                    st8(o + ZS_HDR + k, 48 + (c / 8 & 7)); k = k + 1;
                    st8(o + ZS_HDR + k, 48 + (c & 7)); k = k + 1;
                } } } } } } }
            } else {
                st8(o + ZS_HDR + k, 92);
                k = k + 1;
                st8(o + ZS_HDR + k, c);
                k = k + 1;
            }
        } else {
            st8(o + ZS_HDR + k, c);
            k = k + 1;
        }
        i = i + 1;
    }
    st64(o + 16, k);
    st8(o + ZS_HDR + k, 0);
    return o;
}
uptr php_f_basename(uptr z, uptr sz) {
    uptr s = php_zv_str(z);
    i64 n = php_strlen(s);
    // php_basename: a separator ends a name, and on Windows so does a drive's
    // colon at the start of a name (php_base_colon, a host answer: "C:foo" is
    // "foo" there and itself everywhere else)
    uptr b = s + ZS_HDR;
    loop {
        if (n <= 0) break;
        i64 c = ld8(b + n - 1);
        if (!php_is_sep(c) && !(c == ':' && php_base_colon(b, n - 1))) break;
        n = n - 1;
    }
    i64 i = n;
    loop {
        if (i <= 0) break;
        i64 c = ld8(b + i - 1);
        if (php_is_sep(c)) break;
        if (c == ':' && php_base_colon(b, i - 1)) break;
        i = i - 1;
    }
    uptr r = php_str_new(s + ZS_HDR + i, n - i);
    if (php_zv_type(sz) != IS_NULL) {
        uptr suf = php_zv_str(sz);
        i64 sl = php_strlen(suf);
        if (sl && php_strlen(r) > sl && php_str_eq(php_str_new(r + ZS_HDR + php_strlen(r) - sl, sl), suf))
            r = php_str_new(r + ZS_HDR, php_strlen(r) - sl);
    }
    return r;
}

// php's zend_dirname (Zend/zend_compile.c), step for step, with the three
// answers that are the HOST's asked of the host layer: what separates
// (php_is_sep), what a root is written as (php_dir_sep: DEFAULT_SLASH, so a
// Windows root is "\\" whichever separator the path used), and how long a
// drive spec is (php_drive_len: "C:" on Windows, never on POSIX). The drive
// is kept as it is and the rest is a POSIX dirname; dirname("C:") is "C:".
uptr php_dn_one(uptr p, i64 adj, i64 c) {
    uptr r = php_str_alloc(adj + 1);
    i64 i = 0;
    loop { if (i >= adj) break; st8(r + ZS_HDR + i, ld8(p + i)); i = i + 1; }
    st8(r + ZS_HDR + adj, c);
    return r;
}

uptr php_f_dirname(uptr z, uptr _p2) {
    uptr s = php_zv_str(z);
    uptr p = s + ZS_HDR;
    i64 len = php_strlen(s);
    i64 adj = php_drive_len(p, len);
    if (adj && len == 2) return php_str_new(p, 2);
    if (len == 0) return php_str_new("", 0);
    uptr q = p + adj;
    i64 end = len - adj - 1;
    // trailing separators
    loop { if (end < 0) break; if (!php_is_sep(ld8(q + end))) break; end = end - 1; }
    if (end < 0) return php_dn_one(p, adj, php_dir_sep());
    // the file name
    loop { if (end < 0) break; if (php_is_sep(ld8(q + end))) break; end = end - 1; }
    if (end < 0) return php_dn_one(p, adj, '.');
    // the separators before it
    loop { if (end < 0) break; if (!php_is_sep(ld8(q + end))) break; end = end - 1; }
    if (end < 0) return php_dn_one(p, adj, php_dir_sep());
    return php_str_new(p, adj + end + 1);
}

i64 php_f_crc32(uptr z) {
    uptr s = php_zv_str(z);
    i64 n = php_strlen(s);
    u64 c = 4294967295;
    i64 i = 0;
    loop {
        if (i >= n) break;
        c = c ^ ld8(s + ZS_HDR + i);
        i64 k = 0;
        loop {
            if (k >= 8) break;
            u64 m = 0 - (c & 1);
            c = (c >> 1) ^ (3988292384 & m);
            k = k + 1;
        }
        i = i + 1;
    }
    return (c ^ 4294967295) & 4294967295;
}

uptr php_f_urlencode(uptr z, i64 raw) {
    uptr s = php_zv_str(z);
    i64 n = php_strlen(s);
    uptr o = php_str_alloc(n * 3);
    i64 w = 0;
    i64 i = 0;
    loop {
        if (i >= n) break;
        i64 c = ld8(s + ZS_HDR + i);
        i64 safe = 0;
        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) safe = 1;
        if (c == 45 || c == 46 || c == 95) safe = 1;
        if (raw && c == 126) safe = 1;
        if (safe) { st8(o + ZS_HDR + w, c); w = w + 1; i = i + 1; continue; }
        if (!raw && c == 32) { st8(o + ZS_HDR + w, 43); w = w + 1; i = i + 1; continue; }
        st8(o + ZS_HDR + w, 37);
        st8(o + ZS_HDR + w + 1, ld8("0123456789ABCDEF" + ((c >> 4) & 15)));
        st8(o + ZS_HDR + w + 2, ld8("0123456789ABCDEF" + (c & 15)));
        w = w + 3;
        i = i + 1;
    }
    st64(o + 16, w);
    st8(o + ZS_HDR + w, 0);
    return o;
}

uptr php_f_urlencode0(uptr z) { return php_f_urlencode(z, 0); }
uptr php_f_rawurlencode(uptr z) { return php_f_urlencode(z, 1); }

uptr php_f_urldecode(uptr z) {
    uptr s = php_zv_str(z);
    i64 n = php_strlen(s);
    uptr o = php_str_alloc(n);
    i64 w = 0;
    i64 i = 0;
    loop {
        if (i >= n) break;
        i64 c = ld8(s + ZS_HDR + i);
        if (c == 43) { st8(o + ZS_HDR + w, 32); w = w + 1; i = i + 1; continue; }
        if (c == 37 && i + 2 < n) {
            i64 h1 = php_hexval(ld8(s + ZS_HDR + i + 1));
            i64 h2 = php_hexval(ld8(s + ZS_HDR + i + 2));
            if (h1 >= 0 && h2 >= 0) { st8(o + ZS_HDR + w, h1 * 16 + h2); w = w + 1; i = i + 3; continue; }
        }
        st8(o + ZS_HDR + w, c);
        w = w + 1;
        i = i + 1;
    }
    st64(o + 16, w);
    st8(o + ZS_HDR + w, 0);
    return o;
}

uptr php_f_htmlspecialchars_decode(uptr z, uptr _p2, uptr _p3) {
    uptr s = php_zv_str(z);
    uptr r = php_str_replace(php_str_new("&amp;", 5), php_str_new("&", 1), s);
    r = php_str_replace(php_str_new("&lt;", 4), php_str_new("<", 1), r);
    r = php_str_replace(php_str_new("&gt;", 4), php_str_new(">", 1), r);
    r = php_str_replace(php_str_new("&quot;", 6), php_str_new("\"", 1), r);
    r = php_str_replace(php_str_new("&#039;", 6), php_str_new("'", 1), r);
    r = php_str_replace(php_str_new("&#39;", 5), php_str_new("'", 1), r);
    return r;
}

uptr php_f_str_increment(uptr z) { return php_zstr(php_str_inc(php_zv_str(z))); }

u8 php_f_array_is_list(uptr z) {
    if (php_zv_type(z) != IS_ARRAY) return 0;
    uptr h = ld64(z);
    i64 used = php_ht_used(h);
    i64 k = 0;
    i64 i = 0;
    loop {
        if (i >= used) break;
        uptr b = php_ht_bkt(h, i);
        if (ld8(b + 8) != IS_UNDEF) {
            if (ld64(b + 24)) return 0;
            if (ld64(b + 16) != k) return 0;
            k = k + 1;
        }
        i = i + 1;
    }
    return 1;
}

i64 php_f_array_push(uptr a, uptr v1, uptr v2, uptr v3) {
    if (php_zv_type(a) != IS_ARRAY) return 0;
    uptr h = ld64(a);
    php_arr_push(h, v1);
    if (php_zv_type(v2) != IS_NULL) php_arr_push(h, v2);
    if (php_zv_type(v3) != IS_NULL) php_arr_push(h, v3);
    return php_count(h);
}

uptr php_f_array_column(uptr a, uptr col, uptr idx) {
    uptr r = php_arr_new(8);
    if (php_zv_type(a) != IS_ARRAY) return r;
    uptr h = ld64(a);
    i64 used = php_ht_used(h);
    i64 i = 0;
    loop {
        if (i >= used) break;
        uptr b = php_ht_bkt(h, i);
        if (ld8(b + 8) != IS_UNDEF && php_zv_type(b) == IS_ARRAY) {
            uptr row = ld64(b);
            uptr v = b;
            if (php_zv_type(col) != IS_NULL) {
                if (!php_arr_has(row, col)) { i = i + 1; continue; }
                v = php_arr_zget(row, col);
            }
            if (php_zv_type(idx) != IS_NULL && php_arr_has(row, idx))
                php_zv_cpv(php_arr_zslot(r, php_arr_zget(row, idx)), v);
            if (php_zv_type(idx) == IS_NULL) php_zv_cpv(php_arr_nextslot(r), v);
        }
        i = i + 1;
    }
    return r;
}

// `array_diff_key` is a different function from `array_diff`, and wiring it
// to the same helper answered by VALUE: `array_diff_key(["a"=>1], ["b"=>1])`
// kept nothing where php keeps `a`, because the two 1s compare equal. The key
// a stored bucket carries is already normalised -- a numeric string became an
// integer index at insert -- so a string key is looked up by its own hash and
// an integer one by the index, which IS the hash the table stored.
i64 php_bkt_key_in(uptr other, uptr bk) {
    if (php_zv_type(other) != IS_ARRAY) return 0;
    uptr g = ld64(other);
    uptr k = ld64(bk + 24);
    if (k) {
        if (php_ht_find(g, php_str_hash(k), k)) return 1;
        return 0;
    }
    if (php_ht_find(g, ld64(bk + 16), 0)) return 1;
    return 0;
}

uptr php_f_array_diff_key(uptr a, uptr b) {
    uptr r = php_arr_new(8);
    if (php_zv_type(a) != IS_ARRAY) return r;
    uptr h = ld64(a);
    i64 used = php_ht_used(h);
    i64 i = 0;
    loop {
        if (i >= used) break;
        uptr bk = php_ht_bkt(h, i);
        if (ld8(bk + 8) != IS_UNDEF) {
            if (!php_bkt_key_in(b, bk)) {
                uptr k = ld64(bk + 24);
                if (k) php_zv_cpv(php_ht_slotfor(r, php_str_hash(k), k), bk);
                if (!k) php_zv_cpv(php_arr_islot(r, ld64(bk + 16)), bk);
            }
        }
        i = i + 1;
    }
    return r;
}

uptr php_f_array_intersect_key(uptr a, uptr b) {
    uptr r = php_arr_new(8);
    if (php_zv_type(a) != IS_ARRAY) return r;
    uptr h = ld64(a);
    i64 used = php_ht_used(h);
    i64 i = 0;
    loop {
        if (i >= used) break;
        uptr bk = php_ht_bkt(h, i);
        if (ld8(bk + 8) != IS_UNDEF) {
            if (php_bkt_key_in(b, bk)) {
                uptr k = ld64(bk + 24);
                if (k) php_zv_cpv(php_ht_slotfor(r, php_str_hash(k), k), bk);
                if (!k) php_zv_cpv(php_arr_islot(r, ld64(bk + 16)), bk);
            }
        }
        i = i + 1;
    }
    return r;
}

uptr php_f_array_diff(uptr a, uptr b) {
    uptr r = php_arr_new(8);
    if (php_zv_type(a) != IS_ARRAY) return r;
    uptr h = ld64(a);
    i64 used = php_ht_used(h);
    i64 i = 0;
    loop {
        if (i >= used) break;
        uptr bk = php_ht_bkt(h, i);
        if (ld8(bk + 8) != IS_UNDEF) {
            i64 found = 0;
            if (php_zv_type(b) == IS_ARRAY) {
                uptr g = ld64(b);
                i64 u2 = php_ht_used(g);
                i64 j = 0;
                loop {
                    if (j >= u2) break;
                    uptr b2 = php_ht_bkt(g, j);
                    if (ld8(b2 + 8) != IS_UNDEF && php_str_eq(php_zv_str(bk), php_zv_str(b2))) { found = 1; break; }
                    j = j + 1;
                }
            }
            if (!found) {
                uptr k = ld64(bk + 24);
                if (k) php_zv_cpv(php_ht_slotfor(r, php_str_hash(k), k), bk);
                if (!k) php_zv_cpv(php_arr_islot(r, ld64(bk + 16)), bk);
            }
        }
        i = i + 1;
    }
    return r;
}

uptr php_f_array_intersect(uptr a, uptr b) {
    uptr r = php_arr_new(8);
    if (php_zv_type(a) != IS_ARRAY || php_zv_type(b) != IS_ARRAY) return r;
    uptr h = ld64(a);
    uptr g = ld64(b);
    i64 used = php_ht_used(h);
    i64 i = 0;
    loop {
        if (i >= used) break;
        uptr bk = php_ht_bkt(h, i);
        if (ld8(bk + 8) != IS_UNDEF) {
            i64 found = 0;
            i64 u2 = php_ht_used(g);
            i64 j = 0;
            loop {
                if (j >= u2) break;
                uptr b2 = php_ht_bkt(g, j);
                if (ld8(b2 + 8) != IS_UNDEF && php_str_eq(php_zv_str(bk), php_zv_str(b2))) { found = 1; break; }
                j = j + 1;
            }
            if (found) {
                uptr k = ld64(bk + 24);
                if (k) php_zv_cpv(php_ht_slotfor(r, php_str_hash(k), k), bk);
                if (!k) php_zv_cpv(php_arr_islot(r, ld64(bk + 16)), bk);
            }
        }
        i = i + 1;
    }
    return r;
}

uptr php_f_array_pad(uptr a, uptr sz, uptr v) {
    uptr r = php_arr_new(8);
    if (php_zv_type(a) != IS_ARRAY) return r;
    i64 want = php_zv_long(sz);
    i64 n = php_count(ld64(a));
    i64 need = want;
    if (need < 0) need = 0 - need;
    if (need <= n) { php_ht_append_all(r, a); return r; }
    i64 k = need - n;
    if (want < 0) { i64 i = 0; loop { if (i >= k) break; php_arr_push(r, v); i = i + 1; } }
    php_ht_append_all(r, a);
    if (want > 0) { i64 i2 = 0; loop { if (i2 >= k) break; php_arr_push(r, v); i2 = i2 + 1; } }
    return r;
}

uptr php_f_array_chunk(uptr a, uptr sz, uptr pres) {
    uptr r = php_arr_new(8);
    if (php_zv_type(a) != IS_ARRAY) return r;
    i64 k = php_zv_long(sz);
    if (k < 1) k = 1;
    i64 keep = php_zv_bool(pres);
    uptr h = ld64(a);
    i64 used = php_ht_used(h);
    uptr cur = 0;
    i64 c = 0;
    i64 i = 0;
    loop {
        if (i >= used) break;
        uptr b = php_ht_bkt(h, i);
        if (ld8(b + 8) != IS_UNDEF) {
            if (!cur) { cur = php_arr_new(8); c = 0; }
            uptr key = ld64(b + 24);
            if (keep && key) php_zv_cpv(php_ht_slotfor(cur, php_str_hash(key), key), b);
            if (keep && !key) php_zv_cpv(php_arr_islot(cur, ld64(b + 16)), b);
            if (!keep) php_zv_cpv(php_arr_nextslot(cur), b);
            c = c + 1;
            if (c >= k) { php_arr_push(r, php_zarr(cur)); cur = 0; }
        }
        i = i + 1;
    }
    if (cur) php_arr_push(r, php_zarr(cur));
    return r;
}

uptr php_f_compact_no(uptr a) { return php_znull(); }
uptr php_f_iterator(uptr a, uptr _p2) { return a; }
uptr php_f_current(uptr a) {
    if (php_zv_type(a) != IS_ARRAY) return php_zbool(0);
    i64 i = php_it_next(ld64(a), 0);
    if (i < 0) return php_zbool(0);
    return php_it_val(ld64(a), i);
}
uptr php_f_end(uptr a) {
    if (php_zv_type(a) != IS_ARRAY) return php_zbool(0);
    i64 i = php_ht_last(ld64(a));
    if (i < 0) return php_zbool(0);
    return php_it_val(ld64(a), i);
}
uptr php_f_key(uptr a) {
    if (php_zv_type(a) != IS_ARRAY) return php_znull();
    i64 i = php_it_next(ld64(a), 0);
    if (i < 0) return php_znull();
    return php_it_key(ld64(a), i);
}

// md5 and sha1, so a corpus test that hashes a string has an answer
u32 ph_rol(u32 x, i64 c) { return ((x << c) | (x >> (32 - c))) & 4294967295; }

uptr php_f_md5(uptr z, uptr _p2) {
    uptr s = php_zv_str(z);
    i64 n = php_strlen(s);
    i64 total = ((n + 8) / 64 + 1) * 64;
    uptr m = php_alloc(total);
    i64 i = 0;
    loop { if (i >= total) break; st8(m + i, 0); i = i + 1; }
    php_memcpy(m, s + ZS_HDR, n);
    st8(m + n, 128);
    u64 bits = n * 8;
    i = 0;
    loop { if (i >= 8) break; st8(m + total - 8 + i, (bits >> (i * 8)) & 255); i = i + 1; }
    // K[i] = floor(2^32 * |sin(i+1)|), as decimal text so the source carries
    // no escape mc does not have
    u8 kk[512];
    uptr kdec = "3614090360 3905402710 606105819 3250441966 4118548399 1200080426 2821735955 4249261313 1770035416 2336552879 4294925233 2304563134 1804603682 4254626195 2792965006 1236535329 4129170786 3225465664 643717713 3921069994 3593408605 38016083 3634488961 3889429448 568446438 3275163606 4107603335 1163531501 2850285829 4243563512 1735328473 2368359562 4294588738 2272392833 1839030562 4259657740 2763975236 1272893353 4139469664 3200236656 681279174 3936430074 3572445317 76029189 3654602809 3873151461 530742520 3299628645 4096336452 1126891415 2878612391 4237533241 1700485571 2399980690 4293915773 2240044497 1873313359 4264355552 2734768916 1309151649 4149444226 3174756917 718787259 3951481745";
    i64 kp = 0;
    i = 0;
    loop {
        if (i >= 64) break;
        i64 v = 0;
        loop { if (ld8(kdec + kp) < 48 || ld8(kdec + kp) > 57) break; v = v * 10 + (ld8(kdec + kp) - 48); kp = kp + 1; }
        kp = kp + 1;
        st64(kk + i * 8, v);
        i = i + 1;
    }
    u8 rr[64];
    uptr rdec = "7 12 17 22 7 12 17 22 7 12 17 22 7 12 17 22 5 9 14 20 5 9 14 20 5 9 14 20 5 9 14 20 4 11 16 23 4 11 16 23 4 11 16 23 4 11 16 23 6 10 15 21 6 10 15 21 6 10 15 21 6 10 15 21";
    i64 rp = 0;
    i = 0;
    loop {
        if (i >= 64) break;
        i64 v = 0;
        loop { if (ld8(rdec + rp) < 48 || ld8(rdec + rp) > 57) break; v = v * 10 + (ld8(rdec + rp) - 48); rp = rp + 1; }
        rp = rp + 1;
        st8(rr + i, v);
        i = i + 1;
    }
    u64 h0 = 1732584193;
    u64 h1 = 4023233417;
    u64 h2 = 2562383102;
    u64 h3 = 271733878;
    i64 off = 0;
    loop {
        if (off >= total) break;
        u8 w[128];
        i = 0;
        loop {
            if (i >= 16) break;
            u64 v = ld8(m + off + i * 4) | (ld8(m + off + i * 4 + 1) << 8) | (ld8(m + off + i * 4 + 2) << 16) | (ld8(m + off + i * 4 + 3) << 24);
            st64(w + i * 8, v);
            i = i + 1;
        }
        u64 a = h0;
        u64 b = h1;
        u64 c = h2;
        u64 d = h3;
        i = 0;
        loop {
            if (i >= 64) break;
            u64 f = 0;
            i64 g = 0;
            if (i < 16) { f = (b & c) | ((4294967295 - b) & d); g = i; }
            if (i >= 16 && i < 32) { f = (d & b) | ((4294967295 - d) & c); g = (5 * i + 1) % 16; }
            if (i >= 32 && i < 48) { f = b ^ c ^ d; g = (3 * i + 5) % 16; }
            if (i >= 48) { f = c ^ (b | (4294967295 - d)); g = (7 * i) % 16; }
            u64 tmp = d;
            d = c;
            c = b;
            u64 x = (a + (f & 4294967295) + ld64(kk + i * 8) + ld64(w + g * 8)) & 4294967295;
            b = (b + ph_rol(x, ld8(rr + i))) & 4294967295;
            a = tmp;
            i = i + 1;
        }
        h0 = (h0 + a) & 4294967295;
        h1 = (h1 + b) & 4294967295;
        h2 = (h2 + c) & 4294967295;
        h3 = (h3 + d) & 4294967295;
        off = off + 64;
    }
    u8 dig[16];
    i = 0;
    loop {
        if (i >= 4) break;
        st8(dig + i, (h0 >> (i * 8)) & 255);
        st8(dig + 4 + i, (h1 >> (i * 8)) & 255);
        st8(dig + 8 + i, (h2 >> (i * 8)) & 255);
        st8(dig + 12 + i, (h3 >> (i * 8)) & 255);
        i = i + 1;
    }
    return php_f_bin2hex(php_zstr(php_str_new(dig, 16)));
}

uptr php_f_sha1(uptr z, uptr _p2) {
    uptr s = php_zv_str(z);
    i64 n = php_strlen(s);
    i64 total = ((n + 8) / 64 + 1) * 64;
    uptr m = php_alloc(total);
    i64 i = 0;
    loop { if (i >= total) break; st8(m + i, 0); i = i + 1; }
    php_memcpy(m, s + ZS_HDR, n);
    st8(m + n, 128);
    u64 bits = n * 8;
    i = 0;
    loop { if (i >= 8) break; st8(m + total - 1 - i, (bits >> (i * 8)) & 255); i = i + 1; }
    u64 h0 = 1732584193;
    u64 h1 = 4023233417;
    u64 h2 = 2562383102;
    u64 h3 = 271733878;
    u64 h4 = 3285377520;
    i64 off = 0;
    loop {
        if (off >= total) break;
        u8 w[640];
        i = 0;
        loop {
            if (i >= 16) break;
            u64 v = (ld8(m + off + i * 4) << 24) | (ld8(m + off + i * 4 + 1) << 16) | (ld8(m + off + i * 4 + 2) << 8) | ld8(m + off + i * 4 + 3);
            st64(w + i * 8, v);
            i = i + 1;
        }
        i = 16;
        loop {
            if (i >= 80) break;
            u64 v = ld64(w + (i - 3) * 8) ^ ld64(w + (i - 8) * 8) ^ ld64(w + (i - 14) * 8) ^ ld64(w + (i - 16) * 8);
            st64(w + i * 8, ph_rol(v & 4294967295, 1));
            i = i + 1;
        }
        u64 a = h0;
        u64 b = h1;
        u64 c = h2;
        u64 d = h3;
        u64 e = h4;
        i = 0;
        loop {
            if (i >= 80) break;
            u64 f = 0;
            u64 k = 0;
            if (i < 20) { f = (b & c) | ((4294967295 - b) & d); k = 1518500249; }
            if (i >= 20 && i < 40) { f = b ^ c ^ d; k = 1859775393; }
            if (i >= 40 && i < 60) { f = (b & c) | (b & d) | (c & d); k = 2400959708; }
            if (i >= 60) { f = b ^ c ^ d; k = 3395469782; }
            u64 t = (ph_rol(a, 5) + (f & 4294967295) + e + k + ld64(w + i * 8)) & 4294967295;
            e = d;
            d = c;
            c = ph_rol(b, 30);
            b = a;
            a = t;
            i = i + 1;
        }
        h0 = (h0 + a) & 4294967295;
        h1 = (h1 + b) & 4294967295;
        h2 = (h2 + c) & 4294967295;
        h3 = (h3 + d) & 4294967295;
        h4 = (h4 + e) & 4294967295;
        off = off + 64;
    }
    u8 dig[20];
    i = 0;
    loop {
        if (i >= 4) break;
        st8(dig + 3 - i, (h0 >> (i * 8)) & 255);
        st8(dig + 7 - i, (h1 >> (i * 8)) & 255);
        st8(dig + 11 - i, (h2 >> (i * 8)) & 255);
        st8(dig + 15 - i, (h3 >> (i * 8)) & 255);
        st8(dig + 19 - i, (h4 >> (i * 8)) & 255);
        i = i + 1;
    }
    return php_f_bin2hex(php_zstr(php_str_new(dig, 20)));
}

uptr php_f_sapi() { return php_str_new("cli", 3); }
uptr php_f_phpversion(uptr z) { return php_str_new("8.5.10", 6); }
// trigger_error($msg, $level = E_USER_NOTICE); E_USER_ERROR exits 255
u8 php_f_trigger(uptr m, uptr l) {
    i64 lv = PHE_USER_NOTICE;
    if (php_zv_type(l) != IS_NULL) lv = php_zv_long(l);
    php_mreset();
    php_ms(php_zv_str(m));
    php_raise_m(lv);
    return 1;
}

// error_reporting([$level]): php answers the OLD mask and sets the new one
i64 php_f_error_reporting(uptr l) {
    i64 old = ph_erep;
    if (php_zv_type(l) != IS_NULL) ph_erep = php_zv_long(l);
    return old;
}
u8 php_f_contains(uptr h, uptr n) { return php_str_contains(php_zv_str(h), php_zv_str(n)); }
i64 ph_ct_all(uptr z, i64 kind) {
    if (php_zv_type(z) != IS_STRING) return 0;
    uptr s = ld64(z);
    i64 n = php_strlen(s);
    if (n == 0) return 0;
    i64 i = 0;
    loop {
        if (i >= n) break;
        i64 c = ld8(s + ZS_HDR + i);
        i64 ok = 0;
        if (kind == 0 && c >= '0' && c <= '9') ok = 1;
        if (kind == 1 && ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'))) ok = 1;
        if (kind == 2 && ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9'))) ok = 1;
        if (kind == 3 && (c == 32 || c == 9 || c == 10 || c == 13 || c == 11 || c == 12)) ok = 1;
        if (kind == 4 && c >= 'A' && c <= 'Z') ok = 1;
        if (kind == 5 && c >= 'a' && c <= 'z') ok = 1;
        if (kind == 6 && c > 32 && c < 127 && !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9'))) ok = 1;
        if (kind == 7 && php_hexval(c) >= 0) ok = 1;
        if (!ok) return 0;
        i = i + 1;
    }
    return 1;
}
u8 php_f_ctype(uptr z) { return ph_ct_all(z, 0); }
u8 php_f_ctype_a(uptr z) { return ph_ct_all(z, 1); }
u8 php_f_ctype_an(uptr z) { return ph_ct_all(z, 2); }
u8 php_f_ctype_sp(uptr z) { return ph_ct_all(z, 3); }
u8 php_f_ctype_up(uptr z) { return ph_ct_all(z, 4); }
u8 php_f_ctype_lo(uptr z) { return ph_ct_all(z, 5); }
u8 php_f_ctype_pu(uptr z) { return ph_ct_all(z, 6); }
u8 php_f_ctype_xd(uptr z) { return ph_ct_all(z, 7); }

i64 php_f_zero() { return 0; }
uptr php_f_ver0() { return php_str_new("8.5.10", 6); }

// arity-matched wrappers: the library table passes exactly `max` arguments
uptr php_f_null1(uptr a) { return php_znull(); }
uptr php_f_null2(uptr a, uptr b) { return php_znull(); }
uptr php_f_hsd2(uptr a, uptr b) { return php_f_htmlspecialchars_decode(a, 0, 0); }

// foreach over an object walks its properties, in declaration order
uptr php_zv_iter(uptr z) {
    i64 t = php_zv_type(z);
    if (t == IS_ARRAY) return ld64(z);
    if (t == IS_OBJECT) return php_obj_props(ld64(z));
    php_mreset();
    php_mc("foreach() argument must be of type array|object, ");
    if (t == IS_TRUE) php_mc("true");
    if (t == IS_FALSE) php_mc("false");
    if (t != IS_TRUE && t != IS_FALSE) php_ms(php_f_get_debug_type(z));
    php_mc(" given");
    php_raise_m(PHE_WARNING);
    return php_arr_new(8);
}

// ---- files and streams -----------------------------------------------------
// T8. php's stream layer is a plugin architecture; this is the FILE half of
// it, over the six libSystem calls mc's <sys> already declares plus the five
// a module may declare itself. A php `resource` is a zval of type
// IS_RESOURCE whose value is an index into one table -- php's own resource
// ids are small integers too, and `var_dump` prints exactly that.
//
// The fourteen calls and the six flags this section used to declare are the host
// layer's now (lib/rt_host_macos.mc, lib/rt_host_linux.mc): their numbers are
// per-system and their names are not.

#define PH_MAXFH 64
i64  ph_fh_fd[PH_MAXFH];
i64  ph_fh_eof[PH_MAXFH];
i64  ph_fh_own[PH_MAXFH];            // 0 for the three std streams: never closed
uptr ph_fh_name[PH_MAXFH];
i64  ph_nfh;
u8   ph_rdbuf[4096];

uptr php_zres(i64 id) { uptr z = php_zv_alloc(); st64(z, id); php_zv_settype(z, IS_RESOURCE); return z; }

// a resource argument -> the table row, or -1
i64 php_res_id(uptr z) {
    if (php_zv_type(z) != IS_RESOURCE) return 0 - 1;
    i64 id = ld64(z);
    if (id < 1 || id > ph_nfh) return 0 - 1;
    if (ld64(ph_fh_fd + (id - 1) * 8) < 0) return 0 - 1;
    return id - 1;
}

i64 php_fh_new(i64 fd, uptr name, i64 own) {
    if (ph_nfh >= PH_MAXFH) return 0 - 1;
    st64(ph_fh_fd + ph_nfh * 8, fd);
    st64(ph_fh_eof + ph_nfh * 8, 0);
    st64(ph_fh_own + ph_nfh * 8, own);
    st64(ph_fh_name + ph_nfh * 8, name);
    ph_nfh = ph_nfh + 1;
    return ph_nfh;                               // the id is 1-based
}

i64 php_file_exists_c(uptr p) { if (access(p, 0) == 0) return 1; return 0; }

// php_stat_mode and php_stat_size are the host layer's: `struct stat` has a
// different shape on every one of them, and on Linux a different one per
// architecture (lib/rt_host_linux_aarch64.mc).

// a zend_string holding a NUL-terminated copy, for the libc calls
uptr php_cpath(uptr z) {
    uptr s = php_zv_str(z);
    return s + ZS_HDR;                           // php_str_alloc always writes the NUL
}

// php's mode string -> the open flags, and whether the file must be created
// first (mc's `open` is not variadic, so a create is creat() + reopen)
i64 ph_mode_rw;                                  // O_RDONLY / O_WRONLY / O_RDWR
i64 ph_mode_app;
i64 ph_mode_trunc;
i64 ph_mode_create;
i64 ph_mode_excl;

i64 php_parse_mode(uptr m, i64 n) {
    ph_mode_rw = O_RDONLY;
    ph_mode_app = 0;
    ph_mode_trunc = 0;
    ph_mode_create = 0;
    ph_mode_excl = 0;
    if (n < 1) return 0;
    i64 c = ld8(m);
    i64 plus = 0;
    i64 i = 1;
    loop { if (i >= n) break; if (ld8(m + i) == '+') plus = 1; i = i + 1; }
    if (c == 'r') { ph_mode_rw = O_RDONLY; if (plus) ph_mode_rw = O_RDWR; return 1; }
    if (c == 'w') { ph_mode_rw = O_WRONLY; if (plus) ph_mode_rw = O_RDWR; ph_mode_trunc = 1; ph_mode_create = 1; return 1; }
    if (c == 'a') { ph_mode_rw = O_WRONLY; if (plus) ph_mode_rw = O_RDWR; ph_mode_app = 1; ph_mode_create = 1; return 1; }
    if (c == 'x') { ph_mode_rw = O_WRONLY; if (plus) ph_mode_rw = O_RDWR; ph_mode_create = 1; ph_mode_excl = 1; return 1; }
    if (c == 'c') { ph_mode_rw = O_WRONLY; if (plus) ph_mode_rw = O_RDWR; ph_mode_create = 1; return 1; }
    return 0;
}

i64 php_streq_c(uptr s, uptr lit, i64 n) {
    if (php_strlen(s) != n) return 0;
    i64 i = 0;
    loop { if (i >= n) break; if (ld8(s + ZS_HDR + i) != ld8(lit + i)) return 0; i = i + 1; }
    return 1;
}

uptr php_f_fopen(uptr pz, uptr mz, uptr uz, uptr cz) {
    uptr ps = php_zv_str(pz);
    uptr p = ps + ZS_HDR;
    uptr ms = php_zv_str(mz);
    // php://stdout and friends: the three the corpus uses
    if (php_streq_c(ps, "php://stdout", 12)) return php_zres(php_fh_new(1, p, 0));
    if (php_streq_c(ps, "php://output", 12)) return php_zres(php_fh_new(1, p, 0));
    if (php_streq_c(ps, "php://stderr", 12)) return php_zres(php_fh_new(2, p, 0));
    if (php_streq_c(ps, "php://stdin", 11))  return php_zres(php_fh_new(0, p, 0));
    if (!php_parse_mode(ms + ZS_HDR, php_strlen(ms))) {
        php_mreset();
        php_mc("fopen(): Argument #2 ($mode) must be a valid mode");
        php_raise_m(PHE_WARNING);
        return php_zbool(0);
    }
    i64 have = php_file_exists_c(p);
    if (ph_mode_excl && have) {
        php_mreset();
        php_mc("fopen(");
        php_mput(p, php_strlen(ps));
        php_mc("): Failed to open stream: File exists");
        php_raise_m(PHE_WARNING);
        return php_zbool(0);
    }
    if (!have && !ph_mode_create) {
        php_mreset();
        php_mc("fopen(");
        php_mput(p, php_strlen(ps));
        php_mc("): Failed to open stream: No such file or directory");
        php_raise_m(PHE_WARNING);
        return php_zbool(0);
    }
    // create or truncate with creat(), which is the non-variadic road
    if (ph_mode_create) {
        if (!have || ph_mode_trunc) {
            i64 cf = creat(p, 420);
            if (cf < 0) {
                php_mreset();
                php_mc("fopen(");
                php_mput(p, php_strlen(ps));
                php_mc("): Failed to open stream: Permission denied");
                php_raise_m(PHE_WARNING);
                return php_zbool(0);
            }
            close(cf);
        }
    }
    i64 fl = ph_mode_rw;
    if (ph_mode_app) fl = fl | O_APPEND;
    i64 fd = open(p, fl, 0);
    if (fd < 0) {
        php_mreset();
        php_mc("fopen(");
        php_mput(p, php_strlen(ps));
        php_mc("): Failed to open stream: No such file or directory");
        php_raise_m(PHE_WARNING);
        return php_zbool(0);
    }
    i64 id = php_fh_new(fd, p, 1);
    if (id < 0) { close(fd); return php_zbool(0); }
    return php_zres(id);
}

u8 php_f_fclose(uptr rz) {
    i64 i = php_res_id(rz);
    if (i < 0) return 0;
    if (ld64(ph_fh_own + i * 8)) close(ld64(ph_fh_fd + i * 8));
    st64(ph_fh_fd + i * 8, 0 - 1);
    return 1;
}

uptr php_f_fwrite(uptr rz, uptr sz, uptr lz) {
    i64 i = php_res_id(rz);
    if (i < 0) return php_zbool(0);
    uptr s = php_zv_str(sz);
    i64 n = php_strlen(s);
    if (lz) { if (php_zv_type(lz) != IS_NULL) { i64 l = php_zv_long(lz); if (l < n) n = l; } }
    php_flush();
    i64 w = write(ld64(ph_fh_fd + i * 8), s + ZS_HDR, n);
    if (w < 0) return php_zbool(0);
    return php_zlong(w);
}

uptr php_f_fread(uptr rz, uptr lz) {
    i64 i = php_res_id(rz);
    if (i < 0) return php_zbool(0);
    i64 n = php_zv_long(lz);
    if (n < 1) {
        php_mreset();
        php_mc("fread(): Argument #2 ($length) must be greater than 0");
        php_raise_m(PHE_WARNING);
        return php_zbool(0);
    }
    uptr o = php_str_alloc(n);
    i64 got = read(ld64(ph_fh_fd + i * 8), o + ZS_HDR, n);
    if (got < 0) got = 0;
    if (!got) st64(ph_fh_eof + i * 8, 1);
    st64(o + 16, got);
    st8(o + ZS_HDR + got, 0);
    return php_zstr(o);
}

// fgets reads one byte at a time: there is no buffered stream here and a
// shared descriptor must not be read past its line
uptr php_f_fgets(uptr rz, uptr lz) {
    i64 i = php_res_id(rz);
    if (i < 0) return php_zbool(0);
    i64 cap = 8192;
    if (lz) { if (php_zv_type(lz) != IS_NULL) { i64 l = php_zv_long(lz); if (l > 1) cap = l - 1; } }
    uptr o = php_str_alloc(cap);
    i64 n = 0;
    i64 fd = ld64(ph_fh_fd + i * 8);
    loop {
        if (n >= cap) break;
        u8 b[8];
        i64 g = read(fd, b, 1);
        if (g < 1) { if (!n) st64(ph_fh_eof + i * 8, 1); break; }
        st8(o + ZS_HDR + n, ld8(b));
        n = n + 1;
        if (ld8(b) == 10) break;
    }
    if (!n) return php_zbool(0);
    st64(o + 16, n);
    st8(o + ZS_HDR + n, 0);
    return php_zstr(o);
}

uptr php_f_fgetc(uptr rz) {
    i64 i = php_res_id(rz);
    if (i < 0) return php_zbool(0);
    u8 b[8];
    i64 g = read(ld64(ph_fh_fd + i * 8), b, 1);
    if (g < 1) { st64(ph_fh_eof + i * 8, 1); return php_zbool(0); }
    return php_zstr(php_str_new(b, 1));
}

u8 php_f_feof(uptr rz) {
    i64 i = php_res_id(rz);
    if (i < 0) return 1;
    if (ld64(ph_fh_eof + i * 8)) return 1;
    // php's feof is "a read has already hit the end", and so is this one:
    // the position against the size is the same answer for a regular file
    i64 fd = ld64(ph_fh_fd + i * 8);
    i64 cur = lseek(fd, 0, 1);
    if (cur < 0) return 0;
    i64 end = lseek(fd, 0, 2);
    lseek(fd, cur, 0);
    if (cur >= end) return 1;
    return 0;
}

i64 php_f_fseek(uptr rz, uptr oz, uptr wz) {
    i64 i = php_res_id(rz);
    if (i < 0) return 0 - 1;
    i64 w = 0;
    if (wz) { if (php_zv_type(wz) != IS_NULL) w = php_zv_long(wz); }
    if (lseek(ld64(ph_fh_fd + i * 8), php_zv_long(oz), w) < 0) return 0 - 1;
    st64(ph_fh_eof + i * 8, 0);
    return 0;
}

uptr php_f_ftell(uptr rz) {
    i64 i = php_res_id(rz);
    if (i < 0) return php_zbool(0);
    i64 p = lseek(ld64(ph_fh_fd + i * 8), 0, 1);
    if (p < 0) return php_zbool(0);
    return php_zlong(p);
}

u8 php_f_rewind(uptr rz) {
    i64 i = php_res_id(rz);
    if (i < 0) return 0;
    if (lseek(ld64(ph_fh_fd + i * 8), 0, 0) < 0) return 0;
    st64(ph_fh_eof + i * 8, 0);
    return 1;
}

u8 php_f_fflush(uptr rz) { php_flush(); return 1; }
u8 php_f_flock(uptr rz, uptr oz) { return 1; }

u8 php_f_is_resource(uptr z) { if (php_zv_type(z) == IS_RESOURCE) return 1; return 0; }

// the whole file, read in one go
uptr php_read_whole(uptr p) {
    i64 fd = open(p, O_RDONLY, 0);
    if (fd < 0) return 0;
    i64 n = lseek(fd, 0, 2);
    lseek(fd, 0, 0);
    if (n < 0) n = 0;
    uptr o = php_str_alloc(n);
    i64 got = 0;
    loop {
        if (got >= n) break;
        i64 g = read(fd, o + ZS_HDR + got, n - got);
        if (g < 1) break;
        got = got + g;
    }
    close(fd);
    st64(o + 16, got);
    st8(o + ZS_HDR + got, 0);
    return o;
}

uptr php_f_file_get_contents(uptr pz) {
    uptr ps = php_zv_str(pz);
    uptr o = php_read_whole(ps + ZS_HDR);
    if (!o) {
        php_mreset();
        php_mc("file_get_contents(");
        php_mput(ps + ZS_HDR, php_strlen(ps));
        php_mc("): Failed to open stream: No such file or directory");
        php_raise_m(PHE_WARNING);
        return php_zbool(0);
    }
    return php_zstr(o);
}

uptr php_f_file_put_contents(uptr pz, uptr dz, uptr fz) {
    uptr ps = php_zv_str(pz);
    uptr p = ps + ZS_HDR;
    uptr d = 0;
    if (php_zv_type(dz) == IS_ARRAY) {
        // php joins an array with no separator
        uptr a = ld64(dz);
        i64 used = php_ht_used(a);
        uptr acc = php_str_new("", 0);
        i64 i = 0;
        loop {
            if (i >= used) break;
            uptr b = php_ht_bkt(a, i);
            if (ld8(b + 8) != IS_UNDEF) acc = php_str_concat(acc, php_zv_str(b));
            i = i + 1;
        }
        d = acc;
    }
    if (!d) d = php_zv_str(dz);
    i64 app = 0;
    if (fz) { if (php_zv_type(fz) != IS_NULL) { if (php_zv_long(fz) & 8) app = 1; } }
    i64 fd = 0 - 1;
    if (app && php_file_exists_c(p)) fd = open(p, O_WRONLY | O_APPEND, 0);
    if (fd < 0) {
        i64 cf = creat(p, 420);
        if (cf < 0) {
            php_mreset();
            php_mc("file_put_contents(");
            php_mput(p, php_strlen(ps));
            php_mc("): Failed to open stream: No such file or directory");
            php_raise_m(PHE_WARNING);
            return php_zbool(0);
        }
        fd = cf;
    }
    i64 n = php_strlen(d);
    i64 w = write(fd, d + ZS_HDR, n);
    close(fd);
    if (w < 0) return php_zbool(0);
    return php_zlong(w);
}

uptr php_f_file(uptr pz, uptr fz) {
    uptr ps = php_zv_str(pz);
    uptr o = php_read_whole(ps + ZS_HDR);
    if (!o) {
        php_mreset();
        php_mc("file(");
        php_mput(ps + ZS_HDR, php_strlen(ps));
        php_mc("): Failed to open stream: No such file or directory");
        php_raise_m(PHE_WARNING);
        return php_zbool(0);
    }
    i64 flags = 0;
    if (fz) { if (php_zv_type(fz) != IS_NULL) flags = php_zv_long(fz); }
    uptr a = php_arr_new(8);
    i64 n = php_strlen(o);
    i64 st = 0;
    loop {
        if (st >= n) break;
        i64 e = st;
        loop { if (e >= n) break; if (ld8(o + ZS_HDR + e) == 10) break; e = e + 1; }
        i64 len = e - st;
        if (e < n && !(flags & 2)) len = len + 1;            // keep the \n
        uptr ln = php_str_new(o + ZS_HDR + st, len);
        i64 skip = 0;
        if ((flags & 4) && !php_strlen(ln)) skip = 1;
        if (!skip) php_arr_push(a, php_zstr(ln));
        st = e + 1;
    }
    return php_zarr(a);
}

uptr php_f_readfile(uptr pz) {
    uptr r = php_f_file_get_contents(pz);
    if (php_zv_type(r) != IS_STRING) return php_zbool(0);
    uptr s = ld64(r);
    php_echo_str(s);
    return php_zlong(php_strlen(s));
}

u8 php_f_unlink(uptr pz) {
    uptr ps = php_zv_str(pz);
    if (unlink(ps + ZS_HDR) == 0) return 1;
    php_mreset();
    php_mc("unlink(");
    php_mput(ps + ZS_HDR, php_strlen(ps));
    php_mc("): No such file or directory");
    php_raise_m(PHE_WARNING);
    return 0;
}

u8 php_f_rename(uptr az, uptr bz) {
    if (rename(php_zv_str(az) + ZS_HDR, php_zv_str(bz) + ZS_HDR) == 0) return 1;
    return 0;
}

u8 php_f_copy(uptr az, uptr bz) {
    uptr o = php_read_whole(php_zv_str(az) + ZS_HDR);
    if (!o) return 0;
    i64 fd = creat(php_zv_str(bz) + ZS_HDR, 420);
    if (fd < 0) return 0;
    write(fd, o + ZS_HDR, php_strlen(o));
    close(fd);
    return 1;
}

u8 php_f_file_exists(uptr pz) { return php_file_exists_c(php_zv_str(pz) + ZS_HDR); }

u8 php_f_is_file(uptr pz) {
    i64 m = php_stat_mode(php_zv_str(pz) + ZS_HDR);
    if (m < 0) return 0;
    if ((m & S_IFMT) == S_IFREG) return 1;
    return 0;
}

// set_error_handler(callable, levels) -> the previous handler or null.
// register/restore is a one-deep stack, which is what the corpus uses.
uptr php_f_set_error_handler(uptr hz, uptr lz) {
    uptr old = ph_ehz;
    ph_ehprev = old;
    ph_ehmask = 32767;
    if (lz) { if (php_zv_type(lz) != IS_NULL) ph_ehmask = php_zv_long(lz); }
    if (!hz) ph_ehz = 0;
    if (hz) { if (php_zv_type(hz) == IS_NULL) ph_ehz = 0; }
    if (hz) { if (php_zv_type(hz) != IS_NULL) ph_ehz = hz; }
    if (!old) return php_znull();
    return old;
}

u8 php_f_restore_error_handler() {
    ph_ehz = ph_ehprev;
    ph_ehprev = 0;
    return 1;
}

// set_exception_handler(): the callable an UNCAUGHT throwable reaches
uptr ph_xhz;
uptr ph_xhprev;

uptr php_f_set_exception_handler(uptr hz) {
    uptr old = ph_xhz;
    ph_xhprev = old;
    ph_xhz = 0;
    if (hz) { if (php_zv_type(hz) != IS_NULL) ph_xhz = hz; }
    if (!old) return php_znull();
    return old;
}

u8 php_f_restore_exception_handler() {
    ph_xhz = ph_xhprev;
    ph_xhprev = 0;
    return 1;
}

// setlocale(category, ...locales): EVERY request and every query goes to the
// host's setlocale(3), which is the same function php calls, so the two agree
// on every host by construction rather than by a table here.
//
// It was macOS's answer hard-coded until the hosts branch -- "C" for "C" and
// for "", false for anything else -- and that is wrong three ways, each
// measured: musl ACCEPTS an unknown name and hands it back where macOS and
// glibc answer NULL (tests/g/58-sscanf.php, which is what caught it); `""`
// means "take the environment" and php answers what LANG says, not "C"; and a
// "C" that never reaches libc does not RESET it, so after an accepted
// non-C locale the next query reported the old one where php reports "C".
//
// This runtime is still byte-oriented (D10) and implements no locale of its
// own: what changes is only what it reports, which is what php reports.
//
// The category number reaches libc unchanged, which is why php's LC_* are the
// host's numbers too (src/consts.mc, ph_lc_bsd and ph_lc_gnu).
// sscanf($str, $format): php's own C-like scanner. With no extra arguments
// it answers an array of the conversions; a directive that finds nothing
// yields null, and a literal that does not match stops the scan.
i64 ph_sc_p;
uptr ph_sc_s;
i64 ph_sc_n;

// a scanset is `a-z` (a dash range), not trim's `a..z`
i64 php_scanset(uptr set, i64 c) {
    i64 n = php_strlen(set);
    uptr b = set + ZS_HDR;
    i64 i = 0;
    loop {
        if (i >= n) break;
        if (i + 2 < n) {
            if (ld8(b + i + 1) == 45) {
                if (c >= ld8(b + i) && c <= ld8(b + i + 2)) return 1;
                i = i + 3;
                continue;
            }
        }
        if (ld8(b + i) == c) return 1;
        i = i + 1;
    }
    return 0;
}

i64 php_sc_ws(i64 c) { if (c == 32 || c == 9 || c == 10 || c == 13 || c == 11 || c == 12) return 1; return 0; }

void php_sc_skipws() {
    loop {
        if (ph_sc_p >= ph_sc_n) break;
        if (!php_sc_ws(ld8(ph_sc_s + ph_sc_p))) break;
        ph_sc_p = ph_sc_p + 1;
    }
}

uptr php_f_sscanf(uptr sz, uptr fz, uptr a1, uptr a2, uptr a3, uptr a4, uptr a5, uptr a6) {
    uptr str = php_zv_str(sz);
    uptr fmt = php_zv_str(fz);
    ph_sc_s = str + ZS_HDR;
    ph_sc_n = php_strlen(str);
    ph_sc_p = 0;
    uptr out = php_arr_new(8);
    uptr f = fmt + ZS_HDR;
    i64 fn = php_strlen(fmt);
    i64 i = 0;
    loop {
        if (i >= fn) break;
        i64 fc = ld8(f + i);
        if (php_sc_ws(fc)) { php_sc_skipws(); i = i + 1; continue; }
        if (fc != 37) {
            if (ph_sc_p >= ph_sc_n) break;
            if (ld8(ph_sc_s + ph_sc_p) != fc) break;
            ph_sc_p = ph_sc_p + 1;
            i = i + 1;
            continue;
        }
        i = i + 1;
        if (i >= fn) break;
        if (ld8(f + i) == 37) {
            if (ph_sc_p >= ph_sc_n) break;
            if (ld8(ph_sc_s + ph_sc_p) != 37) break;
            ph_sc_p = ph_sc_p + 1;
            i = i + 1;
            continue;
        }
        i64 width = 0 - 1;
        loop {
            if (i >= fn) break;
            i64 d = ld8(f + i);
            if (d < 48 || d > 57) break;
            if (width < 0) width = 0;
            width = width * 10 + (d - 48);
            i = i + 1;
        }
        if (i >= fn) break;
        i64 conv = ld8(f + i);
        i = i + 1;
        if (conv != 99) php_sc_skipws();                  // %c does not skip
        i64 st = ph_sc_p;
        if (conv == 100 || conv == 105 || conv == 117) {  // d i u
            if (ph_sc_p < ph_sc_n) { i64 sg = ld8(ph_sc_s + ph_sc_p); if (sg == 45 || sg == 43) ph_sc_p = ph_sc_p + 1; }
            loop {
                if (ph_sc_p >= ph_sc_n) break;
                if (width >= 0 && ph_sc_p - st >= width) break;
                i64 d = ld8(ph_sc_s + ph_sc_p);
                if (d < 48 || d > 57) break;
                ph_sc_p = ph_sc_p + 1;
            }
            if (ph_sc_p == st) { php_arr_push(out, php_znull()); break; }
            php_arr_push(out, php_zlong(php_stoi(php_str_new(ph_sc_s + st, ph_sc_p - st))));
            continue;
        }
        if (conv == 120 || conv == 88 || conv == 111 || conv == 98) {   // x X o b
            i64 base = 16;
            if (conv == 111) base = 8;
            if (conv == 98) base = 2;
            i64 v = 0;
            loop {
                if (ph_sc_p >= ph_sc_n) break;
                if (width >= 0 && ph_sc_p - st >= width) break;
                i64 d = ld8(ph_sc_s + ph_sc_p);
                i64 dv = 0 - 1;
                if (d >= 48 && d <= 57) dv = d - 48;
                if (d >= 97 && d <= 102) dv = d - 87;
                if (d >= 65 && d <= 70) dv = d - 55;
                if (dv < 0 || dv >= base) break;
                v = v * base + dv;
                ph_sc_p = ph_sc_p + 1;
            }
            if (ph_sc_p == st) { php_arr_push(out, php_znull()); break; }
            php_arr_push(out, php_zlong(v));
            continue;
        }
        if (conv == 101 || conv == 102 || conv == 103 || conv == 69 || conv == 71) {   // e f g
            if (ph_sc_p < ph_sc_n) { i64 sg = ld8(ph_sc_s + ph_sc_p); if (sg == 45 || sg == 43) ph_sc_p = ph_sc_p + 1; }
            loop {
                if (ph_sc_p >= ph_sc_n) break;
                if (width >= 0 && ph_sc_p - st >= width) break;
                i64 d = ld8(ph_sc_s + ph_sc_p);
                if (d >= 48 && d <= 57) { ph_sc_p = ph_sc_p + 1; continue; }
                if (d == 46) { ph_sc_p = ph_sc_p + 1; continue; }
                if (d == 101 || d == 69) {
                    i64 j = ph_sc_p + 1;
                    if (j < ph_sc_n) { i64 g = ld8(ph_sc_s + j); if (g == 43 || g == 45) j = j + 1; }
                    if (j < ph_sc_n) { i64 g2 = ld8(ph_sc_s + j); if (g2 >= 48 && g2 <= 57) { ph_sc_p = j; continue; } }
                }
                break;
            }
            if (ph_sc_p == st) { php_arr_push(out, php_znull()); break; }
            php_arr_push(out, php_zdouble(php_stof(php_str_new(ph_sc_s + st, ph_sc_p - st))));
            continue;
        }
        if (conv == 99) {                                  // c
            i64 w = 1;
            if (width > 0) w = width;
            if (ph_sc_p + w > ph_sc_n) { php_arr_push(out, php_znull()); break; }
            php_arr_push(out, php_zstr(php_str_new(ph_sc_s + ph_sc_p, w)));
            ph_sc_p = ph_sc_p + w;
            continue;
        }
        if (conv == 115) {                                 // s
            loop {
                if (ph_sc_p >= ph_sc_n) break;
                if (width >= 0 && ph_sc_p - st >= width) break;
                if (php_sc_ws(ld8(ph_sc_s + ph_sc_p))) break;
                ph_sc_p = ph_sc_p + 1;
            }
            if (ph_sc_p == st) { php_arr_push(out, php_znull()); break; }
            php_arr_push(out, php_zstr(php_str_new(ph_sc_s + st, ph_sc_p - st)));
            continue;
        }
        if (conv == 91) {                                  // [set]
            i64 neg = 0;
            if (i < fn) { if (ld8(f + i) == 94) { neg = 1; i = i + 1; } }
            i64 sb = i;
            loop { if (i >= fn) break; if (ld8(f + i) == 93 && i > sb) break; i = i + 1; }
            uptr set = php_str_new(f + sb, i - sb);
            if (i < fn) i = i + 1;                         // the ]
            loop {
                if (ph_sc_p >= ph_sc_n) break;
                if (width >= 0 && ph_sc_p - st >= width) break;
                i64 inx = php_scanset(set, ld8(ph_sc_s + ph_sc_p));
                if (neg) { if (inx) break; }
                if (!neg) { if (!inx) break; }
                ph_sc_p = ph_sc_p + 1;
            }
            if (ph_sc_p == st) { php_arr_push(out, php_znull()); break; }
            php_arr_push(out, php_zstr(php_str_new(ph_sc_s + st, ph_sc_p - st)));
            continue;
        }
        break;
    }
    // with extra arguments php writes THROUGH them and answers the count
    // php_zundef() is what the call site passes for an output slot it did
    // not write, and a NULL is a variable that WAS passed and happens to be
    // null -- which is every undefined `$out` at its first use. Testing for
    // null here made `sscanf($s, $f, $w, $v)` answer the array instead of
    // writing through, which is the whole point of the extra arguments.
    i64 extra = 0;
    if (a1) { if (php_zv_type(a1) != IS_UNDEF) extra = 1; }
    if (!extra) return php_zarr(out);
    uptr h = ld64(php_zarr(out));
    i64 k = 0;
    i64 idx = php_it_next(h, 0);
    loop {
        if (k >= 6) break;
        uptr tgt = a1;
        if (k == 1) tgt = a2;
        if (k == 2) tgt = a3;
        if (k == 3) tgt = a4;
        if (k == 4) tgt = a5;
        if (k == 5) tgt = a6;
        if (!tgt) break;
        if (php_zv_type(tgt) == IS_UNDEF) break;
        if (idx < 0) break;
        php_zv_cp(tgt, php_it_val(h, idx));
        idx = php_it_next(h, idx + 1);
        k = k + 1;
    }
    return php_zlong(k);
}

uptr php_locale_now(uptr cz, uptr c) {
    uptr r = php_setlocale(php_zv_long(cz), 0);
    if (!r) return php_zstr(c);
    return php_zstr(php_str_new(r, php_cstrlen(r)));
}

uptr php_f_setlocale(uptr cz, uptr a1, uptr a2, uptr a3, uptr a4, uptr a5) {
    uptr c = php_str_new("C", 1);
    // A QUERY -- setlocale($cat), setlocale($cat, null), setlocale($cat, 0) --
    // is "what is set now", and what is set now is the host's answer: the call
    // above may have set something this runtime does not implement but the
    // host's libc accepted, and php reports that. Answering "C" here made the
    // query disagree with php on musl after exactly such a call.
    if (!a1) return php_locale_now(cz, c);
    if (php_zv_type(a1) == IS_NULL) return php_locale_now(cz, c);
    if (php_zv_type(a1) == IS_LONG) { if (ld64(a1) == 0) return php_locale_now(cz, c); }
    i64 k = 0;
    loop {
        if (k >= 5) break;
        uptr v = a1;
        if (k == 1) v = a2;
        if (k == 2) v = a3;
        if (k == 3) v = a4;
        if (k == 4) v = a5;
        if (!v) break;
        // a missing optional argument arrives as php_znull() on the library
        // road, not as 0
        if (php_zv_type(v) == IS_NULL) break;
        if (php_zv_type(v) == IS_ARRAY) {
            uptr h = ld64(v);
            i64 i = php_it_next(h, 0);
            loop {
                if (i < 0) break;
                uptr ra = php_setlocale(php_zv_long(cz), php_zv_str(php_it_val(h, i)) + ZS_HDR);
                if (ra) return php_zstr(php_str_new(ra, php_cstrlen(ra)));
                i = php_it_next(h, i + 1);
            }
            k = k + 1;
            continue;
        }
        uptr r = php_setlocale(php_zv_long(cz), php_zv_str(v) + ZS_HDR);
        if (r) return php_zstr(php_str_new(r, php_cstrlen(r)));
        k = k + 1;
    }
    return php_zbool(0);
}

uptr php_f_getcwd() {
    uptr b = php_alloc(4096);
    if (!getcwd(b, 4096)) return php_zbool(0);
    return php_zstr(php_str_new(b, php_cstrlen(b)));
}

u8 php_f_chdir(uptr pz) {
    uptr p = php_zv_str(pz) + ZS_HDR;
    if (chdir(p) != 0) {
        php_warn2("chdir(): No such file or directory (errno 2)", "");
        return 0;
    }
    return 1;
}

u8 php_f_chmod(uptr pz, uptr mz) {
    if (chmod(php_zv_str(pz) + ZS_HDR, php_zv_long(mz)) != 0) return 0;
    return 1;
}

// putenv("K=V") and putenv("K") -- the second removes it, which is php's rule
u8 php_f_putenv(uptr sz) {
    uptr s = php_zv_str(sz);
    i64 n = php_strlen(s);
    i64 i = 0;
    loop { if (i >= n) break; if (ld8(s + ZS_HDR + i) == 61) break; i = i + 1; }
    if (i >= n) { unsetenv(s + ZS_HDR); return 1; }
    if (putenv(s + ZS_HDR) != 0) return 0;
    return 1;
}

u8 php_f_is_dir(uptr pz) {
    i64 m = php_stat_mode(php_zv_str(pz) + ZS_HDR);
    if (m < 0) return 0;
    if ((m & S_IFMT) == S_IFDIR) return 1;
    return 0;
}

u8 php_f_is_readable(uptr pz) { if (access(php_zv_str(pz) + ZS_HDR, 4) == 0) return 1; return 0; }
u8 php_f_is_writable(uptr pz) { if (access(php_zv_str(pz) + ZS_HDR, 2) == 0) return 1; return 0; }
u8 php_f_is_executable(uptr pz) { if (access(php_zv_str(pz) + ZS_HDR, 1) == 0) return 1; return 0; }

uptr php_f_filesize(uptr pz) {
    uptr ps = php_zv_str(pz);
    i64 n = php_stat_size(ps + ZS_HDR);
    if (n < 0) {
        php_mreset();
        php_mc("filesize(): stat failed for ");
        php_mput(ps + ZS_HDR, php_strlen(ps));
        php_raise_m(PHE_WARNING);
        return php_zbool(0);
    }
    return php_zlong(n);
}

u8 php_f_mkdir(uptr pz, uptr mz, uptr rz) {
    i64 m = 511;
    if (mz) { if (php_zv_type(mz) != IS_NULL) m = php_zv_long(mz); }
    if (mkdir(php_zv_str(pz) + ZS_HDR, m) == 0) return 1;
    return 0;
}

u8 php_f_rmdir(uptr pz) { if (rmdir(php_zv_str(pz) + ZS_HDR) == 0) return 1; return 0; }

u8 php_f_touch(uptr pz) {
    uptr p = php_zv_str(pz) + ZS_HDR;
    if (php_file_exists_c(p)) return 1;
    i64 fd = creat(p, 420);
    if (fd < 0) return 0;
    close(fd);
    return 1;
}

u8 php_f_clearstatcache(uptr a, uptr b) { return 1; }

uptr php_f_sys_get_temp_dir() {
    uptr e = getenv("TMPDIR");
    if (e) {
        i64 n = 0;
        loop { if (!ld8(e + n)) break; n = n + 1; }
        if (n > 1) { if (ld8(e + n - 1) == '/') n = n - 1; }
        return php_str_new(e, n);
    }
    return php_str_new("/tmp", 4);
}

// a counter, not a random: one process, and the name must not collide with
// its own earlier answers
i64 ph_tmpseq;

uptr php_f_tempnam(uptr dz, uptr pz) {
    uptr d = php_zv_str(dz);
    uptr p = php_zv_str(pz);
    if (!php_strlen(d)) d = php_f_sys_get_temp_dir();
    loop {
        ph_tmpseq = ph_tmpseq + 1;
        uptr nm = php_str_concat(d, php_str_new("/", 1));
        nm = php_str_concat(nm, p);
        nm = php_str_concat(nm, php_str_new("mcp", 3));
        nm = php_str_concat(nm, php_itos(getpid() * 100000 + ph_tmpseq));
        if (!php_file_exists_c(nm + ZS_HDR)) {
            i64 fd = creat(nm + ZS_HDR, 384);
            if (fd < 0) return php_zbool(0);
            close(fd);
            return php_zstr(nm);
        }
        if (ph_tmpseq > 100000) return php_zbool(0);
    }
    return php_zbool(0);
}

uptr php_f_tmpfile() {
    uptr nm = php_f_tempnam(php_zstr(php_str_new("", 0)), php_zstr(php_str_new("tmp", 3)));
    if (php_zv_type(nm) != IS_STRING) return php_zbool(0);
    uptr s = ld64(nm);
    i64 fd = open(s + ZS_HDR, O_RDWR, 0);
    if (fd < 0) return php_zbool(0);
    return php_zres(php_fh_new(fd, s + ZS_HDR, 1));
}

uptr php_f_getenv(uptr nz) {
    if (!nz) return php_zbool(0);
    if (php_zv_type(nz) == IS_NULL) return php_zbool(0);
    uptr e = getenv(php_zv_str(nz) + ZS_HDR);
    if (!e) return php_zbool(0);
    i64 n = 0;
    loop { if (!ld8(e + n)) break; n = n + 1; }
    return php_zstr(php_str_new(e, n));
}

// php resolves . and .. and makes the path absolute; an ABSOLUTE path that
// exists is already its own realpath, and a relative one needs the cwd,
// which this runtime does not have a call for -- so that case answers the
// path unchanged rather than a wrong absolute one.
uptr php_f_realpath(uptr pz) {
    uptr ps = php_zv_str(pz);
    if (!php_file_exists_c(ps + ZS_HDR)) return php_zbool(0);
    return php_zstr(ps);
}

uptr php_f_stream_get_contents(uptr rz) {
    i64 i = php_res_id(rz);
    if (i < 0) return php_zbool(0);
    i64 fd = ld64(ph_fh_fd + i * 8);
    uptr acc = php_str_new("", 0);
    loop {
        i64 g = read(fd, ph_rdbuf, 4096);
        if (g < 1) break;
        acc = php_str_concat(acc, php_str_new(ph_rdbuf, g));
    }
    st64(ph_fh_eof + i * 8, 1);
    return php_zstr(acc);
}

// ---- T8: the names the corpus asks for next --------------------------------

// settype($v, "int"): a by-reference write of a converted value. A by-ref
// argument is the caller's own zval since T8's first block, so this writes
// through it exactly as php does.
u8 php_f_settype(uptr vz, uptr tz) {
    uptr t = php_zv_str(tz);
    i64 n = php_strlen(t);
    uptr p = t + ZS_HDR;
    if (php_streq_c(t, "int", 3) || php_streq_c(t, "integer", 7)) {
        i64 v = php_zv_long(vz);
        st64(vz, v); php_zv_settype(vz, IS_LONG); return 1;
    }
    if (php_streq_c(t, "float", 5) || php_streq_c(t, "double", 6)) {
        f64 v = php_zv_double(vz);
        stf64(vz, v); php_zv_settype(vz, IS_DOUBLE); return 1;
    }
    if (php_streq_c(t, "string", 6)) {
        uptr v = php_zv_str(vz);
        st64(vz, v); php_zv_settype(vz, IS_STRING); return 1;
    }
    if (php_streq_c(t, "bool", 4) || php_streq_c(t, "boolean", 7)) {
        i64 v = php_zv_bool(vz);
        st64(vz, 0);
        if (v) php_zv_settype(vz, IS_TRUE);
        if (!v) php_zv_settype(vz, IS_FALSE);
        return 1;
    }
    if (php_streq_c(t, "array", 5)) {
        if (php_zv_type(vz) == IS_ARRAY) return 1;
        uptr a = php_arr_new(8);
        if (php_zv_type(vz) != IS_NULL) php_arr_push(a, php_zv_dup(vz));
        st64(vz, a); php_zv_settype(vz, IS_ARRAY); return 1;
    }
    if (php_streq_c(t, "null", 4)) { st64(vz, 0); php_zv_settype(vz, IS_NULL); return 1; }
    php_throw_str(php_str_new("ValueError", 10), php_str_new("settype(): Argument #2 ($type) must be a valid type", 51));
    return 0;
}

uptr php_f_str_decrement(uptr sz) {
    uptr s = php_zv_str(sz);
    i64 n = php_strlen(s);
    if (!n) {
        php_throw_str(php_str_new("ValueError", 10),
            php_str_new("str_decrement(): Argument #1 ($string) must not be empty", 56));
        return php_zstr(s);
    }
    uptr o = php_str_new(s + ZS_HDR, n);
    i64 i = n - 1;
    loop {
        if (i < 0) break;
        i64 c = ld8(o + ZS_HDR + i);
        if (c > 'a' && c <= 'z') { st8(o + ZS_HDR + i, c - 1); return php_zstr(o); }
        if (c > 'A' && c <= 'Z') { st8(o + ZS_HDR + i, c - 1); return php_zstr(o); }
        if (c > '0' && c <= '9') { st8(o + ZS_HDR + i, c - 1); return php_zstr(o); }
        if (c == 'a') { st8(o + ZS_HDR + i, 'z'); i = i - 1; continue; }
        if (c == 'A') { st8(o + ZS_HDR + i, 'Z'); i = i - 1; continue; }
        if (c == '0') { st8(o + ZS_HDR + i, '9'); i = i - 1; continue; }
        php_throw_str(php_str_new("ValueError", 10),
            php_str_new("str_decrement(): Argument #1 ($string) must be composed only of alphanumeric ASCII characters", 93));
        return php_zstr(s);
    }
    // every position wrapped: php drops the leading character
    if (php_strlen(o) > 1) return php_zstr(php_str_new(o + ZS_HDR + 1, php_strlen(o) - 1));
    return php_zstr(o);
}

// php normalises a numeric answer: "10" decrements to "9", not "09"
uptr php_f_str_decrement_n(uptr sz) {
    uptr r = php_f_str_decrement(sz);
    if (php_zv_type(r) != IS_STRING) return r;
    uptr o = ld64(r);
    i64 n = php_strlen(o);
    i64 alldig = 1;
    i64 i = 0;
    loop { if (i >= n) break; i64 c = ld8(o + ZS_HDR + i); if (c < 48 || c > 57) alldig = 0; i = i + 1; }
    if (!alldig) return r;
    i64 z = 0;
    loop { if (z >= n - 1) break; if (ld8(o + ZS_HDR + z) != 48) break; z = z + 1; }
    if (!z) return r;
    return php_zstr(php_str_new(o + ZS_HDR + z, n - z));
}

// array_splice(&$a, offset, length, replacement)
uptr php_f_array_splice(uptr az, uptr oz, uptr lz, uptr rz) {
    if (php_zv_type(az) != IS_ARRAY) return php_zarr(php_arr_new(8));
    uptr a = ld64(az);
    i64 n = php_count(a);
    i64 off = php_zv_long(oz);
    if (off < 0) { off = n + off; if (off < 0) off = 0; }
    if (off > n) off = n;
    i64 len = n - off;
    if (lz) { if (php_zv_type(lz) != IS_NULL) { len = php_zv_long(lz); if (len < 0) { len = n + len - off; if (len < 0) len = 0; } } }
    if (off + len > n) len = n - off;
    uptr cut = php_arr_new(8);
    uptr out = php_arr_new(8);
    i64 used = php_ht_used(a);
    i64 i = 0;
    i64 seen = 0;
    loop {
        if (i >= used) break;
        uptr b = php_ht_bkt(a, i);
        if (ld8(b + 8) != IS_UNDEF) {
            if (seen == off) {
                if (rz) {
                    if (php_zv_type(rz) == IS_ARRAY) {
                        uptr r = ld64(rz);
                        i64 ru = php_ht_used(r);
                        i64 j = 0;
                        loop {
                            if (j >= ru) break;
                            uptr rb = php_ht_bkt(r, j);
                            if (ld8(rb + 8) != IS_UNDEF) php_arr_push(out, rb);
                            j = j + 1;
                        }
                    }
                    if (php_zv_type(rz) != IS_ARRAY && php_zv_type(rz) != IS_NULL) php_arr_push(out, rz);
                }
            }
            if (seen >= off && seen < off + len) php_arr_push(cut, b);
            if (seen < off || seen >= off + len) {
                uptr k = ld64(b + 24);
                if (k) php_zv_cp(php_arr_sslot(out, k), b);
                if (!k) php_arr_push(out, b);
            }
            seen = seen + 1;
        }
        i = i + 1;
    }
    if (seen == off) {
        if (rz) {
            if (php_zv_type(rz) == IS_ARRAY) {
                uptr r = ld64(rz);
                i64 ru = php_ht_used(r);
                i64 j = 0;
                loop {
                    if (j >= ru) break;
                    uptr rb = php_ht_bkt(r, j);
                    if (ld8(rb + 8) != IS_UNDEF) php_arr_push(out, rb);
                    j = j + 1;
                }
            }
            if (php_zv_type(rz) != IS_ARRAY && php_zv_type(rz) != IS_NULL) php_arr_push(out, rz);
        }
    }
    st64(az, out);
    return php_zarr(cut);
}

// parse_str("a=1&b[]=2", $out)
uptr php_urldec_s(uptr s, i64 off, i64 n) {
    uptr o = php_str_alloc(n);
    i64 w = 0;
    i64 i = 0;
    loop {
        if (i >= n) break;
        i64 c = ld8(s + off + i);
        if (c == '+') { st8(o + ZS_HDR + w, ' '); w = w + 1; i = i + 1; continue; }
        if (c == '%' && i + 2 < n) {
            i64 h = php_hexval(ld8(s + off + i + 1));
            i64 l = php_hexval(ld8(s + off + i + 2));
            if (h >= 0 && l >= 0) { st8(o + ZS_HDR + w, h * 16 + l); w = w + 1; i = i + 3; continue; }
        }
        st8(o + ZS_HDR + w, c);
        w = w + 1;
        i = i + 1;
    }
    st64(o + 16, w);
    st8(o + ZS_HDR + w, 0);
    return o;
}

u8 php_f_parse_str(uptr sz, uptr oz) {
    uptr s = php_zv_str(sz);
    i64 n = php_strlen(s);
    uptr a = php_arr_new(8);
    i64 i = 0;
    loop {
        if (i >= n) break;
        i64 e = i;
        loop { if (e >= n) break; if (ld8(s + ZS_HDR + e) == '&') break; e = e + 1; }
        i64 eq = i;
        loop { if (eq >= e) break; if (ld8(s + ZS_HDR + eq) == '=') break; eq = eq + 1; }
        if (e > i) {
            uptr k = php_urldec_s(s + ZS_HDR, i, eq - i);
            uptr v = php_str_new("", 0);
            if (eq < e) v = php_urldec_s(s + ZS_HDR, eq + 1, e - eq - 1);
            // `name[]` appends, `name[k]` sets a key
            i64 kn = php_strlen(k);
            i64 br = 0;
            loop { if (br >= kn) break; if (ld8(k + ZS_HDR + br) == '[') break; br = br + 1; }
            if (br < kn && ld8(k + ZS_HDR + kn - 1) == ']') {
                uptr base = php_str_new(k + ZS_HDR, br);
                uptr inner = php_str_new(k + ZS_HDR + br + 1, kn - br - 2);
                uptr slot = php_arr_sslot(a, base);
                if (php_zv_type(slot) != IS_ARRAY) { st64(slot, php_arr_new(8)); php_zv_settype(slot, IS_ARRAY); }
                uptr sub = ld64(slot);
                if (!php_strlen(inner)) php_arr_push(sub, php_zstr(v));
                if (php_strlen(inner)) php_zv_cp(php_arr_sslot(sub, inner), php_zstr(v));
            }
            if (br >= kn || ld8(k + ZS_HDR + kn - 1) != ']') php_zv_cp(php_arr_sslot(a, k), php_zstr(v));
        }
        i = e + 1;
    }
    st64(oz, a);
    php_zv_settype(oz, IS_ARRAY);
    return 1;
}

// uniqid(): php's is the time in microseconds as 13 hex digits. There is no
// clock here, so it is a counter seeded by the pid -- unique within a
// process and between concurrent ones, which is what every use of it needs.
i64 ph_uniqseq;

uptr php_f_uniqid(uptr pz, uptr mz) {
    ph_uniqseq = ph_uniqseq + 1;
    i64 v = getpid() * 1048576 + ph_uniqseq;
    uptr o = php_str_alloc(13);
    i64 i = 12;
    loop {
        if (i < 0) break;
        i64 d = v & 15;
        i64 c = '0' + d;
        if (d > 9) c = 'a' + d - 10;
        st8(o + ZS_HDR + i, c);
        v = v / 16;
        i = i - 1;
    }
    st8(o + ZS_HDR + 13, 0);
    uptr pre = php_str_new("", 0);
    if (pz) { if (php_zv_type(pz) != IS_NULL) pre = php_zv_str(pz); }
    return php_zstr(php_str_concat(pre, o));
}

// ---- pack / unpack ---------------------------------------------------------
// php's binary packer. The codes are php's own list; the byte orders are
// spelled out rather than probed, because a compiled program must give the
// same answer on every host this compiler targets (docs/plan.md's rule for
// the string type applies to these bytes too). "machine" order is little
// endian on all five.
// a float's bytes: stf64/ldf64 over an 8-byte buffer is the reinterpret,
// and <float>'s f32 is what gives the 4-byte codes their IEEE single
i64 php_f64_bits(f64 x) { u8 b[8]; stf64(b, x); return ld64(b); }
f64 php_bits_f64(i64 v) { u8 b[8]; st64(b, v); return ldf64(b); }
i64 php_f32_bits(f64 x) { u8 b[8]; stf32(b, (f32) x); return ld32(b); }
f64 php_bits_f32(i64 v) { u8 b[8]; st32(b, v); return (f64) ldf32(b); }

uptr ph_pk;                          // the output, grown by php_pk_need
i64  ph_pkn;
i64  ph_pkc;

void php_pk_need(i64 n) {
    if (ph_pkn + n <= ph_pkc) return;
    i64 nc = ph_pkc * 2 + n + 64;
    uptr nb = php_alloc(nc);
    php_memcpy(nb, ph_pk, ph_pkn);
    ph_pk = nb;
    ph_pkc = nc;
}

void php_pk_b(i64 v) { php_pk_need(1); st8(ph_pk + ph_pkn, v & 255); ph_pkn = ph_pkn + 1; }

void php_pk_int(i64 v, i64 w, i64 be) {
    i64 i = 0;
    loop {
        if (i >= w) break;
        i64 sh = i * 8;
        if (be) sh = (w - 1 - i) * 8;
        php_pk_b(v >> sh);
        i = i + 1;
    }
}

// the repeater after a code: a count, `*`, or nothing (1)
i64 ph_pk_star;

i64 php_pk_rep(uptr f, i64 n, uptr pi) {
    i64 i = ld64(pi);
    ph_pk_star = 0;
    if (i < n && ld8(f + i) == '*') { ph_pk_star = 1; st64(pi, i + 1); return 0 - 1; }
    i64 v = 0;
    i64 got = 0;
    loop {
        if (i >= n) break;
        i64 c = ld8(f + i);
        if (c < 48 || c > 57) break;
        v = v * 10 + (c - 48);
        got = 1;
        i = i + 1;
    }
    st64(pi, i);
    if (!got) return 1;
    return v;
}

uptr php_f_pack(uptr fz, uptr az) {
    uptr f = php_zv_str(fz);
    i64 fn = php_strlen(f);
    uptr args = php_arr_new(8);
    if (az) { if (php_zv_type(az) == IS_ARRAY) args = ld64(az); }
    i64 na = php_count(args);
    ph_pk = 0;
    ph_pkn = 0;
    ph_pkc = 0;
    i64 ai = 0;
    u8 pi[8];
    st64(pi, 0);
    loop {
        i64 i = ld64(pi);
        if (i >= fn) break;
        i64 code = ld8(f + ZS_HDR + i);
        st64(pi, i + 1);
        i64 rep = php_pk_rep(f + ZS_HDR, fn, pi);
        i64 star = ph_pk_star;
        // the string codes take ONE argument and the repeater is a width
        if (code == 'a' || code == 'A' || code == 'Z') {
            if (ai >= na) break;
            uptr s = php_zv_str(php_arr_iget(args, ai));
            ai = ai + 1;
            i64 sl = php_strlen(s);
            i64 w = rep;
            if (star) { w = sl; if (code == 'Z') w = sl + 1; }
            i64 k = 0;
            loop {
                if (k >= w) break;
                i64 b = 0;
                if (code == 'A') b = ' ';
                if (k < sl) b = ld8(s + ZS_HDR + k);
                if (code == 'Z' && k == w - 1) b = 0;
                php_pk_b(b);
                k = k + 1;
            }
            continue;
        }
        if (code == 'h' || code == 'H') {
            if (ai >= na) break;
            uptr s = php_zv_str(php_arr_iget(args, ai));
            ai = ai + 1;
            i64 sl = php_strlen(s);
            i64 w = rep;
            if (star) w = sl;
            if (w > sl) w = sl;
            i64 k = 0;
            loop {
                if (k >= w) break;
                i64 hi = php_hexval(ld8(s + ZS_HDR + k));
                i64 lo = 0;
                if (k + 1 < w) lo = php_hexval(ld8(s + ZS_HDR + k + 1));
                if (hi < 0) hi = 0;
                if (lo < 0) lo = 0;
                if (code == 'H') php_pk_b(hi * 16 + lo);
                if (code == 'h') php_pk_b(lo * 16 + hi);
                k = k + 2;
            }
            continue;
        }
        if (code == 'x') { i64 k = 0; if (star) rep = 1; loop { if (k >= rep) break; php_pk_b(0); k = k + 1; } continue; }
        if (code == 'X') { i64 k = 0; if (star) rep = 1; loop { if (k >= rep) break; if (ph_pkn) ph_pkn = ph_pkn - 1; k = k + 1; } continue; }
        if (code == '@') { if (star) rep = 0; loop { if (ph_pkn >= rep) break; php_pk_b(0); } if (ph_pkn > rep) ph_pkn = rep; continue; }
        // the numeric codes take `rep` arguments
        i64 cnt = rep;
        if (star) cnt = na - ai;
        i64 k = 0;
        loop {
            if (k >= cnt) break;
            if (ai >= na) break;
            uptr z = php_arr_iget(args, ai);
            ai = ai + 1;
            if (code == 'c' || code == 'C') php_pk_int(php_zv_long(z), 1, 0);
            if (code == 's' || code == 'S' || code == 'v') php_pk_int(php_zv_long(z), 2, 0);
            if (code == 'n') php_pk_int(php_zv_long(z), 2, 1);
            if (code == 'i' || code == 'I' || code == 'l' || code == 'L' || code == 'V') php_pk_int(php_zv_long(z), 4, 0);
            if (code == 'N') php_pk_int(php_zv_long(z), 4, 1);
            if (code == 'q' || code == 'Q' || code == 'P') php_pk_int(php_zv_long(z), 8, 0);
            if (code == 'J') php_pk_int(php_zv_long(z), 8, 1);
            if (code == 'd' || code == 'e') php_pk_int(php_f64_bits(php_zv_double(z)), 8, 0);
            if (code == 'E') php_pk_int(php_f64_bits(php_zv_double(z)), 8, 1);
            if (code == 'f' || code == 'g') php_pk_int(php_f32_bits(php_zv_double(z)), 4, 0);
            if (code == 'G') php_pk_int(php_f32_bits(php_zv_double(z)), 4, 1);
            k = k + 1;
        }
    }
    return php_zstr(php_str_new(ph_pk, ph_pkn));
}

i64 php_unp_int(uptr s, i64 off, i64 w, i64 be, i64 sign) {
    i64 v = 0;
    i64 i = 0;
    loop {
        if (i >= w) break;
        i64 b = ld8(s + off + i);
        i64 sh = i * 8;
        if (be) sh = (w - 1 - i) * 8;
        v = v | (b << sh);
        i = i + 1;
    }
    if (sign && w < 8) {
        i64 top = 1 << (w * 8 - 1);
        if (v & top) v = v - (top * 2);
    }
    return v;
}

uptr php_f_unpack(uptr fz, uptr sz, uptr oz) {
    uptr f = php_zv_str(fz);
    uptr s = php_zv_str(sz);
    i64 fn = php_strlen(f);
    i64 sn = php_strlen(s);
    i64 pos = 0;
    if (oz) { if (php_zv_type(oz) != IS_NULL) pos = php_zv_long(oz); }
    if (pos < 0) pos = sn + pos;
    uptr out = php_arr_new(8);
    i64 i = 0;
    loop {
        if (i >= fn) break;
        i64 code = ld8(f + ZS_HDR + i);
        i = i + 1;
        u8 pi[8];
        st64(pi, i);
        i64 rep = php_pk_rep(f + ZS_HDR, fn, pi);
        i64 star = ph_pk_star;
        i = ld64(pi);
        // the name runs to the next `/`
        i64 ns = i;
        loop { if (i >= fn) break; if (ld8(f + ZS_HDR + i) == '/') break; i = i + 1; }
        uptr nm = php_str_new(f + ZS_HDR + ns, i - ns);
        if (i < fn) i = i + 1;
        i64 w = 0;
        i64 be = 0;
        i64 sign = 0;
        if (code == 'c') { w = 1; sign = 1; }
        if (code == 'C') w = 1;
        if (code == 's') { w = 2; sign = 1; }
        if (code == 'S' || code == 'v') w = 2;
        if (code == 'n') { w = 2; be = 1; }
        if (code == 'i' || code == 'l') { w = 4; sign = 1; }
        if (code == 'I' || code == 'L' || code == 'V') w = 4;
        if (code == 'N') { w = 4; be = 1; }
        if (code == 'q') { w = 8; sign = 1; }
        if (code == 'Q' || code == 'P') w = 8;
        if (code == 'J') { w = 8; be = 1; }
        if (code == 'a' || code == 'A' || code == 'Z') {
            i64 len = rep;
            if (star) len = sn - pos;
            if (pos + len > sn) len = sn - pos;
            if (len < 0) len = 0;
            i64 e = len;
            if (code == 'A') { loop { if (e < 1) break; i64 c = ld8(s + ZS_HDR + pos + e - 1); if (c != ' ' && c != 0 && c != 9 && c != 10 && c != 13) break; e = e - 1; } }
            if (code == 'Z') { e = 0; loop { if (e >= len) break; if (!ld8(s + ZS_HDR + pos + e)) break; e = e + 1; } }
            uptr key = nm;
            if (!php_strlen(key)) key = php_str_new("1", 1);
            php_zv_cp(php_arr_sslot(out, key), php_zstr(php_str_new(s + ZS_HDR + pos, e)));
            pos = pos + len;
            continue;
        }
        if (code == 'H' || code == 'h') {
            i64 len = rep;
            if (star) len = (sn - pos) * 2;
            i64 nb = (len + 1) / 2;
            if (pos + nb > sn) nb = sn - pos;
            if (nb < 0) nb = 0;
            uptr o = php_str_alloc(len);
            i64 k = 0;
            loop {
                if (k >= len) break;
                i64 b = ld8(s + ZS_HDR + pos + k / 2);
                i64 d = b >> 4;
                if (code == 'h') d = b & 15;
                if (k % 2) { d = b & 15; if (code == 'h') d = b >> 4; }
                i64 c = '0' + d;
                if (d > 9) c = 'a' + d - 10;
                st8(o + ZS_HDR + k, c);
                k = k + 1;
            }
            st64(o + 16, len);
            st8(o + ZS_HDR + len, 0);
            uptr key = nm;
            if (!php_strlen(key)) key = php_str_new("1", 1);
            php_zv_cp(php_arr_sslot(out, key), php_zstr(o));
            pos = pos + nb;
            continue;
        }
        if (code == 'x') { i64 n2 = rep; if (star) n2 = sn - pos; pos = pos + n2; continue; }
        if (code == 'X') { i64 n2 = rep; if (star) n2 = 1; pos = pos - n2; continue; }
        if (code == '@') { pos = rep; continue; }
        if (!w) {
            if (code == 'd' || code == 'e' || code == 'E') w = 8;
            if (code == 'f' || code == 'g' || code == 'G') w = 4;
            if (code == 'E' || code == 'G') be = 1;
        }
        if (!w) continue;
        i64 cnt = rep;
        if (star) cnt = (sn - pos) / w;
        i64 k = 0;
        loop {
            if (k >= cnt) break;
            if (pos + w > sn) break;
            uptr key = nm;
            // php numbers a repeated field from 1 and appends the index
            if (cnt > 1 || star) key = php_str_concat(nm, php_itos(k + 1));
            if (!php_strlen(key)) key = php_itos(k + 1);
            i64 raw = php_unp_int(s + ZS_HDR, pos, w, be, sign);
            uptr val = php_zlong(raw);
            if (code == 'd' || code == 'e' || code == 'E') val = php_zdouble(php_bits_f64(raw));
            if (code == 'f' || code == 'g' || code == 'G') val = php_zdouble(php_bits_f32(raw));
            php_zv_cp(php_arr_sslot(out, key), val);
            pos = pos + w;
            k = k + 1;
        }
    }
    return php_zarr(out);
}

// ---- T8: more of the library ----------------------------------------------

i64 php_hexdig_u(i64 d) { if (d < 10) return '0' + d; return 'A' + d - 10; }


// quoted-printable, RFC 2045
uptr php_f_quoted_printable_encode(uptr sz) {
    uptr s = php_zv_str(sz);
    i64 n = php_strlen(s);
    uptr o = php_str_alloc(n * 3 + 8);
    i64 w = 0;
    i64 i = 0;
    i64 col = 0;
    loop {
        if (i >= n) break;
        i64 c = ld8(s + ZS_HDR + i);
        i64 lit = 1;
        if (c < 33 || c > 126) lit = 0;
        if (c == '=') lit = 0;
        if (c == ' ' || c == 9) { lit = 1; if (i + 1 >= n || ld8(s + ZS_HDR + i + 1) == 13 || ld8(s + ZS_HDR + i + 1) == 10) lit = 0; }
        if (c == 13 || c == 10) {
            st8(o + ZS_HDR + w, c); w = w + 1; col = 0; i = i + 1; continue;
        }
        i64 need = 1;
        if (!lit) need = 3;
        if (col + need > 75) { st8(o + ZS_HDR + w, '='); st8(o + ZS_HDR + w + 1, 13); st8(o + ZS_HDR + w + 2, 10); w = w + 3; col = 0; }
        if (lit) { st8(o + ZS_HDR + w, c); w = w + 1; col = col + 1; }
        if (!lit) {
            st8(o + ZS_HDR + w, '=');
            st8(o + ZS_HDR + w + 1, php_hexdig_u(c >> 4));
            st8(o + ZS_HDR + w + 2, php_hexdig_u(c & 15));
            w = w + 3;
            col = col + 3;
        }
        i = i + 1;
    }
    st64(o + 16, w);
    st8(o + ZS_HDR + w, 0);
    return o;
}

uptr php_f_quoted_printable_decode(uptr sz) {
    uptr s = php_zv_str(sz);
    i64 n = php_strlen(s);
    uptr o = php_str_alloc(n);
    i64 w = 0;
    i64 i = 0;
    loop {
        if (i >= n) break;
        i64 c = ld8(s + ZS_HDR + i);
        if (c == '=' && i + 2 < n) {
            i64 h = php_hexval(ld8(s + ZS_HDR + i + 1));
            i64 l = php_hexval(ld8(s + ZS_HDR + i + 2));
            if (h >= 0 && l >= 0) { st8(o + ZS_HDR + w, h * 16 + l); w = w + 1; i = i + 3; continue; }
        }
        if (c == '=' && i + 1 < n) {
            if (ld8(s + ZS_HDR + i + 1) == 10) { i = i + 2; continue; }
            if (i + 2 < n && ld8(s + ZS_HDR + i + 1) == 13 && ld8(s + ZS_HDR + i + 2) == 10) { i = i + 3; continue; }
        }
        st8(o + ZS_HDR + w, c);
        w = w + 1;
        i = i + 1;
    }
    st64(o + 16, w);
    st8(o + ZS_HDR + w, 0);
    return o;
}

// uuencode, php's own line shape: a length character then groups of four
uptr php_f_convert_uuencode(uptr sz) {
    uptr s = php_zv_str(sz);
    i64 n = php_strlen(s);
    uptr o = php_str_alloc(n * 2 + 64);
    i64 w = 0;
    i64 i = 0;
    loop {
        if (i >= n) break;
        i64 ln = n - i;
        if (ln > 45) ln = 45;
        st8(o + ZS_HDR + w, 32 + ln);
        w = w + 1;
        i64 k = 0;
        loop {
            if (k >= ln) break;
            i64 b0 = ld8(s + ZS_HDR + i + k);
            i64 b1 = 0;
            i64 b2 = 0;
            if (k + 1 < ln) b1 = ld8(s + ZS_HDR + i + k + 1);
            if (k + 2 < ln) b2 = ld8(s + ZS_HDR + i + k + 2);
            i64 c0 = (b0 >> 2) & 63;
            i64 c1 = ((b0 << 4) | (b1 >> 4)) & 63;
            i64 c2 = ((b1 << 2) | (b2 >> 6)) & 63;
            i64 c3 = b2 & 63;
            st8(o + ZS_HDR + w, 32 + c0); if (!c0) st8(o + ZS_HDR + w, '`');
            st8(o + ZS_HDR + w + 1, 32 + c1); if (!c1) st8(o + ZS_HDR + w + 1, '`');
            st8(o + ZS_HDR + w + 2, 32 + c2); if (!c2) st8(o + ZS_HDR + w + 2, '`');
            st8(o + ZS_HDR + w + 3, 32 + c3); if (!c3) st8(o + ZS_HDR + w + 3, '`');
            w = w + 4;
            k = k + 3;
        }
        st8(o + ZS_HDR + w, 10);
        w = w + 1;
        i = i + ln;
    }
    st8(o + ZS_HDR + w, '`');
    st8(o + ZS_HDR + w + 1, 10);
    w = w + 2;
    st64(o + 16, w);
    st8(o + ZS_HDR + w, 0);
    return o;
}

uptr php_f_convert_uudecode(uptr sz) {
    uptr s = php_zv_str(sz);
    i64 n = php_strlen(s);
    uptr o = php_str_alloc(n);
    i64 w = 0;
    i64 i = 0;
    loop {
        if (i >= n) break;
        i64 ln = (ld8(s + ZS_HDR + i) - 32) & 63;
        i = i + 1;
        if (!ln) break;
        i64 got = 0;
        loop {
            if (got >= ln) break;
            if (i + 3 >= n + 1) break;
            i64 c0 = (ld8(s + ZS_HDR + i) - 32) & 63;
            i64 c1 = (ld8(s + ZS_HDR + i + 1) - 32) & 63;
            i64 c2 = (ld8(s + ZS_HDR + i + 2) - 32) & 63;
            i64 c3 = (ld8(s + ZS_HDR + i + 3) - 32) & 63;
            if (got < ln) { st8(o + ZS_HDR + w, (c0 << 2) | (c1 >> 4)); w = w + 1; got = got + 1; }
            if (got < ln) { st8(o + ZS_HDR + w, (c1 << 4) | (c2 >> 2)); w = w + 1; got = got + 1; }
            if (got < ln) { st8(o + ZS_HDR + w, (c2 << 6) | c3); w = w + 1; got = got + 1; }
            i = i + 4;
        }
        loop { if (i >= n) break; if (ld8(s + ZS_HDR + i) == 10) { i = i + 1; break; } i = i + 1; }
    }
    st64(o + 16, w);
    st8(o + ZS_HDR + w, 0);
    return o;
}

// str_getcsv: one line, php's quoting rules
uptr php_f_str_getcsv(uptr sz, uptr dz, uptr ez, uptr xz) {
    // php 8.4 deprecated leaving $escape to its default
    i64 hasx = 0;
    if (xz) { if (php_zv_type(xz) != IS_NULL) hasx = 1; }
    if (!hasx) php_depr1("str_getcsv(): the $escape parameter must be provided as its default value will change");
    uptr s = php_zv_str(sz);
    i64 n = php_strlen(s);
    i64 d = ',';
    i64 q = '"';
    if (dz) { if (php_zv_type(dz) != IS_NULL) { uptr t = php_zv_str(dz); if (php_strlen(t)) d = ld8(t + ZS_HDR); } }
    if (ez) { if (php_zv_type(ez) != IS_NULL) { uptr t = php_zv_str(ez); if (php_strlen(t)) q = ld8(t + ZS_HDR); } }
    uptr a = php_arr_new(8);
    if (!n) { php_arr_push(a, php_znull()); return a; }
    i64 i = 0;
    loop {
        uptr f = php_str_alloc(n);
        i64 w = 0;
        i64 inq = 0;
        loop {
            if (i >= n) break;
            i64 c = ld8(s + ZS_HDR + i);
            if (inq) {
                if (c == q) {
                    if (i + 1 < n && ld8(s + ZS_HDR + i + 1) == q) { st8(f + ZS_HDR + w, q); w = w + 1; i = i + 2; continue; }
                    inq = 0; i = i + 1; continue;
                }
                st8(f + ZS_HDR + w, c); w = w + 1; i = i + 1; continue;
            }
            if (c == q && !w) { inq = 1; i = i + 1; continue; }
            if (c == d) break;
            st8(f + ZS_HDR + w, c);
            w = w + 1;
            i = i + 1;
        }
        st64(f + 16, w);
        st8(f + ZS_HDR + w, 0);
        php_arr_push(a, php_zstr(f));
        if (i >= n) break;
        i = i + 1;                                // the delimiter
        if (i >= n) { php_arr_push(a, php_zstr(php_str_new("", 0))); break; }
    }
    return a;
}

// serialize / unserialize: php's own text format
void php_ser(uptr z, i64 depth);

void php_ser_str(uptr s) {
    php_write("s:", 2);
    php_echo_int(php_strlen(s));
    php_write(":\"", 2);
    php_write(s + ZS_HDR, php_strlen(s));
    php_write("\";", 2);
}

void php_ser(uptr z, i64 depth) {
    i64 t = php_zv_type(z);
    if (t == IS_NULL || t == IS_UNDEF) { php_write("N;", 2); return; }
    if (t == IS_TRUE) { php_write("b:1;", 4); return; }
    if (t == IS_FALSE) { php_write("b:0;", 4); return; }
    if (t == IS_LONG) { php_write("i:", 2); php_echo_int(ld64(z)); php_write(";", 1); return; }
    if (t == IS_DOUBLE) {
        php_write("d:", 2);
        u8 b[64];
        i64 n = php_fmt_f64(b, ldf64(z), 17);
        php_write(b, n);
        php_write(";", 1);
        return;
    }
    if (t == IS_STRING) { php_ser_str(ld64(z)); return; }
    if (t == IS_ARRAY) {
        uptr a = ld64(z);
        php_write("a:", 2);
        php_echo_int(php_count(a));
        php_write(":{", 2);
        i64 used = php_ht_used(a);
        i64 i = 0;
        loop {
            if (i >= used) break;
            uptr b = php_ht_bkt(a, i);
            if (ld8(b + 8) != IS_UNDEF) {
                uptr k = ld64(b + 24);
                if (k) php_ser_str(k);
                if (!k) { php_write("i:", 2); php_echo_int(ld64(b + 16)); php_write(";", 1); }
                php_ser(b, depth + 1);
            }
            i = i + 1;
        }
        php_write("}", 1);
        return;
    }
    if (t == IS_OBJECT) {
        uptr o = ld64(z);
        uptr cn = php_obj_cname(o);
        uptr pr = php_obj_props(o);
        php_write("O:", 2);
        php_echo_int(php_strlen(cn));
        php_write(":\"", 2);
        php_write(cn + ZS_HDR, php_strlen(cn));
        php_write("\":", 2);
        php_echo_int(php_count(pr));
        php_write(":{", 2);
        i64 used = php_ht_used(pr);
        i64 i = 0;
        loop {
            if (i >= used) break;
            uptr b = php_ht_bkt(pr, i);
            if (ld8(b + 8) != IS_UNDEF) {
                uptr k = ld64(b + 24);
                if (k) php_ser_str(k);
                if (!k) { php_write("i:", 2); php_echo_int(ld64(b + 16)); php_write(";", 1); }
                php_ser(b, depth + 1);
            }
            i = i + 1;
        }
        php_write("}", 1);
        return;
    }
    php_write("N;", 2);
}

// ---- json_encode / json_decode ---------------------------------------------
// ext/json is D2(a): it IS php and is written here. The text format is the
// one php writes -- `/` escaped, non-ASCII as \uXXXX by default, a float
// printed with serialize_precision -1 (the shortest round trip), and an
// array that is a LIST as [..] and anything else as {..}.
i64 ph_js_bad;                              // 1 when the input was not UTF-8

void php_js_hex4(i64 v) {
    php_write("\\u", 2);
    i64 i = 12;
    loop {
        if (i < 0) break;
        i64 d = (v >> i) & 15;
        u8 c[1];
        if (d < 10) st8(c, 48 + d);
        if (d >= 10) st8(c, 87 + d);
        php_write(c, 1);
        i = i - 4;
    }
}

void php_js_str(uptr s) {
    php_write("\"", 1);
    i64 n = php_strlen(s);
    uptr b = s + ZS_HDR;
    i64 i = 0;
    loop {
        if (i >= n) break;
        i64 c = ld8(b + i);
        if (c == 34) { php_write("\\\"", 2); i = i + 1; continue; }
        if (c == 92) { php_write("\\\\", 2); i = i + 1; continue; }
        if (c == 47) { php_write("\\/", 2); i = i + 1; continue; }
        if (c == 8)  { php_write("\\b", 2); i = i + 1; continue; }
        if (c == 12) { php_write("\\f", 2); i = i + 1; continue; }
        if (c == 10) { php_write("\\n", 2); i = i + 1; continue; }
        if (c == 13) { php_write("\\r", 2); i = i + 1; continue; }
        if (c == 9)  { php_write("\\t", 2); i = i + 1; continue; }
        if (c < 32) { php_js_hex4(c); i = i + 1; continue; }
        if (c < 128) { php_write(b + i, 1); i = i + 1; continue; }
        // a UTF-8 sequence becomes \uXXXX (and a surrogate pair past the BMP)
        i64 cp = 0 - 1;
        i64 len = 0;
        if (c >= 192 && c < 224) { cp = c - 192; len = 2; }
        if (c >= 224 && c < 240) { cp = c - 224; len = 3; }
        if (c >= 240 && c < 248) { cp = c - 240; len = 4; }
        if (len == 0 || i + len > n) { ph_js_bad = 1; return; }
        i64 k = 1;
        loop {
            if (k >= len) break;
            i64 cc = ld8(b + i + k);
            if (cc < 128 || cc >= 192) { ph_js_bad = 1; return; }
            cp = cp * 64 + (cc - 128);
            k = k + 1;
        }
        if (cp < 128) { ph_js_bad = 1; return; }
        if (len == 3 && cp < 2048) { ph_js_bad = 1; return; }
        if (len == 4 && cp < 65536) { ph_js_bad = 1; return; }
        if (cp >= 55296 && cp < 57344) { ph_js_bad = 1; return; }
        if (cp < 65536) php_js_hex4(cp);
        if (cp >= 65536) {
            i64 v = cp - 65536;
            php_js_hex4(55296 + (v >> 10));
            php_js_hex4(56320 + (v - (v >> 10) * 1024));
        }
        i = i + len;
    }
    php_write("\"", 1);
}

void php_js(uptr z, i64 depth) {
    i64 t = php_zv_type(z);
    if (t == IS_NULL || t == IS_UNDEF) { php_write("null", 4); return; }
    if (t == IS_TRUE)  { php_write("true", 4); return; }
    if (t == IS_FALSE) { php_write("false", 5); return; }
    if (t == IS_LONG)  { php_echo_int(ld64(z)); return; }
    if (t == IS_DOUBLE) {
        f64 d = ldf64(z);
        if (ph_is_nan(d) || ph_is_inf(d)) { ph_js_bad = 2; php_write("0", 1); return; }
        u8 b[64];
        i64 n = php_fmt_f64(b, d, 17);
        php_write(b, n);
        // php writes an integral double with no fraction: 1.0 -> 1
        return;
    }
    if (t == IS_STRING) { php_js_str(ld64(z)); return; }
    if (depth > 512) { ph_js_bad = 3; return; }
    uptr h = 0;
    i64 list = 0;
    if (t == IS_ARRAY) { h = ld64(z); list = php_f_array_is_list(z); }
    if (t == IS_OBJECT) h = php_obj_props(ld64(z));
    if (!h) { php_write("null", 4); return; }
    if (list) php_write("[", 1);
    if (!list) php_write("{", 1);
    i64 used = php_ht_used(h);
    i64 i = 0;
    i64 first = 1;
    loop {
        if (i >= used) break;
        uptr b = php_ht_bkt(h, i);
        if (ld8(b + 8) != IS_UNDEF) {
            if (!first) php_write(",", 1);
            first = 0;
            if (!list) {
                uptr k = ld64(b + 24);
                if (k) php_js_str(k);
                if (!k) php_js_str(php_itos(ld64(b + 16)));
                php_write(":", 1);
            }
            php_js(b, depth + 1);
        }
        i = i + 1;
    }
    if (list) php_write("]", 1);
    if (!list) php_write("}", 1);
}

uptr php_f_json_encode(uptr z, uptr flags, uptr depth) {
    ph_js_bad = 0;
    php_ob_start();
    php_js(z, 0);
    uptr r = php_ob_get();
    if (ph_js_bad) return php_zbool(0);
    return php_zstr(r);
}

uptr php_f_json_last_error_msg() {
    if (!ph_js_bad) return php_zstr(php_str_new("No error", 8));
    if (ph_js_bad == 1) return php_zstr(php_str_new("Malformed UTF-8 characters, possibly incorrectly encoded", 56));
    if (ph_js_bad == 2) return php_zstr(php_str_new("Inf and NaN cannot be JSON encoded", 34));
    if (ph_js_bad == 4) return php_zstr(php_str_new("Syntax error", 12));
    return php_zstr(php_str_new("Maximum stack depth exceeded", 28));
}

i64 php_f_json_last_error() {
    if (!ph_js_bad) return 0;
    if (ph_js_bad == 1) return 5;
    if (ph_js_bad == 2) return 7;
    if (ph_js_bad == 4) return 4;
    return 1;
}

// the reader: a cursor into the string, json's grammar
i64 ph_jd_p;
uptr ph_jd_s;
i64 ph_jd_n;
i64 ph_jd_bad;
i64 ph_jd_assoc;

uptr php_jd_val(i64 depth);

void php_jd_ws() {
    loop {
        if (ph_jd_p >= ph_jd_n) break;
        i64 c = ld8(ph_jd_s + ph_jd_p);
        if (c == 32 || c == 9 || c == 10 || c == 13) { ph_jd_p = ph_jd_p + 1; continue; }
        break;
    }
}

i64 php_jd_lit(uptr w, i64 n) {
    if (ph_jd_p + n > ph_jd_n) return 0;
    i64 i = 0;
    loop {
        if (i >= n) break;
        if (ld8(ph_jd_s + ph_jd_p + i) != ld8(w + i)) return 0;
        i = i + 1;
    }
    ph_jd_p = ph_jd_p + n;
    return 1;
}

void php_jd_utf8(uptr sb, uptr np, i64 cp) {
    i64 n = ld64(np);
    if (cp < 128) { st8(sb + n, cp); st64(np, n + 1); return; }
    if (cp < 2048) {
        st8(sb + n, 192 + (cp >> 6));
        st8(sb + n + 1, 128 + (cp - (cp >> 6) * 64));
        st64(np, n + 2);
        return;
    }
    if (cp < 65536) {
        st8(sb + n, 224 + (cp >> 12));
        st8(sb + n + 1, 128 + ((cp >> 6) - (cp >> 12) * 64));
        st8(sb + n + 2, 128 + (cp - (cp >> 6) * 64));
        st64(np, n + 3);
        return;
    }
    st8(sb + n, 240 + (cp >> 18));
    st8(sb + n + 1, 128 + ((cp >> 12) - (cp >> 18) * 64));
    st8(sb + n + 2, 128 + ((cp >> 6) - (cp >> 12) * 64));
    st8(sb + n + 3, 128 + (cp - (cp >> 6) * 64));
    st64(np, n + 4);
}

i64 php_jd_hex4() {
    i64 v = 0;
    i64 i = 0;
    loop {
        if (i >= 4) break;
        if (ph_jd_p >= ph_jd_n) { ph_jd_bad = 1; return 0; }
        i64 c = ld8(ph_jd_s + ph_jd_p);
        i64 d = 0 - 1;
        if (c >= 48 && c <= 57) d = c - 48;
        if (c >= 97 && c <= 102) d = c - 87;
        if (c >= 65 && c <= 70) d = c - 55;
        if (d < 0) { ph_jd_bad = 1; return 0; }
        v = v * 16 + d;
        ph_jd_p = ph_jd_p + 1;
        i = i + 1;
    }
    return v;
}

uptr php_jd_str() {
    ph_jd_p = ph_jd_p + 1;                                    // the opening "
    uptr sb = php_alloc(ph_jd_n * 4 + 8);
    u8 np[8];
    st64(np, 0);
    loop {
        if (ph_jd_p >= ph_jd_n) { ph_jd_bad = 1; break; }
        i64 c = ld8(ph_jd_s + ph_jd_p);
        if (c == 34) { ph_jd_p = ph_jd_p + 1; break; }
        if (c != 92) {
            i64 n0 = ld64(np);
            st8(sb + n0, c);
            st64(np, n0 + 1);
            ph_jd_p = ph_jd_p + 1;
            continue;
        }
        ph_jd_p = ph_jd_p + 1;
        if (ph_jd_p >= ph_jd_n) { ph_jd_bad = 1; break; }
        i64 e = ld8(ph_jd_s + ph_jd_p);
        ph_jd_p = ph_jd_p + 1;
        i64 out = 0 - 1;
        if (e == 34) out = 34;
        if (e == 92) out = 92;
        if (e == 47) out = 47;
        if (e == 98) out = 8;
        if (e == 102) out = 12;
        if (e == 110) out = 10;
        if (e == 114) out = 13;
        if (e == 116) out = 9;
        if (out >= 0) {
            i64 n1 = ld64(np);
            st8(sb + n1, out);
            st64(np, n1 + 1);
            continue;
        }
        if (e != 117) { ph_jd_bad = 1; break; }
        i64 cp = php_jd_hex4();
        if (ph_jd_bad) break;
        if (cp >= 55296 && cp < 56320) {
            if (ph_jd_p + 1 < ph_jd_n) {
                if (ld8(ph_jd_s + ph_jd_p) == 92) {
                    if (ld8(ph_jd_s + ph_jd_p + 1) == 117) {
                        ph_jd_p = ph_jd_p + 2;
                        i64 lo = php_jd_hex4();
                        if (ph_jd_bad) break;
                        cp = 65536 + (cp - 55296) * 1024 + (lo - 56320);
                    }
                }
            }
        }
        php_jd_utf8(sb, np, cp);
    }
    return php_str_new(sb, ld64(np));
}

uptr php_jd_num() {
    i64 st = ph_jd_p;
    i64 isf = 0;
    if (ph_jd_p < ph_jd_n) { if (ld8(ph_jd_s + ph_jd_p) == 45) ph_jd_p = ph_jd_p + 1; }
    loop {
        if (ph_jd_p >= ph_jd_n) break;
        i64 c = ld8(ph_jd_s + ph_jd_p);
        if (c >= 48 && c <= 57) { ph_jd_p = ph_jd_p + 1; continue; }
        if (c == 46 || c == 101 || c == 69) { isf = 1; ph_jd_p = ph_jd_p + 1; continue; }
        if (c == 43 || c == 45) {
            i64 pv = ld8(ph_jd_s + ph_jd_p - 1);
            if (pv == 101 || pv == 69) { ph_jd_p = ph_jd_p + 1; continue; }
        }
        break;
    }
    if (ph_jd_p == st) { ph_jd_bad = 1; return php_znull(); }
    uptr t = php_str_new(ph_jd_s + st, ph_jd_p - st);
    if (isf) return php_zdouble(php_stof(t));
    return php_zlong(php_stoi(t));
}

uptr php_jd_val(i64 depth) {
    php_jd_ws();
    if (ph_jd_p >= ph_jd_n) { ph_jd_bad = 1; return php_znull(); }
    if (depth > 512) { ph_jd_bad = 3; return php_znull(); }
    i64 c = ld8(ph_jd_s + ph_jd_p);
    if (c == 34) return php_zstr(php_jd_str());
    if (php_jd_lit("true", 4)) return php_zbool(1);
    if (php_jd_lit("false", 5)) return php_zbool(0);
    if (php_jd_lit("null", 4)) return php_znull();
    if (c == 91) {
        ph_jd_p = ph_jd_p + 1;
        uptr a = php_arr_new(8);
        php_jd_ws();
        if (ph_jd_p < ph_jd_n) { if (ld8(ph_jd_s + ph_jd_p) == 93) { ph_jd_p = ph_jd_p + 1; return php_zarr(a); } }
        loop {
            php_arr_push(a, php_jd_val(depth + 1));
            if (ph_jd_bad) break;
            php_jd_ws();
            if (ph_jd_p >= ph_jd_n) { ph_jd_bad = 1; break; }
            i64 d = ld8(ph_jd_s + ph_jd_p);
            ph_jd_p = ph_jd_p + 1;
            if (d == 93) break;
            if (d != 44) { ph_jd_bad = 1; break; }
        }
        return php_zarr(a);
    }
    if (c == 123) {
        ph_jd_p = ph_jd_p + 1;
        uptr a = php_arr_new(8);
        php_jd_ws();
        i64 empty = 0;
        if (ph_jd_p < ph_jd_n) { if (ld8(ph_jd_s + ph_jd_p) == 125) { ph_jd_p = ph_jd_p + 1; empty = 1; } }
        if (!empty) {
            loop {
                php_jd_ws();
                if (ph_jd_p >= ph_jd_n) { ph_jd_bad = 1; break; }
                if (ld8(ph_jd_s + ph_jd_p) != 34) { ph_jd_bad = 1; break; }
                uptr k = php_jd_str();
                if (ph_jd_bad) break;
                php_jd_ws();
                if (ph_jd_p >= ph_jd_n) { ph_jd_bad = 1; break; }
                if (ld8(ph_jd_s + ph_jd_p) != 58) { ph_jd_bad = 1; break; }
                ph_jd_p = ph_jd_p + 1;
                uptr v = php_jd_val(depth + 1);
                if (ph_jd_bad) break;
                php_zv_cp(php_arr_sslot(a, k), v);
                php_jd_ws();
                if (ph_jd_p >= ph_jd_n) { ph_jd_bad = 1; break; }
                i64 d = ld8(ph_jd_s + ph_jd_p);
                ph_jd_p = ph_jd_p + 1;
                if (d == 125) break;
                if (d != 44) { ph_jd_bad = 1; break; }
            }
        }
        if (ph_jd_assoc) return php_zarr(a);
        uptr o = php_obj_new(ph_ce_stdclass);
        i64 used = php_ht_used(a);
        i64 i = 0;
        loop {
            if (i >= used) break;
            uptr b = php_ht_bkt(a, i);
            if (ld8(b + 8) != IS_UNDEF) {
                uptr kk = ld64(b + 24);
                if (!kk) kk = php_itos(ld64(b + 16));
                php_zv_cp(php_arr_sslot(php_obj_props(o), kk), b);
            }
            i = i + 1;
        }
        return php_zobj(o);
    }
    if (c == 45 || (c >= 48 && c <= 57)) return php_jd_num();
    ph_jd_bad = 1;
    return php_znull();
}

uptr php_f_json_decode(uptr z, uptr assoc, uptr depth, uptr flags) {
    ph_js_bad = 0;
    ph_jd_bad = 0;
    uptr s = php_zv_str(z);
    ph_jd_s = s + ZS_HDR;
    ph_jd_n = php_strlen(s);
    ph_jd_p = 0;
    ph_jd_assoc = 0;
    if (php_zv_type(assoc) != IS_NULL) { if (php_zv_bool(assoc)) ph_jd_assoc = 1; }
    uptr r = php_jd_val(0);
    php_jd_ws();
    if (ph_jd_p != ph_jd_n) ph_jd_bad = 1;
    if (ph_jd_bad) { ph_js_bad = 4; return php_znull(); }
    return r;
}

uptr php_f_serialize(uptr z) {
    php_ob_start();
    php_ser(z, 0);
    return php_ob_get();
}

// the reader: a cursor into the string, php's grammar
i64 ph_us_p;
uptr ph_us_s;
i64 ph_us_n;
i64 ph_us_bad;

i64 php_us_int() {
    i64 neg = 0;
    if (ph_us_p < ph_us_n && ld8(ph_us_s + ph_us_p) == '-') { neg = 1; ph_us_p = ph_us_p + 1; }
    i64 v = 0;
    loop {
        if (ph_us_p >= ph_us_n) break;
        i64 c = ld8(ph_us_s + ph_us_p);
        if (c < 48 || c > 57) break;
        v = v * 10 + (c - 48);
        ph_us_p = ph_us_p + 1;
    }
    if (neg) return 0 - v;
    return v;
}

uptr php_us_val();

uptr php_us_str() {
    i64 len = php_us_int();
    if (ph_us_p >= ph_us_n || ld8(ph_us_s + ph_us_p) != ':') { ph_us_bad = 1; return php_str_new("", 0); }
    ph_us_p = ph_us_p + 2;                                 // `:"`
    if (ph_us_p + len > ph_us_n) { ph_us_bad = 1; return php_str_new("", 0); }
    uptr s = php_str_new(ph_us_s + ph_us_p, len);
    ph_us_p = ph_us_p + len + 2;                           // `";`
    return s;
}

uptr php_us_val() {
    if (ph_us_p >= ph_us_n) { ph_us_bad = 1; return php_znull(); }
    i64 t = ld8(ph_us_s + ph_us_p);
    // the type letter is followed by `:` (or `;` for N), and nothing else is
    // a serialization -- php answers false and warns for the rest
    if (t == 'N') {
        if (ph_us_p + 1 >= ph_us_n || ld8(ph_us_s + ph_us_p + 1) != ';') { ph_us_bad = 1; return php_znull(); }
        ph_us_p = ph_us_p + 2;
        return php_znull();
    }
    if (t != 'b' && t != 'i' && t != 'd' && t != 's' && t != 'a') { ph_us_bad = 1; return php_znull(); }
    if (ph_us_p + 1 >= ph_us_n || ld8(ph_us_s + ph_us_p + 1) != ':') { ph_us_bad = 1; return php_znull(); }
    if (t == 'b') { ph_us_p = ph_us_p + 2; i64 v = php_us_int(); ph_us_p = ph_us_p + 1; return php_zbool(v); }
    if (t == 'i') { ph_us_p = ph_us_p + 2; i64 v = php_us_int(); ph_us_p = ph_us_p + 1; return php_zlong(v); }
    if (t == 'd') {
        ph_us_p = ph_us_p + 2;
        i64 st = ph_us_p;
        loop { if (ph_us_p >= ph_us_n) break; if (ld8(ph_us_s + ph_us_p) == ';') break; ph_us_p = ph_us_p + 1; }
        uptr txt = php_str_new(ph_us_s + st, ph_us_p - st);
        ph_us_p = ph_us_p + 1;
        return php_zdouble(php_stof(txt));
    }
    if (t == 's') { ph_us_p = ph_us_p + 2; return php_zstr(php_us_str()); }
    if (t == 'a') {
        ph_us_p = ph_us_p + 2;
        i64 cnt = php_us_int();
        ph_us_p = ph_us_p + 2;                             // `:{`
        uptr a = php_arr_new(8);
        i64 i = 0;
        loop {
            if (i >= cnt) break;
            if (ph_us_bad) break;
            uptr k = php_us_val();
            uptr v = php_us_val();
            if (php_zv_type(k) == IS_STRING) php_zv_cp(php_arr_sslot(a, ld64(k)), v);
            if (php_zv_type(k) != IS_STRING) php_zv_cp(php_arr_islot(a, php_zv_long(k)), v);
            i = i + 1;
        }
        ph_us_p = ph_us_p + 1;                             // `}`
        return php_zarr(a);
    }
    ph_us_bad = 1;
    return php_znull();
}

uptr php_f_unserialize(uptr sz, uptr oz) {
    uptr s = php_zv_str(sz);
    ph_us_s = s + ZS_HDR;
    ph_us_n = php_strlen(s);
    ph_us_p = 0;
    ph_us_bad = 0;
    uptr v = php_us_val();
    if (ph_us_bad) {
        php_mreset();
        php_mc("unserialize(): Error at offset 0 of ");
        php_mi(ph_us_n);
        php_mc(" bytes");
        php_raise_m(PHE_WARNING);
        return php_zbool(0);
    }
    return v;
}

// mb_internal_encoding: this runtime's strings are BYTES (D10), and the one
// encoding it ever reports is the one php defaults to
uptr php_f_mb_internal_encoding(uptr z) {
    if (z) { if (php_zv_type(z) != IS_NULL) return php_zbool(1); }
    return php_zstr(php_str_new("UTF-8", 5));
}

uptr php_arg_range() {
    php_throw_str(php_str_new("ValueError", 10),
        php_str_new("func_get_arg(): Argument #1 ($position) must be less than the number of the arguments passed to the currently executed function", 127));
    return php_znull();
}

// func_get_arg(k): the compiler passes the count and every parameter of the
// caller, so this is a choice and not a stack walk.
uptr php_arg_at(i64 k, i64 n, uptr a0, uptr a1, uptr a2, uptr a3, uptr a4,
                uptr a5, uptr a6, uptr a7, uptr a8, uptr a9) {
    if (k < 0 || k >= n) {
        return php_arg_range();
    }
    if (k == 0) return a0;
    if (k == 1) return a1;
    if (k == 2) return a2;
    if (k == 3) return a3;
    if (k == 4) return a4;
    if (k == 5) return a5;
    if (k == 6) return a6;
    if (k == 7) return a7;
    if (k == 8) return a8;
    return a9;
}

// func_get_args(): the same choice as php_arg_at, collected into an array.
// D6 refuses no run-time table and this needs none -- the arguments of the
// executing function ARE its own parameters, which the compiler has in front
// of it (docs/plan.md D6, corrected by T8's measurement).
// `$a[k] = &$v` / `$o->p = &$v`: the two names share ONE cell from here on,
// and the cell php picks is the container's -- the variable is rebound to it
// after it receives the variable's current value. D7 has no refcount, so an
// array that is later COPIED (a php array is a value) separates them, which
// is the same approximation `$r = &$a[k]` has made since T8.
uptr php_ref_bind(uptr cell, uptr cur) {
    if (cur) php_zv_cp(cell, cur);
    return cell;
}

// `f(...$args)`: the callee's arity is fixed at compile time and the array's
// length is not, so the compiler emits one slot per parameter the callee
// could take and this answers "the k-th element, or NOT PASSED". 0 is what
// every zval parameter already reads as "not passed", which is what makes a
// default value and ArgumentCountError both still work.
// The two things php checks BEFORE it enters the callee and mc-php could
// not see: that the operand is unpackable at all, and -- mc-php's own limit
// and not php's -- that it fits the fixed number of slots the compiler
// emitted for it. Both were silent: `f(...1)` called f with no arguments and
// a 20-element array lost four values.
void php_unpack_check(uptr z, i64 cap) {
    if (php_zv_type(z) == IS_OBJECT) {
        // php iterates a TRAVERSABLE here and raises a TypeError for any
        // other object. Dying for both was wrong twice: the TypeError is
        // CATCHABLE and a `try` around the call should see it, and the
        // limit is only real for the objects this compiler cannot
        // iterate.
        if (php_instanceof(z, php_str_new("Traversable", 11))
            || php_instanceof(z, php_str_new("Iterator", 8))
            || php_instanceof(z, php_str_new("IteratorAggregate", 17))) {
            php_die("mc-php: a spread of a Traversable is not implemented yet\n", 57);
        }
        uptr mo = php_str_new("Only arrays and Traversables can be unpacked, ", 46);
        mo = php_str_concat(mo, php_f_get_debug_type(z));
        mo = php_str_concat(mo, php_str_new(" given", 6));
        php_throw_str(php_str_new("TypeError", 9), mo);
        return;
    }
    if (php_zv_type(z) != IS_ARRAY) {
        uptr m = php_str_new("Only arrays and Traversables can be unpacked, ", 46);
        m = php_str_concat(m, php_f_get_debug_type(z));
        m = php_str_concat(m, php_str_new(" given", 6));
        php_throw_str(php_str_new("TypeError", 9), m);
        return;
    }
    if (cap <= 0) return;                  // the callee's arity, not my buffer
    uptr a = ld64(z);
    i64 n = 0;
    i64 i = php_it_next(a, 0);
    loop {
        if (i < 0) break;
        n = n + 1;
        if (n > cap) {
            // the CALL's own slot count, not a constant: it is 16 for a
            // plain function, 6 for a method and 5 for a callable value, and
            // a seven-element method spread reported "more than 16".
            php_flush();
            write(2, "mc-php: a spread of more than ", 30);
            uptr d = php_itos(cap);
            write(2, php_str_val(d), php_strlen(d));
            write(2, " values is not implemented yet\n", 31);
            exit(255);
        }
        i = php_it_next(a, i + 1);
    }
}

uptr php_unpack_at(uptr z, i64 k) {
    if (php_zv_type(z) != IS_ARRAY) return 0;
    uptr a = ld64(z);
    i64 i = php_it_next(a, 0);
    loop {
        if (i < 0) return 0;
        if (k == 0) return php_it_val(a, i);
        k = k - 1;
        i = php_it_next(a, i + 1);
    }
    return 0;
}

// max()/min(): php takes either one array or two-or-more values, and the
// comparison is php's own (php_zv_cmp), not a numeric one -- max("10", "9a")
// is "9a" because both are compared as strings.
uptr php_maxmin(i64 want, i64 n, uptr a0, uptr a1, uptr a2, uptr a3, uptr a4,
                uptr a5, uptr a6, uptr a7, uptr a8, uptr a9) {
    uptr best = 0;
    if (n == 1) {
        if (php_zv_type(a0) != IS_ARRAY) {
            // php names the TYPE it was given -- `..., int given` -- and
            // the direction, so `min` does not report itself as `max`.
            uptr mm = php_str_new("max", 3);
            if (want < 0) mm = php_str_new("min", 3);
            mm = php_str_concat(mm, php_str_new("(): Argument #1 ($value) must be of type array, ", 48));
            mm = php_str_concat(mm, php_f_get_debug_type(a0));
            mm = php_str_concat(mm, php_str_new(" given", 6));
            php_throw_str(php_str_new("TypeError", 9), mm);
            return php_znull();
        }
        uptr h = ld64(a0);
        i64 i = php_it_next(h, 0);
        loop {
            if (i < 0) break;
            uptr v = php_it_val(h, i);
            if (!best) best = v;
            if (best) { if (php_zv_cmp(v, best) * want > 0) best = v; }
            i = php_it_next(h, i + 1);
        }
        if (!best) {
            php_throw_str(php_str_new("ValueError", 10),
                php_str_new("max(): Argument #1 ($value) must contain at least one element", 61));
            return php_znull();
        }
        return best;
    }
    i64 k = 0;
    loop {
        if (k >= n) break;
        uptr v = a0;
        if (k == 1) v = a1;
        if (k == 2) v = a2;
        if (k == 3) v = a3;
        if (k == 4) v = a4;
        if (k == 5) v = a5;
        if (k == 6) v = a6;
        if (k == 7) v = a7;
        if (k == 8) v = a8;
        if (k == 9) v = a9;
        if (!v) break;
        if (!best) best = v;
        if (best) { if (php_zv_cmp(v, best) * want > 0) best = v; }
        k = k + 1;
    }
    if (!best) return php_znull();
    return best;
}

// the library road wants php_znull() where the user road wants 0
uptr php_nn(uptr z) { if (z) return z; return php_znull(); }

// ...and a variadic callee's rest array must not collect the slots that
// were not passed
void php_arr_push_opt(uptr a, uptr v) { if (v) php_arr_push(a, v); }

// `$a = &f()` where f does not return by reference: php keeps the value and
// says so. The value is already a cell here, so the alias is harmless; the
// notice is what the corpus grades.
void php_ref_notice() { php_mreset(); php_mc("Only variables should be assigned by reference"); php_raise_m(PHE_NOTICE); }

uptr php_args_all(i64 n, uptr a0, uptr a1, uptr a2, uptr a3, uptr a4,
                  uptr a5, uptr a6, uptr a7, uptr a8, uptr a9) {
    uptr a = php_arr_new(n);
    i64 k = 0;
    loop {
        if (k >= n) break;
        php_arr_push(a, php_arg_at(k, n, a0, a1, a2, a3, a4, a5, a6, a7, a8, a9));
        k = k + 1;
    }
    return php_zarr(a);
}

// isset($s[i]) / empty($s[i]): php reads a string offset that is not there as
// "does not exist", which is null here -- the quiet read the chain wants.
uptr php_str_off_q(uptr s, i64 i) {
    i64 n = php_strlen(s);
    if (i < 0) i = n + i;
    if (i < 0 || i >= n) return php_znull();
    return php_zstr(php_str_new(s + ZS_HDR + i, 1));
}

// `$r = &$o->p`: the property's own zval cell, so the two names share it.
// The slot is created when the property is not there, which is what php's
// reference-taking does too.
uptr php_zv_pref(uptr z, uptr name, uptr scope) {
    if (php_zv_type(z) != IS_OBJECT) return php_znull();
    return php_obj_slot(ld64(z), name);
}

// `$s[i] = "c"`: php writes the byte in place. Strings are immutable here
// (D10), so the answer is a new one and the variable is reassigned.
uptr php_str_setoff(uptr s, i64 i, uptr cz) {
    i64 n = php_strlen(s);
    if (i < 0) i = n + i;
    if (i < 0) {
        php_warn1("Illegal string offset");
        return s;
    }
    uptr c = php_zv_str(cz);
    if (!php_strlen(c)) {
        php_throw_str(php_str_new("Error", 5),
            php_str_new("Cannot assign an empty string to a string offset", 48));
        return s;
    }
    i64 m = n;
    if (i >= m) m = i + 1;
    uptr o = php_str_alloc(m);
    i64 k = 0;
    loop { if (k >= m) break; i64 b = ' '; if (k < n) b = ld8(s + ZS_HDR + k); st8(o + ZS_HDR + k, b); k = k + 1; }
    st8(o + ZS_HDR + i, ld8(c + ZS_HDR));
    return o;
}

// fprintf / vfprintf: the formatted text, written to a stream
uptr php_f_fput(uptr rz, uptr s) {
    i64 i = php_res_id(rz);
    if (i < 0) return php_zbool(0);
    php_flush();
    i64 w = write(ld64(ph_fh_fd + i * 8), s + ZS_HDR, php_strlen(s));
    if (w < 0) return php_zbool(0);
    return php_zlong(w);
}

// get_html_translation_table(table, flags, encoding): php's own two tables.
// HTML_SPECIALCHARS is the five htmlspecialchars() writes; HTML_ENTITIES is
// those plus the Latin-1 range, which is what the corpus asks about.
uptr php_f_get_html_translation_table(uptr tz, uptr fz, uptr ez) {
    i64 tbl = 0;
    if (tz) { if (php_zv_type(tz) != IS_NULL) tbl = php_zv_long(tz); }
    i64 flags = 11;                                   // ENT_QUOTES | ENT_SUBSTITUTE
    if (fz) { if (php_zv_type(fz) != IS_NULL) flags = php_zv_long(fz); }
    uptr a = php_arr_new(8);
    if (flags & 2) php_zv_cp(php_arr_sslot(a, php_str_new("\"", 1)), php_zstr(php_str_new("&quot;", 6)));
    php_zv_cp(php_arr_sslot(a, php_str_new("&", 1)), php_zstr(php_str_new("&amp;", 5)));
    if (flags & 1) php_zv_cp(php_arr_sslot(a, php_str_new("'", 1)), php_zstr(php_str_new("&#039;", 6)));
    php_zv_cp(php_arr_sslot(a, php_str_new("<", 1)), php_zstr(php_str_new("&lt;", 4)));
    php_zv_cp(php_arr_sslot(a, php_str_new(">", 1)), php_zstr(php_str_new("&gt;", 4)));
    if (tbl != 1) return a;
    // HTML_ENTITIES: php's own list, `codepoint:name` pairs, dumped from
    // php 8.5.10 and checked back against it by the fixture. The key is the
    // character in UTF-8, which is what php 8 answers for the default
    // encoding.
    uptr ents = "160:nbsp 161:iexcl 162:cent 163:pound 164:curren 165:yen 166:brvbar 167:sect 168:uml 169:copy 170:ordf 171:laquo 172:not 173:shy 174:reg 175:macr 176:deg 177:plusmn 178:sup2 179:sup3 180:acute 181:micro 182:para 183:middot 184:cedil 185:sup1 186:ordm 187:raquo 188:frac14 189:frac12 190:frac34 191:iquest 192:Agrave 193:Aacute 194:Acirc 195:Atilde 196:Auml 197:Aring 198:AElig 199:Ccedil 200:Egrave 201:Eacute 202:Ecirc 203:Euml 204:Igrave 205:Iacute 206:Icirc 207:Iuml 208:ETH 209:Ntilde 210:Ograve 211:Oacute 212:Ocirc 213:Otilde 214:Ouml 215:times 216:Oslash 217:Ugrave 218:Uacute 219:Ucirc 220:Uuml 221:Yacute 222:THORN 223:szlig 224:agrave 225:aacute 226:acirc 227:atilde 228:auml 229:aring 230:aelig 231:ccedil 232:egrave 233:eacute 234:ecirc 235:euml 236:igrave 237:iacute 238:icirc 239:iuml 240:eth 241:ntilde 242:ograve 243:oacute 244:ocirc 245:otilde 246:ouml 247:divide 248:oslash 249:ugrave 250:uacute 251:ucirc 252:uuml 253:yacute 254:thorn 255:yuml 338:OElig 339:oelig 352:Scaron 353:scaron 376:Yuml 402:fnof 710:circ 732:tilde 913:Alpha 914:Beta 915:Gamma 916:Delta 917:Epsilon 918:Zeta 919:Eta 920:Theta 921:Iota 922:Kappa 923:Lambda 924:Mu 925:Nu 926:Xi 927:Omicron 928:Pi 929:Rho 931:Sigma 932:Tau 933:Upsilon 934:Phi 935:Chi 936:Psi 937:Omega 945:alpha 946:beta 947:gamma 948:delta 949:epsilon 950:zeta 951:eta 952:theta 953:iota 954:kappa 955:lambda 956:mu 957:nu 958:xi 959:omicron 960:pi 961:rho 962:sigmaf 963:sigma 964:tau 965:upsilon 966:phi 967:chi 968:psi 969:omega 977:thetasym 978:upsih 982:piv 8194:ensp 8195:emsp 8201:thinsp 8204:zwnj 8205:zwj 8206:lrm 8207:rlm 8211:ndash 8212:mdash 8216:lsquo 8217:rsquo 8218:sbquo 8220:ldquo 8221:rdquo 8222:bdquo 8224:dagger 8225:Dagger 8226:bull 8230:hellip 8240:permil 8242:prime 8243:Prime 8249:lsaquo 8250:rsaquo 8254:oline 8260:frasl 8364:euro 8465:image 8472:weierp 8476:real 8482:trade 8501:alefsym 8592:larr 8593:uarr 8594:rarr 8595:darr 8596:harr 8629:crarr 8656:lArr 8657:uArr 8658:rArr 8659:dArr 8660:hArr 8704:forall 8706:part 8707:exist 8709:empty 8711:nabla 8712:isin 8713:notin 8715:ni 8719:prod 8721:sum 8722:minus 8727:lowast 8730:radic 8733:prop 8734:infin 8736:ang 8743:and 8744:or 8745:cap 8746:cup 8747:int 8756:there4 8764:sim 8773:cong 8776:asymp 8800:ne 8801:equiv 8804:le 8805:ge 8834:sub 8835:sup 8836:nsub 8838:sube 8839:supe 8853:oplus 8855:otimes 8869:perp 8901:sdot 8968:lceil 8969:rceil 8970:lfloor 8971:rfloor 9001:lang 9002:rang 9674:loz 9824:spades 9827:clubs 9829:hearts 9830:diams";
    i64 i = 0;
    loop {
        if (!ld8(ents + i)) break;
        i64 cp = 0;
        loop { i64 c = ld8(ents + i); if (c < 48 || c > 57) break; cp = cp * 10 + (c - 48); i = i + 1; }
        i = i + 1;                                    // the colon
        i64 st = i;
        loop { if (!ld8(ents + i)) break; if (ld8(ents + i) == ' ') break; i = i + 1; }
        uptr ent = php_str_concat(php_str_new("&", 1),
                                  php_str_concat(php_str_new(ents + st, i - st), php_str_new(";", 1)));
        u8 ub[8];
        i64 un = 0;
        if (cp < 128) { st8(ub, cp); un = 1; }
        if (cp >= 128 && cp < 2048) { st8(ub, 192 + (cp >> 6)); st8(ub + 1, 128 + (cp & 63)); un = 2; }
        if (cp >= 2048) { st8(ub, 224 + (cp >> 12)); st8(ub + 1, 128 + ((cp >> 6) & 63)); st8(ub + 2, 128 + (cp & 63)); un = 3; }
        php_zv_cp(php_arr_sslot(a, php_str_new(ub, un)), php_zstr(ent));
        if (ld8(ents + i) == ' ') i = i + 1;
    }
    return a;
}

// How many times `search` occurs in `subj`, without overlap: str_replace's
// count, and php_str_replace's own first pass.
i64 php_str_occ(uptr subj, uptr search) {
    i64 sn = php_strlen(search);
    if (sn == 0) return 0;
    i64 n = 0;
    i64 i = 0;
    loop {
        i64 p = php_strpos(subj, search, i);
        if (p < 0) break;
        n = n + 1;
        i = p + sn;
    }
    return n;
}

// str_replace over ONE subject string, with php's array forms: an array of
// searches is applied in order, each to the result of the one before; an
// array of replacements is consumed in step (an empty search consumes its
// replacement too) and runs out into "". ext/standard/string.c's
// php_str_replace_in_subject is the model. `cnt` is an i64 cell.
uptr php_sr_subject(uptr sz, uptr rz, uptr subj, uptr cnt) {
    if (php_zv_type(sz) != IS_ARRAY) {
        uptr s1 = php_zv_str(sz);
        st64(cnt, ld64(cnt) + php_str_occ(subj, s1));
        return php_str_replace(s1, php_zv_str(rz), subj);
    }
    uptr sh = ld64(sz);
    uptr rh = 0;
    uptr rs = 0;
    if (php_zv_type(rz) == IS_ARRAY) rh = ld64(rz);
    if (!rh) rs = php_zv_str(rz);
    i64 ri = 0;
    i64 used = php_ht_used(sh);
    i64 i = 0;
    loop {
        if (i >= used) break;
        uptr b = php_ht_bkt(sh, i);
        i = i + 1;
        if (ld8(b + 8) == IS_UNDEF) continue;
        uptr s = php_zv_str(b);
        uptr r = rs;
        if (rh) {
            r = php_str_new("", 0);
            loop {
                if (ri >= php_ht_used(rh)) break;
                uptr rb = php_ht_bkt(rh, ri);
                ri = ri + 1;
                if (ld8(rb + 8) != IS_UNDEF) { r = php_zv_str(rb); break; }
            }
        }
        if (php_strlen(s) == 0) continue;
        st64(cnt, ld64(cnt) + php_str_occ(subj, s));
        subj = php_str_replace(s, r, subj);
    }
    return subj;
}

// str_replace with php's whole signature: string|array for all three, the
// subject's keys kept when it is an array, and php 8's TypeError for an
// array of replacements against a string search.
uptr php_f_str_replace(uptr sz, uptr rz, uptr subz, uptr cz) {
    if (php_zv_type(sz) != IS_ARRAY && php_zv_type(rz) == IS_ARRAY) {
        php_throw_str(php_str_new("TypeError", 9),
            php_str_new("str_replace(): Argument #2 ($replace) must be of type string when argument #1 ($search) is a string", 99));
        return php_znull();
    }
    u8 cnt[8];
    st64(cnt, 0);
    uptr res = 0;
    if (php_zv_type(subz) == IS_ARRAY) {
        uptr h = ld64(subz);
        uptr r = php_arr_new(8);
        i64 used = php_ht_used(h);
        i64 i = 0;
        loop {
            if (i >= used) break;
            uptr b = php_ht_bkt(h, i);
            i = i + 1;
            if (ld8(b + 8) == IS_UNDEF) continue;
            uptr v = php_zstr(php_sr_subject(sz, rz, php_zv_str(b), cnt));
            uptr k = ld64(b + 24);
            if (k) php_zv_cpv(php_ht_slotfor(r, php_str_hash(k), k), v);
            if (!k) php_zv_cpv(php_arr_islot(r, ld64(b + 16)), v);
        }
        res = php_zarr(r);
    }
    if (!res) res = php_zstr(php_sr_subject(sz, rz, php_zv_str(subz), cnt));
    if (cz) {
        st64(cz, ld64(cnt));
        php_zv_settype(cz, IS_LONG);
    }
    return res;
}

// str_replace($search, $replace, $subject, &$count): php's fourth argument
// is by reference and carries how many replacements were made.
uptr php_str_replace_c(uptr search, uptr repl, uptr subj, uptr cz) {
    uptr o = php_str_replace(search, repl, subj);
    if (cz) {
        i64 sn = php_strlen(search);
        i64 n = 0;
        if (sn) {
            i64 i = 0;
            loop {
                i64 p = php_strpos(subj, search, i);
                if (p < 0) break;
                n = n + 1;
                i = p + sn;
            }
        }
        st64(cz, n);
        php_zv_settype(cz, IS_LONG);
    }
    return o;
}

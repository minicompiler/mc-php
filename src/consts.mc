// consts.mc -- const NAME = <literal>, define(), and php's predefined set.
// 
// A constant is resolved at compile time when it can be; the predefined ones
// (PHP_EOL, PHP_INT_MAX, M_PI and the rest) are a table read here.

// ---- `const NAME = <literal>;` and define("NAME", <literal>) --------------
// A constant is compile time here, which is what D1 already requires of every
// name: there is no run-time symbol table to look one up in.
#define PH_MAXCONST 256

uptr ph_cname[PH_MAXCONST];
i64  ph_cty[PH_MAXCONST];
i64  ph_cval[PH_MAXCONST];
uptr ph_cstr[PH_MAXCONST];
i64  ph_nconst;

i64 ph_const_find(uptr n) {
    i64 i = 0;
    loop {
        if (i >= ph_nconst) break;
        if (str_eq(ld64(ph_cname + i * 8), n)) return i;
        i = i + 1;
    }
    return -1;
}

// A constant's value has to be known at compile time: an int/bool literal or a
// string literal, which is the php_str_lit call ph_strlit built.
void ph_const_add(uptr cn, i64 v, i64 t, uptr fl, i64 line) {
    if (ph_const_find(cn) >= 0) err_at2(fl, line, "mc-php: this php constant is declared twice", cn);
    if (ph_nconst >= PH_MAXCONST) err_at(fl, line, "mc-php: too many php constants");
    i64 val = 0;
    uptr bytes = 0;
    i64 lit = 0;
    if ((t == PT_INT || t == PT_BOOL) && nd_kind(v) == N_INT) { val = nd_val(v); lit = 1; }
    if (t == PT_STRING && nd_kind(v) == N_CALL && str_eq(nd_name(v), "php_str_lit")) {
        i64 raw = nd_next(nd_a(v));
        bytes = nd_name(raw);
        val = nd_val(raw);
        lit = 1;
    }
    if (!lit) {
        // not a literal: the value is computed at run time and looked up by
        // name, which is what php's own constant table is
        ph_pending_stmt(ph_stmt_of(ph_c2("php_const_set", ph_strlit(cn, cstrlen(cn)), ph_to_mixed(v, t), TY_VOID)));
        st64(ph_cname + ph_nconst * 8, cn);
        st64(ph_cty + ph_nconst * 8, -1);
        st64(ph_cval + ph_nconst * 8, 0);
        st64(ph_cstr + ph_nconst * 8, 0);
        ph_nconst = ph_nconst + 1;
        return;
    }
    st64(ph_cname + ph_nconst * 8, cn);
    st64(ph_cty + ph_nconst * 8, t);
    st64(ph_cval + ph_nconst * 8, val);
    st64(ph_cstr + ph_nconst * 8, bytes);
    ph_nconst = ph_nconst + 1;
}

// ---- the predefined constants ----------------------------------------------
// value kinds: 0 int, 1 string, 2 float (built by the runtime from its text)
#define PH_MAXPRE 160
uptr ph_pren[PH_MAXPRE];
i64  ph_prek[PH_MAXPRE];
i64  ph_prev[PH_MAXPRE];
uptr ph_pres[PH_MAXPRE];
i64  ph_npre;

void ph_pre(uptr n, i64 k, i64 v, uptr s) {
    if (ph_npre >= PH_MAXPRE) err_at("php.mc", 1, "mc-php: too many predefined constants");
    st64(ph_pren + ph_npre * 8, n);
    st64(ph_prek + ph_npre * 8, k);
    st64(ph_prev + ph_npre * 8, v);
    st64(ph_pres + ph_npre * 8, s);
    ph_npre = ph_npre + 1;
}

i64 ph_pre_find(uptr n) {
    i64 i = 0;
    loop {
        if (i >= ph_npre) break;
        if (str_eq(ld64(ph_pren + i * 8), n)) return i;
        i = i + 1;
    }
    return -1;
}

// The four predefined constants that are the HOST's answer and not php's.
// They were four rows of the table below, all four saying macOS, and two of
// them said it twice: DIRECTORY_SEPARATOR and PATH_SEPARATOR were registered
// at the head of the table with a LENGTH of 0 and again at its foot with the
// right one, and ph_pre_find returns the FIRST match -- so both compiled to
// the empty string and the correct pair was unreachable. Inherited verbatim
// from probes/t10, which is frozen and keeps it.
//
// php's own values, from php-src's Zend/zend_portability.h and main/php.h:
//
//   host      DIRECTORY_SEPARATOR   PATH_SEPARATOR   PHP_OS   PHP_OS_FAMILY
//   macOS     /                     :                Darwin   Darwin
//   Linux     /                     :                Linux    Linux
//   Windows   \\                    ;                WINNT    Windows
//
// The host is the compiler's own, for the reason src/program.mc gives about
// the runtime host layer: mc's default target is the host's, so a binary this
// compiler writes runs on the machine that wrote it.
//
// The third column is the string's LENGTH and mc will not check it -- that is
// what the 0 above was. tests/lencheck.py covers ph_pre since this commit.
void ph_pre_host() {
    uptr os = host_os();
    if (str_eq(os, "windows")) {
        ph_pre("DIRECTORY_SEPARATOR", 1, 1, "\\");
        ph_pre("PATH_SEPARATOR", 1, 1, ";");
        ph_pre("PHP_OS", 1, 5, "WINNT");
        ph_pre("PHP_OS_FAMILY", 1, 7, "Windows");
        ph_pre("PHP_EOL", 1, 2, "\r\n");
        ph_lc_bsd();
        return;
    }
    ph_pre("DIRECTORY_SEPARATOR", 1, 1, "/");
    ph_pre("PATH_SEPARATOR", 1, 1, ":");
    ph_pre("PHP_EOL", 1, 1, "\n");
    if (str_eq(os, "linux")) {
        ph_pre("PHP_OS", 1, 5, "Linux");
        ph_pre("PHP_OS_FAMILY", 1, 5, "Linux");
        ph_lc_gnu();
        return;
    }
    ph_pre("PHP_OS", 1, 6, "Darwin");
    ph_pre("PHP_OS_FAMILY", 1, 6, "Darwin");
    ph_lc_bsd();
}

// setlocale's category numbers, which php takes straight from the system's
// locale.h. BSD (macOS) and the Microsoft CRT number them from LC_ALL; glibc
// and musl number them from LC_CTYPE and put LC_ALL last. They reach libc
// unchanged -- lib/rt_host_*.mc declares setlocale(3) and php_f_setlocale
// calls it -- so a wrong number here asks the host about the wrong category.
void ph_lc_bsd() {
    ph_pre("LC_ALL", 0, 0, 0);
    ph_pre("LC_COLLATE", 0, 1, 0);
    ph_pre("LC_CTYPE", 0, 2, 0);
    ph_pre("LC_MONETARY", 0, 3, 0);
    ph_pre("LC_NUMERIC", 0, 4, 0);
    ph_pre("LC_TIME", 0, 5, 0);
    ph_pre("LC_MESSAGES", 0, 6, 0);
}

void ph_lc_gnu() {
    ph_pre("LC_CTYPE", 0, 0, 0);
    ph_pre("LC_NUMERIC", 0, 1, 0);
    ph_pre("LC_TIME", 0, 2, 0);
    ph_pre("LC_COLLATE", 0, 3, 0);
    ph_pre("LC_MONETARY", 0, 4, 0);
    ph_pre("LC_MESSAGES", 0, 5, 0);
    ph_pre("LC_ALL", 0, 6, 0);
}

void ph_pre_init() {
    ph_pre("HTML_SPECIALCHARS", 0, 0, 0);
    ph_pre("HTML_ENTITIES", 0, 1, 0);
    ph_pre("LOCK_SH", 0, 1, 0);
    ph_pre("LOCK_EX", 0, 2, 0);
    ph_pre("LOCK_UN", 0, 8, 0);
    ph_pre("FILE_USE_INCLUDE_PATH", 0, 1, 0);
    ph_pre("FILE_IGNORE_NEW_LINES", 0, 2, 0);
    ph_pre("FILE_SKIP_EMPTY_LINES", 0, 4, 0);
    ph_pre("FILE_APPEND", 0, 8, 0);
    ph_pre("E_ERROR", 0, 1, 0);
    ph_pre("E_WARNING", 0, 2, 0);
    ph_pre("E_PARSE", 0, 4, 0);
    ph_pre("E_NOTICE", 0, 8, 0);
    ph_pre("E_CORE_ERROR", 0, 16, 0);
    ph_pre("E_CORE_WARNING", 0, 32, 0);
    ph_pre("E_COMPILE_ERROR", 0, 64, 0);
    ph_pre("E_COMPILE_WARNING", 0, 128, 0);
    ph_pre("E_USER_ERROR", 0, 256, 0);
    ph_pre("E_USER_WARNING", 0, 512, 0);
    ph_pre("E_USER_NOTICE", 0, 1024, 0);
    ph_pre("E_STRICT", 0, 2048, 0);
    ph_pre("E_RECOVERABLE_ERROR", 0, 4096, 0);
    ph_pre("E_DEPRECATED", 0, 8192, 0);
    ph_pre("E_USER_DEPRECATED", 0, 16384, 0);
    ph_pre("E_ALL", 0, 30719, 0);
    ph_pre("SORT_REGULAR", 0, 0, 0);
    ph_pre("SORT_NUMERIC", 0, 1, 0);
    ph_pre("SORT_STRING", 0, 2, 0);
    ph_pre("SORT_DESC", 0, 3, 0);
    ph_pre("SORT_ASC", 0, 4, 0);
    ph_pre("SORT_LOCALE_STRING", 0, 5, 0);
    ph_pre("SORT_NATURAL", 0, 6, 0);
    ph_pre("SORT_FLAG_CASE", 0, 8, 0);
    ph_pre("COUNT_NORMAL", 0, 0, 0);
    ph_pre("COUNT_RECURSIVE", 0, 1, 0);
    ph_pre("ENT_QUOTES", 0, 3, 0);
    ph_pre("ENT_COMPAT", 0, 2, 0);
    ph_pre("ENT_NOQUOTES", 0, 0, 0);
    ph_pre("ENT_HTML5", 0, 48, 0);
    ph_pre("ENT_HTML401", 0, 0, 0);
    ph_pre("ENT_SUBSTITUTE", 0, 8, 0);
    ph_pre("ENT_IGNORE", 0, 4, 0);
    ph_pre("PHP_MAJOR_VERSION", 0, 8, 0);
    ph_pre("PHP_MINOR_VERSION", 0, 5, 0);
    ph_pre("PHP_RELEASE_VERSION", 0, 10, 0);
    ph_pre("PHP_INT_SIZE", 0, 8, 0);
    ph_pre("PHP_FLOAT_DIG", 0, 15, 0);
    ph_pre("JSON_PRETTY_PRINT", 0, 128, 0);
    ph_pre("JSON_UNESCAPED_SLASHES", 0, 64, 0);
    ph_pre("JSON_UNESCAPED_UNICODE", 0, 256, 0);
    ph_pre("JSON_THROW_ON_ERROR", 0, 4194304, 0);
    ph_pre("JSON_HEX_TAG", 0, 1, 0);
    ph_pre("JSON_HEX_QUOT", 0, 8, 0);
    ph_pre("JSON_HEX_AMP", 0, 2, 0);
    ph_pre("JSON_HEX_APOS", 0, 4, 0);
    ph_pre("JSON_NUMERIC_CHECK", 0, 32, 0);
    ph_pre("JSON_PRESERVE_ZERO_FRACTION", 0, 1024, 0);
    ph_pre("JSON_ERROR_NONE", 0, 0, 0);
    ph_pre("ARRAY_FILTER_USE_KEY", 0, 2, 0);
    ph_pre("ARRAY_FILTER_USE_BOTH", 0, 1, 0);
    ph_pre("PHP_ROUND_HALF_UP", 0, 1, 0);
    ph_pre("PHP_ROUND_HALF_DOWN", 0, 2, 0);
    ph_pre("PHP_ROUND_HALF_EVEN", 0, 3, 0);
    ph_pre("PHP_ROUND_HALF_ODD", 0, 4, 0);
    ph_pre("SEEK_SET", 0, 0, 0);
    ph_pre("SEEK_CUR", 0, 1, 0);
    ph_pre("SEEK_END", 0, 2, 0);
    ph_pre("PREG_PATTERN_ORDER", 0, 1, 0);
    ph_pre("PREG_SET_ORDER", 0, 2, 0);
    ph_pre("PREG_SPLIT_NO_EMPTY", 0, 1, 0);
    ph_pre("CASE_LOWER", 0, 0, 0);
    ph_pre("CASE_UPPER", 0, 1, 0);
    ph_pre("STR_PAD_RIGHT", 0, 1, 0);
    ph_pre("STR_PAD_LEFT", 0, 0, 0);
    ph_pre("STR_PAD_BOTH", 0, 2, 0);
    ph_pre("PHP_VERSION_ID", 0, 80510, 0);
    ph_pre("MB_CASE_UPPER", 0, 0, 0);
    ph_pre("MB_CASE_LOWER", 0, 1, 0);
    ph_pre("MB_CASE_TITLE", 0, 2, 0);
    ph_pre("DEBUG_BACKTRACE_IGNORE_ARGS", 0, 2, 0);
    ph_pre("PHP_MAXPATHLEN", 0, 1024, 0);
    ph_pre_host();
    ph_pre("PHP_VERSION", 1, 6, "8.5.10");
    ph_pre("PHP_EXTRA_VERSION", 1, 0, "");
    ph_pre("PHP_SAPI", 1, 3, "cli");
    ph_pre("PHP_BINARY", 1, 3, "php");
    ph_pre("M_PI", 2, 0, "3.141592653589793");
    ph_pre("M_E", 2, 0, "2.718281828459045");
    ph_pre("M_SQRT2", 2, 0, "1.4142135623730951");
    ph_pre("M_LN2", 2, 0, "0.6931471805599453");
    ph_pre("M_LN10", 2, 0, "2.302585092994046");
    ph_pre("M_LOG2E", 2, 0, "1.4426950408889634");
    ph_pre("M_LOG10E", 2, 0, "0.4342944819032518");
    ph_pre("M_PI_2", 2, 0, "1.5707963267948966");
    ph_pre("M_PI_4", 2, 0, "0.7853981633974483");
    ph_pre("M_1_PI", 2, 0, "0.3183098861837907");
    ph_pre("M_2_PI", 2, 0, "0.6366197723675814");
    ph_pre("M_SQRT1_2", 2, 0, "0.7071067811865476");
    ph_pre("M_2_SQRTPI", 2, 0, "1.1283791670955126");
    ph_pre("M_EULER", 2, 0, "0.5772156649015329");
    ph_pre("M_SQRT3", 2, 0, "1.7320508075688772");
    ph_pre("PHP_FLOAT_EPSILON", 2, 0, "2.220446049250313e-16");
    ph_pre("PHP_FLOAT_MAX", 2, 0, "1.7976931348623157e+308");
    ph_pre("PHP_FLOAT_MIN", 2, 0, "2.2250738585072014e-308");
}
